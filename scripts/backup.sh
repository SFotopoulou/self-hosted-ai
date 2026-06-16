#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/team-ai}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-team-ai}"
RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-14}"

usage() {
  cat <<'EOF'
Usage: backup.sh [--dir PATH] [--retain-days N]

Back up Team AI Docker volumes (Postgres, Open WebUI, Ollama embeddings).
Requires docker and read access to Docker volumes.

Environment:
  BACKUP_DIR          Destination directory (default: /var/backups/team-ai)
  BACKUP_RETAIN_DAYS  Delete backups older than N days (default: 14)
  COMPOSE_PROJECT_NAME  Compose project name (default: team-ai)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) BACKUP_DIR="$2"; shift 2 ;;
    --retain-days) RETAIN_DAYS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%F-%H%M%S)"

backup_volume() {
  local volume="$1"
  local label="$2"
  local archive="${BACKUP_DIR}/${label}-${STAMP}.tar.gz"

  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "Skipping missing volume: $volume" >&2
    return 0
  fi

  echo "Backing up $volume -> $archive"
  docker run --rm \
    -v "${volume}:/data:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine tar czf "/backup/$(basename "$archive")" -C /data .
}

backup_volume "${PROJECT_NAME}_postgres-data" "postgres"
backup_volume "${PROJECT_NAME}_open-webui-data" "webui"
backup_volume "${PROJECT_NAME}_ollama-data" "ollama"

find "$BACKUP_DIR" -name '*.tar.gz' -mtime +"$RETAIN_DAYS" -print -delete

echo "Backup complete: $BACKUP_DIR"
