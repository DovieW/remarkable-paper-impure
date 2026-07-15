#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

command -v node >/dev/null || { printf 'Node.js 24 or newer is required.\n' >&2; exit 1; }
command -v pnpm >/dev/null || { printf 'pnpm is required.\n' >&2; exit 1; }
command -v docker >/dev/null || { printf 'Docker is required for container deployment.\n' >&2; exit 1; }

node_major=$(node -p 'process.versions.node.split(".")[0]')
(( node_major >= 24 )) || { printf 'Node.js 24 or newer is required; found %s.\n' "$(node --version)" >&2; exit 1; }

docker info >/dev/null 2>&1 || { printf 'The Docker daemon is not reachable.\n' >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { printf 'The Docker Compose plugin is required.\n' >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { printf 'Docker Buildx is required to build the Paperboard relay.\n' >&2; exit 1; }

printf 'Node: %s\npnpm: %s\nDocker Engine: %s\nDocker Compose: %s\nBuildx: %s\n' \
  "$(node --version)" "$(pnpm --version)" \
  "$(docker version --format '{{.Server.Version}}')" \
  "$(docker compose version --short)" \
  "$(docker buildx version | awk '{print $2}')"

PAPERBOARD_PUBLIC_BASE_URL=https://paperboard.invalid \
PAPERBOARD_SECRET_GID="$(id -g)" \
  docker compose -f "$REPOSITORY_ROOT/deploy/relay/compose.yml" config --quiet

TERMINUS_PUBLIC_URL=https://terminus.invalid \
TERMINUS_APP_SECRET=capability-check-only \
TERMINUS_DATABASE_PASSWORD=capability-check-only \
TERMINUS_KEYVALUE_PASSWORD=capability-check-only \
  docker compose -f "$REPOSITORY_ROOT/deploy/terminus/compose.yml" config --quiet

printf 'Docker can parse the Paperboard and Terminus deployment definitions.\n'
