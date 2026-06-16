#!/usr/bin/env bash
# Wrapper for scripts/load-test.py — loads .env from the repo root if present.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_DIR}/.env"
  set +a
fi

export LITELLM_API_KEY="${LITELLM_API_KEY:-${LITELLM_MASTER_KEY:-}}"

exec python3 "${SCRIPT_DIR}/load-test.py" "$@"
