#!/usr/bin/env bash
set -euo pipefail

SERVICE="opposite-osiris"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

find_repo_root() {
  local dir="$PROJECT_DIR"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/docker-compose.yml" || -f "$dir/compose.yml" || -f "$dir/compose.yaml" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

REPO_ROOT="$(find_repo_root || true)"
if [[ -z "${REPO_ROOT}" ]]; then
  echo "Could not find repository root with docker compose file." >&2
  echo "Run this script from inside the repo, or set REPO_ROOT manually." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed or not in PATH." >&2
  exit 1
fi

cd "$REPO_ROOT"

if ! docker compose ps --status running "$SERVICE" >/dev/null 2>&1; then
  echo "Service '$SERVICE' is not running. Starting it now..." >&2
  docker compose up -d --build "$SERVICE"
fi

usage() {
  cat <<'EOF'
Docker-first workflow helper for opposite-osiris.

Usage:
  ./scripts/docker-workflow.sh dev
  ./scripts/docker-workflow.sh shell
  ./scripts/docker-workflow.sh pnpm <args>
  ./scripts/docker-workflow.sh node <args>
  ./scripts/docker-workflow.sh logs
  ./scripts/docker-workflow.sh exec <raw command>

Examples:
  ./scripts/docker-workflow.sh pnpm run lint
  ./scripts/docker-workflow.sh pnpm run check
  ./scripts/docker-workflow.sh exec ls -la
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  dev)
    docker compose logs -f "$SERVICE"
    ;;
  shell)
    docker compose exec "$SERVICE" sh
    ;;
  pnpm)
    docker compose exec "$SERVICE" pnpm "$@"
    ;;
  npm)
    # backward-compat alias → routes to pnpm
    docker compose exec "$SERVICE" pnpm "$@"
    ;;
  node)
    docker compose exec "$SERVICE" node "$@"
    ;;
  logs)
    docker compose logs --tail=200 "$SERVICE"
    ;;
  exec)
    if [[ $# -eq 0 ]]; then
      echo "Missing command for 'exec'." >&2
      exit 1
    fi
    docker compose exec "$SERVICE" "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 1
    ;;
esac
