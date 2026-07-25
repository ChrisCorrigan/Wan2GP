#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PID_FILE="$ROOT_DIR/.run/wan2gp.pid"; APP="$ROOT_DIR/wgp.py"; warn_at="${WAN2GP_MEMORY_WARN_PERCENT:-90}"
config_error() { echo "Configuration error: $1" >&2; exit 4; }
[[ -f "$APP" ]] || config_error "missing $APP"
pid=""; [[ -f "$PID_FILE" ]] && pid="$(tr -d '[:space:]' < "$PID_FILE")"
if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then echo "Wan2GP process: not running"; exit 1; fi
echo "Wan2GP process: running"; echo "PID: $pid"
if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | grep -Eq '[:.]7860[[:space:]]' || { echo "Port 7860: unavailable"; exit 2; }
elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:7860 -sTCP:LISTEN >/dev/null 2>&1 || { echo "Port 7860: unavailable"; exit 2; }
else echo "Port 7860: unable to check (install ss or lsof)"; exit 4; fi
echo "Port 7860: listening"
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:7860/ >/dev/null || { echo "HTTP health: failed"; exit 3; }; echo "HTTP health: OK"
usage=""; limit=""; peak=""; oom=""
if [[ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
  usage=$(< /sys/fs/cgroup/memory/memory.usage_in_bytes); limit=$(< /sys/fs/cgroup/memory/memory.limit_in_bytes)
  [[ -r /sys/fs/cgroup/memory/memory.max_usage_in_bytes ]] && peak=$(< /sys/fs/cgroup/memory/memory.max_usage_in_bytes)
  [[ -r /sys/fs/cgroup/memory/memory.failcnt ]] && oom=$(< /sys/fs/cgroup/memory/memory.failcnt)
elif [[ -r /sys/fs/cgroup/memory.current ]]; then
  usage=$(< /sys/fs/cgroup/memory.current); limit=$(< /sys/fs/cgroup/memory.max)
  [[ "$limit" == "max" ]] && limit=""; [[ -r /sys/fs/cgroup/memory.peak ]] && peak=$(< /sys/fs/cgroup/memory.peak)
  [[ -r /sys/fs/cgroup/memory.events ]] && oom=$(awk '$1 == "oom_kill" {print $2}' /sys/fs/cgroup/memory.events)
fi
if [[ "$usage" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 && "$limit" -lt 9000000000000000000 ]]; then
  gib() { awk -v n="$1" 'BEGIN {printf "%.1f", n/1024/1024/1024}'; }; pct=$(( usage * 100 / limit ))
  echo "Container RAM: $(gib "$usage") GiB / $(gib "$limit") GiB${peak:+ (peak $(gib "$peak") GiB)}"
  [[ -n "$oom" ]] && echo "OOM kills: $oom"
  (( pct >= warn_at )) && echo "Warning: container RAM usage is $(gib "$usage") GiB of $(gib "$limit") GiB. Avoid starting additional memory-heavy processes."
else echo "Container RAM: cgroup limit unavailable"; fi
