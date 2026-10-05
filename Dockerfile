# syntax=docker/dockerfile:1

##
## ---- build stage: install deps + compile TS -> JS ------------------------
##
FROM node:26-alpine@sha256:b341ca66519d9a1c25d4e41f254ffb6fe403fc0f9054c62b863f0660dcc1c199 AS build
WORKDIR /app

# Install exactly what the lockfile pins (dev deps included, for tsc/types).
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run compile

# Drop dev dependencies, leaving only what's needed to run the compiled output.
RUN npm prune --omit=dev

##
## ---- runtime stage: minimal, non-root, read-only-friendly ----------------
##
FROM node:26-alpine@sha256:b341ca66519d9a1c25d4e41f254ffb6fe403fc0f9054c62b863f0660dcc1c199 AS runtime
ENV NODE_ENV=production
WORKDIR /app

# Non-root user with no shell/login — this process only needs to bind a port
# and read files, never to be interactively logged into.
RUN addgroup -S app && adduser -S app -G app -H -s /sbin/nologin

COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

ENV PORT=8080 \
    HOST=0.0.0.0 \
    STATIC_DIR=/app/public \
    TRUST_PROXY=false \
    CACHE_MAX_AGE=1h \
    ALLOWED_ORIGINS=

EXPOSE 8080

USER app

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/index.js"]