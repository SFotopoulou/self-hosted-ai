#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * *}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/team-ai}"

usage() {
  cat <<'EOF'
Usage: install-backup-cron.sh [--schedule "0 3 * * *"] [--dir PATH]

Installs a cron job for scripts/backup.sh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --schedule) CRON_SCHEDULE="$2"; shift 2 ;;
    --dir) BACKUP_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

chmod +x "${ROOT_DIR}/scripts/backup.sh"
CRON_LINE="${CRON_SCHEDULE} BACKUP_DIR=${BACKUP_DIR} ${ROOT_DIR}/scripts/backup.sh >> /var/log/team-ai-backup.log 2>&1"

( crontab -l 2>/dev/null | grep -v "scripts/backup.sh" || true
  echo "$CRON_LINE"
) | crontab -

echo "Installed cron job:"
echo "  $CRON_LINE"
