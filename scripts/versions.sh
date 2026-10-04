#!/usr/bin/env bash
# Print the stack versions tracked in README.md, plus the full dependency lists.
#
# Usage: scripts/versions.sh [image]
#   image  defaults to socks-server:latest; if that isn't built locally, the
#          Dockerfile's base image is used for the Alpine/Node versions instead.
#
# npm versions come from package-lock.json — that's what `npm ci` ships, not
# whatever happens to be in node_modules.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:-socks-server:latest}"
BASE_IMAGE="$(awk '/^FROM/ { print $2; exit }' Dockerfile)"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "note: $IMAGE is not built locally; reading Alpine/Node from base image $BASE_IMAGE" >&2
  IMAGE="$BASE_IMAGE"
fi

read -r ALPINE NODE NPM < <(
  docker run --rm --entrypoint sh "$IMAGE" -c 'echo "$(cat /etc/alpine-release) $(node --version) $(npm --version)"'
)

node - "$IMAGE" "$ALPINE" "$NODE" "$NPM" <<'EOF'
const fs = require("node:fs");
const [image, alpine, node, npm] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
const locked = (name) => lock.packages?.[`node_modules/${name}`]?.version ?? "(not locked)";

const table = (rows) => {
  const w = rows.reduce((m, r) => r.map((c, i) => Math.max(m[i] ?? 0, c.length)), []);
  for (const r of rows) console.log("  " + r.map((c, i) => c.padEnd(w[i])).join("   ").trimEnd());
};

console.log("== Stack (README tracking axis) ==");
table([
  ["Alpine", alpine, image],
  ["Node.js", node.replace(/^v/, ""), image],
  ["NPM", npm.replace(/^v/, ""), image],
  ["Express", locked("express"), "package-lock.json"],
  ["TypeScript", locked("typescript"), "package-lock.json"],
]);

for (const [title, deps] of [
  ["Runtime dependencies", pkg.dependencies ?? {}],
  ["Dev dependencies", pkg.devDependencies ?? {}],
]) {
  console.log(`\n== ${title} ==`);
  table([["package", "range", "locked"], ...Object.entries(deps).map(([n, r]) => [n, r, locked(n)])]);
}
EOF
