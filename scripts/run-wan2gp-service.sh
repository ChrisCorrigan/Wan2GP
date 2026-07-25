#!/usr/bin/env bash
# Optional RunPod supervisor. Launch this instead of start-wan2gp.sh when restarts are desired.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LOG_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/logs/wan2gp-supervisor.log"
mkdir -p "$(dirname "$LOG_FILE")"; stopping=0; child=""
trap 'stopping=1; [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null || true' INT TERM
failures=0
while (( ! stopping )); do
  echo "$(date -Is) starting Wan2GP" | tee -a "$LOG_FILE"
  # Foreground mode keeps this supervisor as the process parent. The launcher
  # handles readiness and streams the application log; do not use --background here.
  "$SCRIPT_DIR/start-wan2gp.sh" >>"$LOG_FILE" 2>&1 &
  child=$!
  wait "$child" || true
  (( stopping )) && break
  failures=$((failures + 1)); delay=$(( failures < 5 ? 10 : 60 ))
  echo "$(date -Is) Wan2GP exited unexpectedly; retry $failures in ${delay}s" | tee -a "$LOG_FILE"
  sleep "$delay"
done
echo "$(date -Is) supervisor stopped" | tee -a "$LOG_FILE"
