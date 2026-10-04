/**
 * Minimal, security-hardened static file server.
 * TS-first, ESM ("module"), single responsibility: serve a static directory.
 *
 * Env vars:
 *   PORT              default 8080
 *   HOST              default 0.0.0.0
 *   STATIC_DIR        default /app/public
 *   TRUST_PROXY       default false (hop count e.g. "1", or comma-separated proxy IPs/subnets; "true" is rejected)
 *   CACHE_MAX_AGE     default "1h"  (e.g. "0", "5m", "1d" — any `ms` string)
 *   ALLOWED_ORIGINS   default ""    (comma-separated; empty = same-origin only, no CORS headers sent)
 */

import path from "node:path";
import { fileURLToPath } from "node:url";
import fs from "node:fs";

import express, { type Request, type Response, type NextFunction } from "express";
import helmet from "helmet";
import compression from "compression";
import rateLimit from "express-rate-limit";
import ms from "ms";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---- Config -----------------------------------------------------------

const PORT = Number(process.env.PORT ?? 8080);
const HOST = process.env.HOST ?? "0.0.0.0";
const STATIC_DIR = path.resolve(process.env.STATIC_DIR ?? "/app/public");
const TRUST_PROXY = parseTrustProxy(process.env.TRUST_PROXY);
const CACHE_MAX_AGE = ms((process.env.CACHE_MAX_AGE ?? "1h") as ms.StringValue);
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

// `true` would trust the left-most X-Forwarded-For entry, which the client controls —
// letting anyone pick their own rate-limit key. Require an explicit hop count or proxy list.
function parseTrustProxy(raw = "false"): false | number | string[] {
  const v = raw.trim().toLowerCase();
  if (v === "" || v === "false" || v === "0") return false;
  if (v === "true") {
    console.error(
      "[fatal] TRUST_PROXY=true trusts client-supplied X-Forwarded-For; use a hop count (e.g. 1) or proxy subnet(s)",
    );
    process.exit(1);
  }
  if (/^\d+$/.test(v)) return Number(v);
  return v.split(",").map((s) => s.trim()).filter(Boolean); // e.g. "loopback,10.0.0.0/8"
}

if (!fs.existsSync(STATIC_DIR) || !fs.statSync(STATIC_DIR).isDirectory()) {
  // Fail fast and loud — a static server with no directory to serve is a misconfiguration, not a runtime error.
  console.error(`[fatal] STATIC_DIR does not exist or is not a directory: ${STATIC_DIR}`);
  process.exit(1);
}

// ---- App ----------------------------------------------------------------

const app = express();

// Only trust the proxy chain if explicitly told to (affects req.ip, rate-limit keys, etc.)
app.set("trust proxy", TRUST_PROXY);
app.disable("x-powered-by");

// Security headers. Default Helmet CSP is fine for a pure static file host;
// tighten/extend directives here if the served assets need specific sources.
app.use(
  helmet({
    contentSecurityPolicy: {
      useDefaults: true,
      directives: {
        "default-src": ["'self'"],
        "object-src": ["'none'"],
        "base-uri": ["'self'"],
        "frame-ancestors": ["'self'"],
      },
    },
    crossOriginResourcePolicy: { policy: "same-site" },
    referrerPolicy: { policy: "no-referrer" },
    hsts: { maxAge: 2592000, includeSubDomains: false, preload: false },
  }),
);

app.use(compression());

// Minimal CORS: only if the caller configured an allowlist. No `cors` package
// dependency needed for a rule this small, and it keeps the default (empty) posture closed.
if (ALLOWED_ORIGINS.length > 0) {
  app.use((req: Request, res: Response, next: NextFunction) => {
    const origin = req.headers.origin;
    if (origin && ALLOWED_ORIGINS.includes(origin)) {
      res.setHeader("Access-Control-Allow-Origin", origin);
      res.setHeader("Vary", "Origin");
      res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
    }
    if (req.method === "OPTIONS") {
      res.sendStatus(204);
      return;
    }
    next();
  });
}

// Basic abuse mitigation. Static-file hosts are cheap to serve but not free —
// this caps request storms per client without needing an upstream WAF.
app.use(
  rateLimit({
    windowMs: 60_000, // 100 RPS (6000req / 60sec)
    limit: 6000, // 100 RPS (6000req / 60sec)
    standardHeaders: "draft-7",
    legacyHeaders: false,
  }),
);

// Health check — kept outside the static root and before it, so it's always reachable
// regardless of what's in STATIC_DIR and never shadowed by a same-named file.
app.get("/healthz", (_req: Request, res: Response) => {
  res.status(200).json({ status: "ok" });
});

// Request logging - by the time we're here we want to know some details about each request.
// Logs the path only; query strings can carry tokens/PII and must stay out of logs.
app.use((req: Request, res: Response, next: NextFunction) => {
  const start = Date.now();
  res.on("finish", () => {
    console.log(
      `[handle] ${req.method} ${req.path} ${res.statusCode} ${Date.now() - start}ms`,
    );
  });
  next();
});

// Static file serving. Deliberately conservative:
//  - dotfiles denied (no leaking .env, .git, etc. if they ever end up in the dir)
//  - no directory index fallback beyond index.html (avoids exposing directory listings)
//  - symlinks ARE followed, even outside STATIC_DIR (operator's choice — see README)
app.use(
  express.static(STATIC_DIR, {
    dotfiles: "deny",
    index: "index.html",
    maxAge: CACHE_MAX_AGE,
    redirect: false,
    setHeaders: (res) => {
      res.setHeader("X-Content-Type-Options", "nosniff");
    },
  }),
);

// 404 for anything that isn't a real static asset.
// Already logged by the request logger above — no separate log line here.
app.use((_req: Request, res: Response) => {
  res.status(404).json({ error: "Not Found" });
});

// Last-resort error handler — never leak stack traces to clients.
app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
  console.error("[error]", err);
  res.status(500).json({ error: "Internal Server Error" });
});

// ---- Startup / graceful shutdown ----------------------------------------

const server = app.listen(PORT, HOST, () => {
  console.log(`[ready] serving ${STATIC_DIR} on http://${HOST}:${PORT}`);
});

// Slowloris guard: don't let a client hold a request open indefinitely.
server.headersTimeout = 5_000;
server.requestTimeout = 10_000;

const SHUTDOWN_TIMEOUT_MS = 5_000; // keep below compose stop_grace_period (15s)
let shuttingDown = false;

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    if (shuttingDown) {
      console.warn(`[shutdown] received second ${signal}, forcing exit`);
      process.exit(1);
    }
    shuttingDown = true;
    console.log(`[shutdown] received ${signal}, closing server...`);
    server.close((err) => {
      if (err) {
        console.error("[shutdown] error while closing server", err);
        process.exit(1);
      }
      process.exit(0);
    });
    // close() alone waits on every open socket; drop idle keep-alives now...
    server.closeIdleConnections();
    // ...and don't let a stuck or slow client hold the process hostage.
    setTimeout(() => {
      console.error(`[shutdown] connections still open after ${SHUTDOWN_TIMEOUT_MS}ms, forcing exit`);
      server.closeAllConnections();
      process.exit(1);
    }, SHUTDOWN_TIMEOUT_MS).unref();
  });
}
