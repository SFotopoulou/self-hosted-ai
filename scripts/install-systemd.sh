#!/usr/bin/env bash
# Install the team-ai systemd unit for boot-time startup.
#
# Usage:
#   sudo ./scripts/install-systemd.sh [/opt/team-ai]
#
# Defaults to the directory containing this repository if no path is given.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${1:-${REPO_DIR}}"
SERVICE_NAME="team-ai.service"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: run as root (e.g. sudo $0)" >&2
  exit 1
fi

if [[ ! -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
  echo "Error: docker-compose.yml not found in ${INSTALL_DIR}" >&2
  exit 1
fi

if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  echo "Warning: ${INSTALL_DIR}/.env not found. Create it before starting the service." >&2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is not installed or not in PATH" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Error: 'docker compose' plugin is required" >&2
  exit 1
fi

echo "Installing systemd unit for ${INSTALL_DIR} ..."

sed "s|@INSTALL_DIR@|${INSTALL_DIR}|g" \
  "${REPO_DIR}/systemd/team-ai.service" > "${SERVICE_DST}"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

echo ""
echo "Installed: ${SERVICE_DST}"
echo ""
echo "Commands:"
echo "  sudo systemctl start ${SERVICE_NAME}    # start stack now"
echo "  sudo systemctl status ${SERVICE_NAME}   # check status"
echo "  sudo systemctl stop ${SERVICE_NAME}     # stop stack"
echo "  journalctl -u ${SERVICE_NAME} -f        # view logs"
echo ""
echo "The stack will start automatically on boot."
echo "Monitor vLLM model loading: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f vllm"
