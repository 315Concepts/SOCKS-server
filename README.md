# Static-Origin-Content-Kwik-Serve (SOCKS) Server

A hyper-modern Node/Express static content server in Typescript.

## Overview

One job: Use the latest NodeJS ecosystem tools to serve a directory of static files - with sensible security headers, rate limiting, and a health check out of the box. SOCKS can run directly from the host or be deployed via a batteries-included container for cloud workloads. Regardless of the deployment model, SOCKS provides a turnkey solution for developers needing a production ready static content server that can be easily be extended or modified as necessary without having to waste time trying to rebuild the foundation.

## Stack versions

These are the versions we track. When one moves, this table moves.

| Component  | Version   | Source                         | Notes                                         |
| ---------- | --------- | ------------------------------ | --------------------------------------------- |
| Alpine     | 3.24.2    | `node:24-alpine` base image    | Floating tag; SHA pinned 2026-10-04           |
| Node.js    | 24.21.0   | `node:24-alpine` base image    | Active LTS ("Krypton"), EOL 2028-04-30        |
| NPM        | 11.19.0   | `node:24-alpine` base image    |                                               |
| Express    | 5.2.1     | `package.json` / lockfile      |                                               |
| TypeScript | 7.0.2     | `package.json` (dev only)      | Build-time only; not in the runtime image     |

Supporting runtime deps:
- **compression**: 1.8.2
- **express-rate-limit**: 8.7.0
- **helmet**: 8.3.0
- **ms**: 2.1.3

## Quick Start

Run from host:

```sh
npm install          # dev tooling + lockfile
npm run compile
STATIC_DIR=./public PORT=8080 node dist/index.js
```

Run from Docker Compose:

```sh
npm run build        # docker build -> socks-server:latest
mkdir -p public && echo '<h1>hello</h1>' > public/index.html
npm start            # docker compose up
# http://localhost:8080
npm run stop         # docker compose down
```

Run as a plain host container:

```sh
npm run build
mkdir -p public && echo '<h1>hello</h1>' > public/index.html
docker run --rm -it --name socks-server \
  -p 8080:8080 \
  -v "$PWD/public:/app/public:ro" \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true --init \
  -e CACHE_MAX_AGE=0 \
  socks-server:latest
# http://localhost:8080 — Ctrl-C to stop
```

- **Same lockdown as Compose,** minus the resource limits and log rotation. Keep the hardening flags; dropping them is how "works in testing" drifts from production.
- **`CACHE_MAX_AGE=0`** stops the browser caching files while you edit them. Any additional [configuration](#configuration) variables can be passed the same way with `-e`.
- **Permissions:** the container runs as a non-root user, so files in `public/` must be world-readable.

### Behind Traefik Proxy

Standard Traefik Docker labels work as-is; SOCKS needs nothing Traefik-specific. For a single-host setup (Traefik and SOCKS on the same Docker host), the only **required** change is putting SOCKS on Traefik's shared backend network. `docker-compose.yaml` already has it, commented out as `traefik_backend`; uncomment both blocks.

```yaml
services:
  static:
    # ...everything else as in docker-compose.yaml...
    environment:
      TRUST_PROXY: "1"            # recommended: Traefik is one hop in front
    # ports:                      # recommended: remove port bindings from host so all traffic goes through Traefik
    #   - "8080:8080"
    networks:
      - traefik_backend
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik_backend
      - traefik.http.routers.socks.rule=Host(`static.example.com`)
      - traefik.http.routers.socks.entrypoints=websecure
      - traefik.http.routers.socks.tls.certresolver=letsencrypt
      - traefik.http.services.socks.loadbalancer.server.port=8080

networks:
  traefik_backend:
    external: true
```

Adjust the entrypoint and cert resolver names to match your Traefik config.

The additional **recommended** changes:

- **`TRUST_PROXY=1`:** without it, every request appears to come from Traefik, so all visitors share one rate-limit bucket.
- **Remove the published port:** Traefik reaches the container over the shared network, so `ports:` isn't needed. If you leave it, clients can skip Traefik and spoof `X-Forwarded-For`.
- **Health checks:** Traefik respects the container's Docker health status and won't route to it until `/healthz` passes.
- **HSTS:** if Traefik already sets HSTS (for example through a `headers` middleware), consider turning it off in SOCKS so there's a single source of truth. See [HSTS](#hsts).


## Configuration

All configuration is through environment variables.

| Variable          | Default       | Description |
| ----------------- | ------------- | ----------- |
| `PORT`            | `8080`        | Listen port. |
| `HOST`            | `0.0.0.0`     | Listen address. |
| `STATIC_DIR`      | `/app/public` | Directory to serve. The server exits at startup if it is missing. |
| `TRUST_PROXY`     | `false`       | Hop count (`1`) or comma-separated proxy IPs/subnets. `true` is rejected. See [Proxies](#proxies). |
| `CACHE_MAX_AGE`   | `1h`          | `Cache-Control: max-age` for files, as an [`ms`](https://github.com/vercel/ms) string (`0`, `5m`, `1d`). |
| `ALLOWED_ORIGINS` | *(empty)*     | Comma-separated exact origins allowed for CORS. Empty = no CORS headers. `*` is not supported. |

## Operations

- **Health check:** `GET /healthz` returns `200 {"status":"ok"}`. It is served before the static handler, so a file named `healthz` can never shadow it. The image and compose file both use it.
- **Logs:** one line per request to stdout: `[handle] METHOD /path STATUS DURATIONms`. Query strings are deliberately **not** logged because they often carry tokens. Compose rotates logs at 10MB × 3 files.
- **Shutdown:** `SIGTERM`/`SIGINT` stops accepting connections, drops idle keep-alive connections, and exits once in-flight requests finish. If connections are still open after 5s they are closed and the process exits with code 1. A second signal forces an immediate exit. Compose allows 15 s before it kills the container.
- **Timeouts:** request headers must arrive within 5s and the whole request within 10s, which limits slow-client (slowloris) attacks.
- **Container hardening (compose):** read-only root filesystem, static dir mounted read-only, non-root user, `cap_drop: ALL`, `no-new-privileges`, `init: true`, and limits of 256MB memory, 1vCPU and 64 PIDs. Raise the limits if your traffic needs it.
- **Behaviour:** `index.html` is served for directory paths that end in `/`. A directory path without the trailing slash returns 404; there is no redirect. There is no directory listing and no SPA fallback.

## Scripts

Both scripts need Docker and take an optional image name (default `socks-server:latest`). Pass it through npm with `--`, e.g. `npm run smoke -- socks-server:1.2.3`.

| Command            | Script                    | What it does |
| ------------------ | ------------------------- | ------------ |
| `npm run versions` | `scripts/versions.sh`     | Prints the [stack versions](#stack-versions) (Alpine and Node read from inside the image; Express and TypeScript from `package-lock.json`), then every dependency with its range and locked version. If the image isn't built yet, it reads the Dockerfile's base image instead. |
| `npm run smoke`    | `scripts/smoke-test.sh`   | Runs the built image locked down like compose (read-only, all capabilities dropped, non-root) on a random local port. Then it checks the behaviour this README promises. Exits non-zero if any check fails. |

The smoke test covers:

- **Serving:** health check, index pages, the no-redirect behaviour, and a 404 for unknown paths.
- **Blocked paths:** dotfiles and path traversal return 404 without leaking contents.
- **Headers:** CSP, HSTS, `nosniff`, `X-Frame-Options`, `Referrer-Policy` and rate-limit headers are present; `X-Powered-By` is absent.
- **Logging:** query strings are never logged, and each request logs exactly one line.
- **Shutdown:** a stuck client is cut off by the app's own deadline, not killed by Docker; an idle shutdown exits 0 immediately.
- **Proxies:** with `TRUST_PROXY=1`, spoofed `X-Forwarded-For` entries share one rate-limit bucket; `TRUST_PROXY=true` is refused at startup.

Typical release check:

```sh
npm run build && npm run smoke && npm run versions
```

## Security notes

### HSTS

- **max-age is 30 days.** Once a browser has seen this header over HTTPS, it refuses plain HTTP to that host for 30 days.
- **`preload` is off.** We never submit to browser preload lists on your behalf.
- **Over plain HTTP the header has no effect.** Browsers ignore HSTS on non-HTTPS responses, so running on plain HTTP (local dev, behind a TLS-terminating proxy on an internal hop) is unaffected.
- **Changing it:** HSTS is not exposed as an env var. Edit the `hsts` option in the `helmet()` call in `src/index.ts`. If TLS is terminated at a CDN or load balancer that already sets HSTS, consider disabling it here (`hsts: false`) so there is a single source of truth.

The default Content-Security-Policy also includes `upgrade-insecure-requests`, so pages that reference `http://` sub-resources will have them upgraded to HTTPS.

### Symlinks

Symlinks inside `STATIC_DIR` are followed, **including links that point outside it**. This is intentional: what goes into the served directory is the operator's choice. If you don't fully control and want to publish the directory contents, don't symlink to it, or check for them before deploying (`find public -type l`).

Dotfiles (`.env`, `.git/…`) and path traversal (`/../`, `%2e%2e`) **always** return 404.

### Rate limiting

Each client IP gets 6000 requests per minute (about 100 RPS). The counter is in memory, per process.

- CORS preflight (`OPTIONS`) requests are answered before the rate limiter runs when `ALLOWED_ORIGINS` is set, so preflights are **not** rate limited by default.

### Proxies

`TRUST_PROXY` controls which `X-Forwarded-For` entries are believed when working out the client IP, which is also the rate-limit key.

| Value                        | Use when                                    |
| ---------------------------- | ------------------------------------------- |
| `false` (default)            | Clients connect directly.                   |
| `1`, `2`, …                  | That many reverse proxies / load balancers sit in front. |
| `loopback,10.0.0.0/8`, …     | Your proxies have known addresses or subnets ([Express syntax](https://expressjs.com/en/guide/behind-proxies.html)). |

- **Behind a proxy with `false`:** every request appears to come from the proxy, so all clients share one rate-limit bucket.
- **`true` is refused at startup.** It would trust the left-most `X-Forwarded-For` entry, which the client controls, so anyone could choose their own rate-limit key.
- **The hop count must match reality, and the server must only be reachable through the proxy.** With `TRUST_PROXY=1`, the right-most `X-Forwarded-For` entry is used. Your proxy appends the real client IP there, so spoofed entries further left are ignored. If clients can reach the server directly, they become the "one trusted hop" and can set that entry themselves.

## About the Name

SOCKS stands for Static-Origin-Content-Kwik-Serve. Any resemblance to a certain tuxedo cat named Socks who supervised development from the la-z-boy in the living room is purely coincidental.

That said, here is Socks: four white paws, verily zero interest in static file serving.

<p>
  <img src="socks/SOCKS-00.jpg" alt="Socks giving the camera a skeptical look" height="280">
  <img src="socks/SOCKS-03.jpg" alt="Socks sleeping on her heated mattress" height="280">
  <img src="socks/SOCKS-01.jpg" alt="Socks watches the neighborhood traffic" height="280">
  <img src="socks/SOCKS-02.jpg" alt="Socks showing off her socks" height="280">
</p>

Adorable Intelligence Disclaimer: She has neither generated nor reviewed any of the included code. Her graceful-shutdown handling is, however, exemplary - we continue having much to learn.
