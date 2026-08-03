#!/usr/bin/env bash
# Remove Wan2GP-generated media and Gradio's server-side upload/cache files.
# This deliberately never touches models, LoRAs, source code, settings, or /tmp
# outside Gradio's own cache directory.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUTS_DIR="$ROOT_DIR/outputs"
GRADIO_CACHE_DIR="${WAN2GP_GRADIO_CACHE_DIR:-/tmp/gradio}"
DELETE=0

usage() {
  cat <<'EOF'
Usage: clean-wan2gp-media.sh [--delete]

Without --delete, lists the Wan2GP media locations and their current usage.
With --delete, permanently removes everything inside:
  - <Wan2GP repository>/outputs
  - /tmp/gradio (or WAN2GP_GRADIO_CACHE_DIR)

It does not delete models, LoRAs, source code, settings, logs, or unrelated /tmp files.
Stop Wan2GP before using --delete to avoid write races.
EOF
}

case "${1:-}" in
  "") ;;
  --delete) DELETE=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

require_safe_directory() {
  local directory="$1"
  [[ -n "$directory" && "$directory" != "/" && "$directory" != "/tmp" ]] || {
    echo "Refusing unsafe cleanup target: $directory" >&2
    exit 64
  }
}

describe_directory() {
  local directory="$1" label="$2"
  if [[ ! -e "$directory" ]]; then
    echo "$label: absent ($directory)"
    return
  fi
  [[ -d "$directory" ]] || { echo "$label is not a directory: $directory" >&2; exit 4; }
  local files size
  files="$(find "$directory" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
  size="$(du -sh "$directory" 2>/dev/null | cut -f1)"
  echo "$label: $files files, $size ($directory)"
}

clear_directory() {
  local directory="$1" label="$2"
  [[ -e "$directory" ]] || { echo "$label: already absent"; return; }
  find "$directory" -mindepth 1 -depth -delete
  echo "$label: cleared"
}

require_safe_directory "$OUTPUTS_DIR"
require_safe_directory "$GRADIO_CACHE_DIR"

echo "Wan2GP media cleanup"
describe_directory "$OUTPUTS_DIR" "Generated outputs"
describe_directory "$GRADIO_CACHE_DIR" "Gradio upload/cache"

if (( ! DELETE )); then
  echo "Dry run only. Re-run with --delete to permanently clear these directories."
  exit 0
fi

clear_directory "$OUTPUTS_DIR" "Generated outputs"
clear_directory "$GRADIO_CACHE_DIR" "Gradio upload/cache"
describe_directory "$OUTPUTS_DIR" "Generated outputs after cleanup"
describe_directory "$GRADIO_CACHE_DIR" "Gradio upload/cache after cleanup"
