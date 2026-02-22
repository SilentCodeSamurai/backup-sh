#!/usr/bin/env bash
#
# Backup server: receives uploads over HTTP, stores per client IP, enforces
# MAX_SIZE_PER_CLIENT by deleting oldest files when limit exceeded.
# Run as daemon; clients identified by connection source IP (SOCAT_PEERADDR).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load server.env from script directory if present
if [[ -f "${SCRIPT_DIR}/server.env" ]]; then
  set +u
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/server.env"
  set -u
fi

# --- Config (override with env) ---
: "${BACKUP_ROOT:=/var/backups/incoming}"
: "${PORT:=9999}"
: "${ACCESS_KEY:=}"
: "${MAX_SIZE_PER_CLIENT:=1G}"
: "${LOG_FILE:=/var/log/backup-server.log}"

# Convert human-readable size to bytes (e.g. 1G, 500M)
parse_size() {
  local v="$1"
  if [[ "$v" =~ ^([0-9]+)([gGmMkK])?$ ]]; then
    local n="${BASH_REMATCH[1]}"
    local u="${BASH_REMATCH[2]:-}"
    case "$u" in
      g|G) echo $((n * 1024 * 1024 * 1024)); return ;;
      m|M) echo $((n * 1024 * 1024)); return ;;
      k|K) echo $((n * 1024)); return ;;
      *)   echo "$n"; return ;;
    esac
  fi
  echo "$v"
}

MAX_BYTES=$(parse_size "$MAX_SIZE_PER_CLIENT")

# Export so handler child (via socat EXEC) inherits
export BACKUP_ROOT PORT ACCESS_KEY MAX_BYTES LOG_FILE SCRIPT_DIR

# --- Logging ---
log_info()  { log_level "INFO"  "$*"; }
log_warn()  { log_level "WARN"  "$*"; }
log_error() { log_level "ERROR" "$*"; }

log_level() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} [${level}] ${msg}" >> "$LOG_FILE"
  # When not in handler (daemon foreground), also to stdout
  if [[ -z "${BACKUP_HANDLER:-}" ]]; then
    echo "${ts} [${level}] ${msg}" >&2
  fi
}

# --- Handler: process one HTTP request (stdin/stdout = socket) ---
run_handler() {
  local client_id="${SOCAT_PEERADDR:-unknown}"
  # Sanitize for directory name (IPv6 colons -> underscore)
  client_id="${client_id//:/_}"
  if [[ "$client_id" == "unknown" ]]; then
    log_warn "client_id unknown (SOCAT_PEERADDR unset)"
  fi

  local request_line
  if ! read -r request_line; then
    log_error "client=${client_id} read request line failed"
    send_response 400 "Bad Request"
    return
  fi

  # Parse headers
  local content_length=0
  local x_access_key=""
  local x_file_path=""
  local line
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" ]] && break
    if [[ "$line" =~ ^[Cc]ontent-[Ll]ength:\ *([0-9]+) ]]; then
      content_length="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[Xx]-[Aa]ccess-[Kk]ey:\ *(.*) ]]; then
      x_access_key="${BASH_REMATCH[1]}"
      x_access_key="${x_access_key#"${x_access_key%%[![:space:]]*}"}"
    elif [[ "$line" =~ ^[Xx]-[Ff]ile-[Pp]ath:\ *(.*) ]]; then
      x_file_path="${BASH_REMATCH[1]}"
      x_file_path="${x_file_path#"${x_file_path%%[![:space:]]*}"}"
    fi
  done

  # Auth
  if [[ -z "$ACCESS_KEY" ]] || [[ "$x_access_key" != "$ACCESS_KEY" ]]; then
    log_warn "client=${client_id} auth failed (key mismatch or missing)"
    send_response 403 "Forbidden"
    return
  fi

  # File path: default to a safe name if not provided
  if [[ -z "$x_file_path" ]]; then
    x_file_path="upload-$(date +%s).bin"
  fi
  # Sanitize: no leading /, no ..
  x_file_path="${x_file_path#/}"
  while [[ "$x_file_path" == *"/../"* ]] || [[ "$x_file_path" == "../"* ]] || [[ "$x_file_path" == *"/.." ]]; do
    x_file_path="${x_file_path//\/../\/}"
    x_file_path="${x_file_path#../}"
    x_file_path="${x_file_path%/..}"
  done
  # Allow only safe chars: alphanumeric, _, -, /, .
  if [[ "$x_file_path" =~ [^a-zA-Z0-9_\-/.] ]]; then
    log_warn "client=${client_id} invalid file path (unsafe chars)"
    send_response 400 "Bad Request: invalid path"
    return
  fi

  # Read body to temp file
  local tmp
  tmp=$(mktemp -p "${TMPDIR:-/tmp}" backup-server.XXXXXXXXXX)
  trap "rm -f '$tmp'" EXIT

  if [[ "$content_length" -gt 0 ]]; then
    if ! dd bs=1 count="$content_length" 2>/dev/null > "$tmp"; then
      log_error "client=${client_id} path=${x_file_path} failed to read body"
      send_response 500 "Internal Server Error"
      return
    fi
  fi

  local new_size
  new_size=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
  local client_dir="${BACKUP_ROOT}/${client_id}"
  mkdir -p "$client_dir"

  # Quota: free space by deleting oldest files if needed
  local current_size
  current_size=$(du -sb "$client_dir" 2>/dev/null | cut -f1)
  current_size=${current_size:-0}
  local need_size=$((current_size + new_size))

  if [[ "$need_size" -gt "$MAX_BYTES" ]]; then
    # List files by mtime (oldest first)
    local freed=0
    while [[ "$need_size" -gt "$MAX_BYTES" ]]; do
      local oldest
      oldest=$(find "$client_dir" -type f -printf '%T+ %p\n' 2>/dev/null | sort -n | head -1)
      if [[ -z "$oldest" ]]; then
        break
      fi
      oldest="${oldest#* }"
      local fsize
      fsize=$(stat -c %s "$oldest" 2>/dev/null || echo 0)
      rm -f "$oldest"
      freed=$((freed + fsize))
      need_size=$((need_size - fsize))
      log_info "client=${client_id} quota: deleted path=${oldest} freed=${fsize} bytes"
    done
    current_size=$((current_size - freed))
    need_size=$((current_size + new_size))
    if [[ "$need_size" -gt "$MAX_BYTES" ]] && [[ -n "$(find "$client_dir" -type f 2>/dev/null)" ]]; then
      # Single file larger than limit: delete all others (plan: allow, trim so only new file remains)
      find "$client_dir" -type f ! -path "$tmp" -exec rm -f {} \;
      log_info "client=${client_id} quota: cleared all existing files to make room for large upload"
    fi
  fi

  # Place file
  local dest="${client_dir}/${x_file_path}"
  local dest_dir
  dest_dir=$(dirname "$dest")
  mkdir -p "$dest_dir"
  if ! mv "$tmp" "$dest"; then
    log_error "client=${client_id} path=${x_file_path} move failed"
    send_response 500 "Internal Server Error"
    return
  fi
  trap - EXIT

  log_info "client=${client_id} path=${x_file_path} size=${new_size} result=ok"
  send_response 200 "OK"
}

send_response() {
  local code="$1"
  local reason="$2"
  local body="${3:-}"
  local len=${#body}
  printf 'HTTP/1.0 %s %s\r\n' "$code" "$reason"
  printf 'Content-Length: %s\r\n' "$len"
  printf '\r\n'
  [[ -n "$body" ]] && printf '%s' "$body"
}

# --- Daemon: start socat and run this script as handler for each connection ---
run_daemon() {
  if ! command -v socat &>/dev/null; then
    log_error "socat not found; install with: apt install socat"
    exit 1
  fi

  if [[ -z "$ACCESS_KEY" ]]; then
    log_error "ACCESS_KEY is not set"
    exit 1
  fi

  mkdir -p "$(dirname "$BACKUP_ROOT")"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  log_info "starting backup server backup_root=${BACKUP_ROOT} port=${PORT} max_per_client=${MAX_SIZE_PER_CLIENT} access_key=***"
  exec socat "TCP-LISTEN:${PORT},reuseaddr,fork" "EXEC:${SCRIPT_DIR}/server.sh handler"
}

# --- Entry ---
case "${1:-}" in
  handler)
    export BACKUP_HANDLER=1
    run_handler
    ;;
  *)
    run_daemon
    ;;
esac
