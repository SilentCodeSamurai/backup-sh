#!/usr/bin/env bash
#
# Client setup: prompt for env from client.env.template, write client.env. Optionally install curl if missing.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/client.env.template"
OUTPUT="${SCRIPT_DIR}/client.env"

if [[ "${1:-}" == "-f" ]] || [[ "${1:-}" == "--force" ]]; then
  FORCE=1
else
  FORCE=0
fi

# Install curl if missing (Debian/Ubuntu)
if ! command -v curl &>/dev/null; then
  echo "curl not found. Install with: sudo apt update && sudo apt install -y curl" >&2
  if [[ -t 0 ]]; then
    read -r -p "Install curl now? [y/N]: " yn < /dev/tty
    if [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]; then
      sudo apt update && sudo apt install -y curl
    else
      echo "Install curl before running send.sh" >&2
      exit 1
    fi
  else
    exit 1
  fi
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE" >&2
  exit 1
fi

if [[ -f "$OUTPUT" ]] && [[ $FORCE -eq 0 ]]; then
  echo "Already exists: $OUTPUT (use -f to overwrite)" >&2
  exit 1
fi

echo "Creating client.env from client.env.template (press Enter to keep default)."
> "$OUTPUT"

while IFS= read -r line; do
  line="${line%%$'\r'}"
  if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
    echo "$line" >> "$OUTPUT"
    continue
  fi
  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    var="${BASH_REMATCH[1]}"
    default="${BASH_REMATCH[2]}"
    default="${default%"${default##*[![:space:]]}"}"
    default="${default#"${default%%[![:space:]]*}"}"
    printf '%s [%s]: ' "$var" "$default" > /dev/tty
    read -r input < /dev/tty
    if [[ -z "${input// }" ]]; then
      echo "${var}=${default}" >> "$OUTPUT"
    else
      echo "${var}=${input}" >> "$OUTPUT"
    fi
    continue
  fi
  echo "$line" >> "$OUTPUT"
done < "$TEMPLATE"

echo "Wrote $OUTPUT"
