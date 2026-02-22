#!/usr/bin/env bash
#
# Creates server.env by prompting for each variable from server.env.template.
# Existing server.env is not overwritten unless run with -f.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/server.env.template"
OUTPUT="${SCRIPT_DIR}/server.env"

if [[ "${1:-}" == "-f" ]] || [[ "${1:-}" == "--force" ]]; then
  FORCE=1
else
  FORCE=0
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE" >&2
  exit 1
fi

if [[ -f "$OUTPUT" ]] && [[ $FORCE -eq 0 ]]; then
  echo "Already exists: $OUTPUT (use -f to overwrite)" >&2
  exit 1
fi

echo "Creating server.env from server.env.template (press Enter to keep default)."
> "$OUTPUT"

while IFS= read -r line; do
  # Skip comments and empty lines
  if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
    echo "$line" >> "$OUTPUT"
    continue
  fi
  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    var="${BASH_REMATCH[1]}"
    default="${BASH_REMATCH[2]}"
    read -r -p "${var} [${default}]: " input
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
