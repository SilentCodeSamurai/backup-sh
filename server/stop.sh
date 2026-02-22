#!/usr/bin/env bash
#
# Stop the backup server (kill process listening on PORT from server.env).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/server.env" ]]; then
  set +u
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/server.env"
  set -u
fi
: "${PORT:=9999}"

pid=$(lsof -t -i ":$PORT" 2>/dev/null || true)
if [[ -z "$pid" ]]; then
  echo "No process listening on port $PORT" >&2
  exit 0
fi
kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
echo "Stopped process $pid (port $PORT)"
