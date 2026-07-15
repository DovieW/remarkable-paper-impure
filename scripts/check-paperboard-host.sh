#!/usr/bin/env bash

set -Eeuo pipefail

readonly MIN_DOCKER="29.4.2"
readonly MIN_COMPOSE="5.1.2"

version_at_least() {
  local actual=$1 minimum=$2
  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" == "$minimum" ]]
}

command -v node >/dev/null || { printf 'Node.js 24 or newer is required.\n' >&2; exit 1; }
command -v pnpm >/dev/null || { printf 'pnpm is required.\n' >&2; exit 1; }
command -v docker >/dev/null || { printf 'Docker is required for container deployment.\n' >&2; exit 1; }

node_major=$(node -p 'process.versions.node.split(".")[0]')
(( node_major >= 24 )) || { printf 'Node.js 24 or newer is required; found %s.\n' "$(node --version)" >&2; exit 1; }

docker_version=$(docker version --format '{{.Server.Version}}')
compose_version=$(docker compose version --short)
printf 'Node: %s\npnpm: %s\nDocker Engine: %s\nDocker Compose: %s\n' "$(node --version)" "$(pnpm --version)" "$docker_version" "$compose_version"

if ! version_at_least "$docker_version" "$MIN_DOCKER" || ! version_at_least "$compose_version" "$MIN_COMPOSE"; then
  printf 'Terminus 0.65.0 requires Docker Engine %s+ and Compose %s+. Upgrade the host before starting deploy/terminus.\n' "$MIN_DOCKER" "$MIN_COMPOSE" >&2
  exit 2
fi
printf 'Host meets the Paperboard and Terminus prerequisites.\n'
