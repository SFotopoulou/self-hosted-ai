#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
THRESHOLD_VRAM="${CAPACITY_VRAM_THRESHOLD:-0.90}"
THRESHOLD_QUEUE="${CAPACITY_QUEUE_THRESHOLD:-8}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

status="healthy"
msg1="All checks passed"
msg2=""
msg3=""
VRAM_RATIO=""
QUEUE_WAITING=""

if ! curl -fsS http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1; then
  status="degraded"
  msg1="LiteLLM health check failed"
fi

if ! docker compose -f "${ROOT_DIR}/docker-compose.yml" exec -T litellm curl -fsS http://vllm:8000/health >/dev/null 2>&1; then
  status="degraded"
  msg2="vLLM health check failed"
fi

if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
  VRAM_RATIO="$(curl -fsS --get http://127.0.0.1:9090/api/v1/query \
    --data-urlencode 'query=(DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE))' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin).get("data",{}).get("result",[]); print(r[0]["value"][1] if r else "")' 2>/dev/null || true)"

  QUEUE_WAITING="$(curl -fsS --get http://127.0.0.1:9090/api/v1/query \
    --data-urlencode 'query=vllm_num_requests_waiting' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin).get("data",{}).get("result",[]); print(r[0]["value"][1] if r else "0")' 2>/dev/null || true)"
fi

if [[ -n "$VRAM_RATIO" ]] && python3 -c "import sys; sys.exit(0 if float('${VRAM_RATIO}') < float('${THRESHOLD_VRAM}') else 1)"; then
  :
elif [[ -n "$VRAM_RATIO" ]]; then
  status="busy"
  msg3="GPU VRAM above ${THRESHOLD_VRAM}"
fi

if [[ -n "$QUEUE_WAITING" ]] && python3 -c "import sys; sys.exit(0 if float('${QUEUE_WAITING}') < float('${THRESHOLD_QUEUE}') else 1)"; then
  :
elif [[ -n "$QUEUE_WAITING" ]]; then
  status="busy"
  if [[ -n "$msg3" ]]; then
    msg3="${msg3}; vLLM queue ${QUEUE_WAITING}"
  else
    msg3="vLLM queue depth ${QUEUE_WAITING} (threshold ${THRESHOLD_QUEUE})"
  fi
fi

python3 - <<PY
import json
messages = [m for m in ["${msg1}", "${msg2}", "${msg3}"] if m]
print(json.dumps({
  "status": "${status}",
  "messages": messages,
  "metrics": {
    "gpu_vram_ratio": "${VRAM_RATIO}" or None,
    "vllm_queue_waiting": "${QUEUE_WAITING}" or None,
  },
  "webui_banner": (
    [{"type": "warning", "content": "High GPU load — responses may be slower than usual."}]
    if "${status}" == "busy" else None
  ),
}, indent=2))
PY

case "$status" in
  degraded) exit 2 ;;
  busy) exit 1 ;;
  *) exit 0 ;;
esac
