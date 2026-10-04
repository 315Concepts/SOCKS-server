#!/usr/bin/env bash
# Smoke-test a built image: run it locked down the way docker-compose.yaml does
# and probe the behaviour README.md promises.
#
# Usage: scripts/smoke-test.sh [image]     (default: socks-server:latest)
# Needs: docker, curl, bash. Exits 0 only if every check passes.
set -uo pipefail

IMAGE="${1:-socks-server:latest}"
NAME="socks-smoke-$$"
WORK="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  exec 3>&- 2>/dev/null
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "  ok    $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image $IMAGE not found — run 'npm run build' first" >&2
  exit 2
fi

# Fixture, readable by the container's non-root user.
mkdir -p "$WORK/public/sub"
echo '<h1>smoke</h1>' >"$WORK/public/index.html"
echo 'sub' >"$WORK/public/sub/index.html"
echo 'SMOKE_DOTFILE_SECRET' >"$WORK/public/.env"
chmod -R a+rX "$WORK"

# start [docker run args...] — (re)start the container and wait for /healthz.
start() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker run -d --name "$NAME" -p 127.0.0.1::8080 \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    -v "$WORK/public:/app/public:ro" "$@" "$IMAGE" >/dev/null || exit 2
  PORT="$(docker port "$NAME" 8080/tcp | head -1 | sed 's/.*://')"
  URL="http://127.0.0.1:$PORT"
  for _ in $(seq 50); do
    curl -fsS "$URL/healthz" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "container never became healthy; logs:" >&2
  docker logs "$NAME" >&2
  exit 2
}

status() { curl -s -o /dev/null -w '%{http_code}' --path-as-is "$URL$1"; }
body() { curl -s --path-as-is "$URL$1"; }
logs() { docker logs "$NAME" 2>&1; }
remaining() { curl -sI -H "X-Forwarded-For: $1" "$URL/" | sed -n 's/^ratelimit:.*remaining=\([0-9]*\).*/\1/ip'; }

# ---- Default config: serving, headers, logging, shutdown --------------------
echo "== default config ($IMAGE)"
start

check "/healthz is 200" [ "$(status /healthz)" = 200 ]
check "/ serves index.html" grep -q smoke <<<"$(body /)"
check "/sub/ serves sub/index.html" [ "$(status /sub/)" = 200 ]
check "/sub (no slash) is 404, no redirect" [ "$(status /sub)" = 404 ]
check "unknown path is 404" [ "$(status /nope)" = 404 ]
check "/.env is 404" [ "$(status /.env)" = 404 ]
check "/.env body does not leak contents" bash -c '! grep -q SMOKE_DOTFILE_SECRET <<<"$1"' _ "$(body /.env)"
check "/../etc/passwd is 404" [ "$(status /../etc/passwd)" = 404 ]
check "/%2e%2e/etc/passwd is 404" [ "$(status /%2e%2e/etc/passwd)" = 404 ]
check "/%2e%2e%2fetc%2fpasswd is 404" [ "$(status /%2e%2e%2fetc%2fpasswd)" = 404 ]

HEADERS="$(curl -sI "$URL/")"
has() { grep -qi "^$1" <<<"$HEADERS"; }
check "Content-Security-Policy set" has "content-security-policy:"
check "Strict-Transport-Security set" has "strict-transport-security:"
check "X-Content-Type-Options: nosniff" has "x-content-type-options: nosniff"
check "X-Frame-Options set" has "x-frame-options:"
check "Referrer-Policy: no-referrer" has "referrer-policy: no-referrer"
check "RateLimit headers set" has "ratelimit:"
check "X-Powered-By absent" bash -c '! grep -qi "^x-powered-by:" <<<"$1"' _ "$HEADERS"

curl -s -o /dev/null "$URL/smoke-qs?token=SMOKE_QUERY_SECRET"
sleep 0.3
check "query strings are not logged" bash -c '! grep -q SMOKE_QUERY_SECRET <<<"$1"' _ "$(logs)"
check "a 404 logs exactly one line" [ "$(logs | grep -c '/smoke-qs')" = 1 ]

# Half-open request (headers never finished) must not block shutdown forever.
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
printf 'GET / HTTP/1.1\r\nHost: smoke\r\n' >&3
T0=$SECONDS
docker stop -t 30 "$NAME" >/dev/null
ELAPSED=$((SECONDS - T0))
exec 3>&-
check "SIGTERM with a stuck client exits in <15s (took ${ELAPSED}s)" [ "$ELAPSED" -lt 15 ]
check "stuck-client shutdown was forced by the app, not docker" \
  [ "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" = 1 ]

# ---- TRUST_PROXY=1: spoofed X-Forwarded-For entries share one bucket --------
echo "== TRUST_PROXY=1"
start -e TRUST_PROXY=1

A="$(remaining "6.6.6.6, 9.9.9.9")"
B="$(remaining "7.7.7.7, 9.9.9.9")"
check "spoofed left-most XFF does not get a fresh bucket ($A -> $B)" [ "${B:-x}" = "$((${A:-0} - 1))" ]

T0=$SECONDS
docker stop -t 30 "$NAME" >/dev/null
ELAPSED=$((SECONDS - T0))
check "idle SIGTERM exits cleanly (code 0)" [ "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" = 0 ]
check "idle SIGTERM is fast (took ${ELAPSED}s)" [ "$ELAPSED" -lt 3 ]

# ---- TRUST_PROXY=true must be refused at startup ----------------------------
echo "== TRUST_PROXY=true"
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -e TRUST_PROXY=true -v "$WORK/public:/app/public:ro" "$IMAGE" >/dev/null
for _ in $(seq 25); do
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = false ] && break
  sleep 0.2
done
check "process exits instead of serving" [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = false ]
check "exit code is non-zero" [ "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" != 0 ]
check "fatal message explains why" grep -q "TRUST_PROXY=true" <<<"$(logs)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
