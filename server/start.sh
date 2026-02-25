#!/usr/bin/env bash
#
# Backup server: receives uploads over HTTP, stores per client IP, enforces
# MAX_SIZE_PER_CLIENT by deleting oldest files when limit exceeded.
# Clients identified by connection source IP (SOCAT_PEERADDR).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/server.env" ]]; then
  set +u
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/server.env"
  set -u
fi

: "${BACKUP_ROOT:=/var/backups/incoming}"
: "${LOCK_DIR:=/var/run/backup-server/locks}"
: "${PORT:=9999}"
: "${ACCESS_KEY:=}"
: "${MAX_SIZE_PER_CLIENT:=1G}"
: "${LOG_FILE:=/var/log/backup-server.log}"
: "${LOCK_STALE_MINS:=60}"

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
export BACKUP_ROOT LOCK_DIR PORT ACCESS_KEY MAX_BYTES LOG_FILE SCRIPT_DIR

log_trace() { log_level "TRACE" "$*"; }
log_info()  { log_level "INFO"  "$*"; }
log_warn()  { log_level "WARN"  "$*"; }
log_error() { log_level "ERROR" "$*"; }

log_level() {
  local level="$1"
  shift
  local msg="$*"
  local ts rid
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  rid="${REQUEST_ID:-}"
  if [[ -n "$rid" ]]; then
    msg="req=${rid} ${msg}"
  fi
  echo "${ts} [${level}] ${msg}" >> "$LOG_FILE"
  # Only duplicate to stderr when attached to a TTY (avoids duplicate lines when stderr is redirected to LOG_FILE)
  if [[ -z "${BACKUP_HANDLER:-}" ]] && [[ -t 2 ]]; then
    echo "${ts} [${level}] ${msg}" >&2
  fi
}

run_handler() {
  trap '' PIPE
  local client_id="${SOCAT_PEERADDR:-unknown}"
  client_id="${client_id//:/_}"
  if [[ "$client_id" == "unknown" ]]; then
    log_warn "client_id unknown (SOCAT_PEERADDR unset)"
  fi
  # Per-request ID for tracing this handler invocation
  REQUEST_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM-${client_id}"
  log_trace "handler start client=${client_id}"

  local request_line
  if ! read -r request_line; then
    log_error "client=${client_id} read request line failed"
    send_response 400 "Bad Request"
    return
  fi

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
  log_trace "parsed headers content_length=${content_length} x_file_path_raw='${x_file_path}'"

  if [[ -z "$ACCESS_KEY" ]] || [[ "$x_access_key" != "$ACCESS_KEY" ]]; then
    log_warn "client=${client_id} auth failed (key mismatch or missing)"
    send_response 403 "Forbidden"
    return
  fi
  log_trace "auth ok client=${client_id}"

  if [[ -z "$x_file_path" ]]; then
    x_file_path="upload-$(date +%s).bin"
  fi
  # Reject encoded traversal (e.g. %2f, %2e%2e)
  if [[ "$x_file_path" =~ %2[fF] ]] || [[ "$x_file_path" =~ %2[eE]%2[eE] ]]; then
    log_warn "client=${client_id} invalid file path (encoded traversal)"
    send_response 400 "Bad Request: invalid path"
    return
  fi
  x_file_path="${x_file_path#/}"
  # Normalize: collapse multiple slashes and /./ (avoid ....// or ..//.. bypass)
  while [[ "$x_file_path" != "${x_file_path//\/\//\/}" ]]; do x_file_path="${x_file_path//\/\//\/}"; done
  while [[ "$x_file_path" != "${x_file_path//\/.\//\/}" ]]; do x_file_path="${x_file_path//\/.\//\/}"; done
  # Reject any ".." segment (leading, middle, or trailing)
  if [[ "$x_file_path" == ".." ]] || [[ "$x_file_path" == "../"* ]] || [[ "$x_file_path" == *"/../"* ]] || [[ "$x_file_path" == *"/.." ]]; then
    log_warn "client=${client_id} invalid file path (path traversal)"
    send_response 400 "Bad Request: invalid path"
    return
  fi
  if [[ "$x_file_path" =~ [^a-zA-Z0-9_\-/.] ]]; then
    log_warn "client=${client_id} invalid file path (unsafe chars)"
    send_response 400 "Bad Request: invalid path"
    return
  fi
  log_trace "path sanitized path=${x_file_path}"

  local tmp
  tmp=$(mktemp -p "${TMPDIR:-/tmp}" backup-server.XXXXXXXXXX)

  if [[ "$content_length" -gt 0 ]]; then
    # Read exactly content_length bytes; dd exits non-zero if client sends less (e.g. disconnect), and we handle that below.
    # Read body in 8MB blocks (dd bs=1 would be one byte at a time, extremely slow for large uploads)
    BS=8388608
    blocks=$(( content_length / BS ))
    rest=$(( content_length % BS ))
    if ! (
      { [[ $blocks -gt 0 ]] && dd bs=$BS iflag=fullblock count=$blocks 2>/dev/null; }
      { [[ $rest -gt 0 ]] && dd bs=65536 iflag=fullblock count=$(( rest / 65536 )) 2>/dev/null; }
      { [[ $(( rest % 65536 )) -gt 0 ]] && dd bs=1 count=$(( rest % 65536 )) 2>/dev/null; }
    ) > "$tmp"; then
      log_error "client=${client_id} path=${x_file_path} failed to read body"
      send_response 500 "Internal Server Error"
      return
    fi
  else
    touch "$tmp"
  fi

  local new_size
  new_size=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
  log_trace "body read size=${new_size}"
  if [[ "$new_size" -gt "$MAX_BYTES" ]]; then
    log_warn "client=${client_id} path=${x_file_path} rejected: single file size ${new_size} exceeds quota ${MAX_BYTES}"
    send_response 413 "Payload Too Large"
    return
  fi

  local client_dir="${BACKUP_ROOT}/${client_id}"
  mkdir -p "$BACKUP_ROOT"
  mkdir -p "$LOCK_DIR"
  local lock_file="${LOCK_DIR}/${client_id}.lock"
  exec 200>"$lock_file"
  if ! flock 200; then
    log_error "client=${client_id} failed to acquire lock"
    send_response 503 "Service Unavailable"
    return
  fi
  cleanup_handler() {
    rm -f "${tmp:-}" 2>/dev/null || true
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
  }
  trap cleanup_handler EXIT

  mkdir -p "$client_dir"
  local current_size
  current_size=$(du -sb "$client_dir" 2>/dev/null | cut -f1)
  current_size=${current_size:-0}
  local need_size=$((current_size + new_size))
  log_trace "quota check start current_size=${current_size} new_size=${new_size} need_size=${need_size} max_bytes=${MAX_BYTES}"

  # Delete oldest files until roughly under quota; one find+sort, then iterate (avoids O(n²) repeated scans)
  while IFS= read -r -u 3 mtime path; do
    [[ "$need_size" -le "$MAX_BYTES" ]] && break
    [[ -z "$path" ]] && continue
    if [[ ! -f "$path" ]]; then
      continue
    fi
    local fsize
    fsize=$(stat -c %s "$path" 2>/dev/null || echo 0)
    rm -f "$path"
    need_size=$((need_size - fsize))
    log_trace "quota delete file=${path} freed=${fsize} new_need_size=${need_size}"
  done 3< <(find "$client_dir" -type f -printf '%T+ %p\n' 2>/dev/null | sort -n)

  # Recalculate based on actual disk usage and account for overwrite of existing dest file.
  local dest="${client_dir}/${x_file_path}"
  local existing_dest_size=0
  if [[ -f "$dest" ]]; then
    existing_dest_size=$(stat -c %s "$dest" 2>/dev/null || echo 0)
  fi
  local actual_size
  actual_size=$(du -sb "$client_dir" 2>/dev/null | cut -f1)
  actual_size=${actual_size:-0}
  local projected_final_size=$(( actual_size - existing_dest_size + new_size ))
  log_trace "quota after deletions actual_size=${actual_size} existing_dest_size=${existing_dest_size} new_size=${new_size} projected_final_size=${projected_final_size} max_bytes=${MAX_BYTES}"
  if [[ "$projected_final_size" -gt "$MAX_BYTES" ]]; then
    log_error "client=${client_id} quota exceeded after deletions projected_final_size=${projected_final_size} max=${MAX_BYTES}"
    send_response 413 "Payload Too Large"
    return
  fi

  local dest_dir
  dest_dir=$(dirname "$dest")
  if [[ -e "$dest" ]]; then
    log_trace "dest exists before write path=${x_file_path}"
  fi
  # Path escape check: lock prevents same-client races; re-check immediately before mv to minimize window for external symlink changes.
  if command -v realpath &>/dev/null; then
    local base_canon dest_dir_canon
    base_canon=$(realpath -m "$client_dir" 2>/dev/null)
    dest_dir_canon=$(realpath -m "$dest_dir" 2>/dev/null || true)
    if [[ -n "$base_canon" && -n "$dest_dir_canon" ]]; then
      if [[ "$dest_dir_canon" != "$base_canon" && "$dest_dir_canon" != "${base_canon}/"* ]]; then
        log_error "client=${client_id} path=${x_file_path} escapes client directory"
        send_response 400 "Bad Request"
        return
      fi
    fi
  fi
  mkdir -p "$dest_dir"
  if command -v realpath &>/dev/null; then
    base_canon=$(realpath -m "$client_dir" 2>/dev/null)
    dest_dir_canon=$(realpath -m "$dest_dir" 2>/dev/null || true)
    if [[ -n "$base_canon" && -n "$dest_dir_canon" ]]; then
      if [[ "$dest_dir_canon" != "$base_canon" && "$dest_dir_canon" != "${base_canon}/"* ]]; then
        log_error "client=${client_id} path=${x_file_path} escapes client directory (re-check before mv)"
        send_response 400 "Bad Request"
        return
      fi
    fi
  fi
  if ! mv "$tmp" "$dest"; then
    log_error "client=${client_id} path=${x_file_path} move failed"
    send_response 500 "Internal Server Error"
    return  # EXIT trap runs cleanup_handler (lock release, tmp removal)
  fi

  log_trace "handler complete client=${client_id} path=${x_file_path} size=${new_size} result=ok"
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

run_daemon() {
  if ! command -v socat &>/dev/null; then
    log_error "socat not found; run setup.sh first"
    exit 1
  fi

  if [[ -z "$ACCESS_KEY" ]]; then
    log_error "ACCESS_KEY is not set (run setup.sh)"
    exit 1
  fi

  mkdir -p "$(dirname "$BACKUP_ROOT")"
  mkdir -p "$LOCK_DIR"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # Clean stale lock files (e.g. from crashed handlers); run at startup (cron can do periodic cleanup)
  find "$LOCK_DIR" -name "*.lock" -type f -mmin "+${LOCK_STALE_MINS}" -delete 2>/dev/null || true

  # If running in a terminal (e.g. SSH), detach so server survives disconnect
  if [[ -t 1 ]]; then
    nohup bash "${SCRIPT_DIR}/start.sh" >> "$LOG_FILE" 2>&1 &
    echo "Server started in background (PID $!). Logs: $LOG_FILE"
    exit 0
  fi

  log_info "starting backup server backup_root=${BACKUP_ROOT} port=${PORT} max_per_client=${MAX_SIZE_PER_CLIENT} access_key=***"
  # Use bash so start.sh does not need execute permission (socat execvp would require +x)
  exec socat "TCP-LISTEN:${PORT},reuseaddr,fork" "EXEC:bash ${SCRIPT_DIR}/start.sh handler"
}

case "${1:-}" in
  handler)
    set +e
    export BACKUP_HANDLER=1
    run_handler
    exit 0
    ;;
  *)
    run_daemon
    ;;
esac
