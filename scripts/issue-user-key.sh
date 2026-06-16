#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${LITELLM_MASTER_KEY:?Set LITELLM_MASTER_KEY in .env or environment}"
: "${LITELLM_BASE_URL:=http://127.0.0.1:4000}"

USER_ALIAS=""
RPM_LIMIT="${USER_RPM_LIMIT:-30}"
TPM_LIMIT="${USER_TPM_LIMIT:-100000}"
MAX_PARALLEL="${USER_MAX_PARALLEL:-3}"

usage() {
  cat <<'EOF'
Usage: issue-user-key.sh --alias USERNAME [--rpm N] [--tpm N] [--max-parallel N]

Generate a per-user LiteLLM API key for usage tracking and IDE/WebUI connections.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias) USER_ALIAS="$2"; shift 2 ;;
    --rpm) RPM_LIMIT="$2"; shift 2 ;;
    --tpm) TPM_LIMIT="$2"; shift 2 ;;
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$USER_ALIAS" ]]; then
  echo "Error: --alias is required" >&2
  usage
  exit 1
fi

RESPONSE="$(curl -fsS -X POST "${LITELLM_BASE_URL%/}/key/generate" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"key_alias\": \"${USER_ALIAS}\",
    \"models\": [\"gemma-4-31b\"],
    \"rpm_limit\": ${RPM_LIMIT},
    \"tpm_limit\": ${TPM_LIMIT},
    \"max_parallel_requests\": ${MAX_PARALLEL}
  }")"

KEY="$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))')"

if [[ -z "$KEY" ]]; then
  echo "Failed to parse key from LiteLLM response:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

cat <<EOF
Issued LiteLLM key for: ${USER_ALIAS}

API key: ${KEY}

Open WebUI: Settings → Connections → add OpenAI connection
  Base URL: http://localhost:4000/v1  (via SSH/Tailscale)
  API key:  ${KEY}

VS Code / Roo Code: use the same base URL, key, and model gemma-4-31b

Usage is tracked per key in LiteLLM Admin UI: ${LITELLM_BASE_URL%/}/ui
EOF
