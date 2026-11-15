# JLud2D in a container — for playing the built game and for development.
#
# Works with Podman (rootless included) as well as Docker: base images are
# fully qualified, no BuildKit-only syntax (no `# syntax=` directive, no
# `RUN --mount`) is used, and the runtime stages need no privileged ports or
# host bind mounts.
#
#   podman build -t jlud2d:play .              # static site served by nginx (:8080)
#   podman build --target dev -t jlud2d:dev .  # Vite dev server with HMR (:3080)
#   podman build --target test -t jlud2d:test . # type-check + unit tests
#
# See "Run with Podman or Docker" in README.md for the matching run commands.

ARG NODE_IMAGE=docker.io/library/node:22-alpine
ARG WEB_IMAGE=docker.io/nginxinc/nginx-unprivileged:1.30-alpine

# --------------------------------------------------------------- dependencies
FROM ${NODE_IMAGE} AS deps
WORKDIR /app

ENV npm_config_update_notifier=false \
    npm_config_fund=false

# Install from the lockfile first so this layer stays cached until dependencies
# actually change.
COPY package.json package-lock.json ./
RUN npm ci

# ------------------------------------------------------------------- develop
# Vite dev server. docker-compose.yml bind-mounts the repository over /app so
# edits trigger hot reload; the image also carries the source so it can be run
# standalone.
FROM deps AS dev
WORKDIR /app

# BROWSER=none stops Vite from trying to launch a browser inside the container.
ENV BROWSER=none

COPY . .

EXPOSE 3080
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", "3080"]

# ----------------------------------------------------------------------- test
# Type-check plus the Vitest suite. Useful as a CI gate or a pre-commit check.
FROM deps AS test
WORKDIR /app

COPY . .

RUN npm run type-check && npm test

# --------------------------------------------------------------------- build
# Production build (tsc + vite build). The optional VITE_SUPABASE_* build args
# enable the "Phantasy Cloud" feature; without them the game builds and runs
# normally, with cloud save reported as unavailable.
FROM deps AS build
WORKDIR /app

ARG VITE_SUPABASE_URL=""
ARG VITE_SUPABASE_ANON_KEY=""
ENV VITE_SUPABASE_URL=${VITE_SUPABASE_URL} \
    VITE_SUPABASE_ANON_KEY=${VITE_SUPABASE_ANON_KEY}

COPY . .
RUN npm run build

# ---------------------------------------------------------------------- play
# The nginx-unprivileged image runs as uid 101 and listens on 8080, so it works
# unchanged under rootless Podman.
FROM ${WEB_IMAGE} AS play

LABEL org.opencontainers.image.title="JLud2D" \
      org.opencontainers.image.description="JLud2D game engine (TypeScript + Phaser port) served as a static site" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1
