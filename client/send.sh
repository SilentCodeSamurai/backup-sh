#!/usr/bin/env bash
#
# Backup client: upload files or directories to the backup server.
# Server identifies this client by connection source IP.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/client.env" ]]; then
  set +u
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/client.env"
  set -u
fi

: "${KEY_FILE:=${HOME:-/tmp}/.backup-sh-key}"
: "${LOG_FILE:=}"
SERVER_URL="${SERVER_URL:-}"
FILE_OR_DIR=""
INSECURE=""

log_info()  { log_level "INFO"  "$*"; }
log_warn()  { log_level "WARN"  "$*"; }
log_error() { log_level "ERROR" "$*"; }

log_level() {
  local level="$1"
  shift
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local msg="${ts} [${level}] $*"
  echo "$msg" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}

usage() {
  echo "Usage: $0 [server_url] <file_or_dir> [options]" >&2
  echo "  server_url   Base URL (e.g. http://backup-server:9999); optional if set in client.env" >&2
  echo "  file_or_dir  File or directory to upload (directories sent recursively)" >&2
  echo "Options:" >&2
  echo "  --key-file PATH   Use this file for access key" >&2
  echo "  --insecure        Skip TLS verification (curl -k)" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-file)
      [[ $# -gt 1 ]] || usage
      KEY_FILE="$2"
      shift 2
      ;;
    --insecure)
      INSECURE="-k"
      shift
      ;;
    -*)
      usage
      ;;
    *)
      if [[ -z "$SERVER_URL" ]]; then
        SERVER_URL="$1"
      elif [[ -z "$FILE_OR_DIR" ]]; then
        FILE_OR_DIR="$1"
      else
        usage
      fi
      shift
      ;;
  esac
done

if [[ -z "$FILE_OR_DIR" ]]; then
  usage
fi
if [[ -z "$SERVER_URL" ]]; then
  log_error "SERVER_URL not set. Set it in client.env or pass as first argument."
  usage
fi

if [[ -n "${LOG_FILE:-}" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
fi

SERVER_URL="${SERVER_URL%/}"
UPLOAD_URL="${SERVER_URL}/upload"

ACCESS_KEY="${BACKUP_ACCESS_KEY:-${ACCESS_KEY:-}}"
if [[ -z "$ACCESS_KEY" ]] && [[ -f "$KEY_FILE" ]]; then
  ACCESS_KEY=$(cat "$KEY_FILE")
  ACCESS_KEY="${ACCESS_KEY%"${ACCESS_KEY##*[![:space:]]}"}"
  ACCESS_KEY="${ACCESS_KEY#"${ACCESS_KEY%%[![:space:]]*}"}"
fi
if [[ -z "$ACCESS_KEY" ]]; then
  log_error "Access key not set. Set BACKUP_ACCESS_KEY or put key in ${KEY_FILE} or use --key-file"
  exit 1
fi

if [[ ! -e "$FILE_OR_DIR" ]]; then
  log_error "Path does not exist: ${FILE_OR_DIR}"
  exit 1
fi

upload_file() {
  local abs_path="$1"
  local relative_path="$2"
  local size
  size=$(stat -c %s "$abs_path" 2>/dev/null || echo "?")
  log_info "uploading path=${relative_path} size=${size}"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "X-Access-Key: ${ACCESS_KEY}" \
    -H "X-File-Path: ${relative_path}" \
    --data-binary "@${abs_path}" \
    $INSECURE \
    "$UPLOAD_URL")
  if [[ "$code" != "200" ]]; then
    log_error "upload failed path=${relative_path} http_code=${code}"
    return 1
  fi
  log_info "uploaded path=${relative_path} http_code=${code}"
  return 0
}

FAILED=0
if [[ -f "$FILE_OR_DIR" ]]; then
  base=$(basename "$FILE_OR_DIR")
  if ! upload_file "$FILE_OR_DIR" "$base"; then
    FAILED=1
  fi
elif [[ -d "$FILE_OR_DIR" ]]; then
  dir_abs=$(cd "$FILE_OR_DIR" && pwd)
  while IFS= read -r -d '' f; do
    rel="${f#"$dir_abs/"}"
    rel="${rel#/}"
    if ! upload_file "$f" "$rel"; then
      FAILED=1
    fi
  done < <(find "$dir_abs" -type f -print0 2>/dev/null)
else
  log_error "Not a file or directory: ${FILE_OR_DIR}"
  exit 1
fi

[[ $FAILED -eq 0 ]] || exit 1
