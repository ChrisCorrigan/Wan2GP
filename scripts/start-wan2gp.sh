#!/usr/bin/env bash
# Start Wan2GP locally in a pod/container. It intentionally does not enable a public listener.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="$ROOT_DIR/.venv/bin/python"
APP="$ROOT_DIR/wgp.py"
RUN_DIR="$ROOT_DIR/.run"
PID_FILE="$RUN_DIR/wan2gp.pid"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/wan2gp.log"
MODE="foreground"
TIMEOUT_SECONDS="${WAN2GP_START_TIMEOUT:-90}"
# H3's checkpoints exceed the regular HTTP downloader's size limit. The
# network-volume quota has been raised, so use Xet rather than hf_transfer:
# Xet provides resumable large-file downloads and is more reliable here.
HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-0}"
HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-0}"
export HF_HUB_DISABLE_XET HF_HUB_ENABLE_HF_TRANSFER

usage() { echo "Usage: $0 [--background | --status | --stop]"; }
pid_is_wan2gp() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= 2>/dev/null | grep -Fq "$APP"
}
read_pid() { [[ -f "$PID_FILE" ]] && tr -d '[:space:]' < "$PID_FILE"; }
port_listening() {
  if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | grep -Eq '[:.]7860[[:space:]]';
  elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:7860 -sTCP:LISTEN >/dev/null 2>&1;
  else return 1; fi
}
status() {
  local pid="$(read_pid || true)"
  if [[ -n "$pid" ]] && pid_is_wan2gp "$pid"; then echo "Wan2GP process: running (PID $pid)"; else echo "Wan2GP process: not running"; fi
  if port_listening; then echo "Port 7860: listening"; else echo "Port 7860: not listening"; fi
}
stop() {
  local pid="$(read_pid || true)"
  [[ -n "$pid" ]] || { echo "Wan2GP is not managed by this script (no PID file)."; return 0; }
  if ! pid_is_wan2gp "$pid"; then echo "Removing stale PID file: $PID_FILE"; rm -f "$PID_FILE"; return 0; fi
  echo "Stopping Wan2GP PID $pid..."; kill -TERM "$pid"
  for _ in {1..20}; do kill -0 "$pid" 2>/dev/null || { rm -f "$PID_FILE"; echo "Wan2GP stopped."; return 0; }; sleep 1; done
  echo "Wan2GP did not stop within 20 seconds; leaving it running." >&2; return 1
}

case "${1:-}" in
  --background) MODE="background" ;;
  --status) status; exit 0 ;;
  --stop) stop; exit $? ;;
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
[[ -x "$PYTHON" ]] || { echo "Missing virtual-environment Python: $PYTHON" >&2; exit 4; }
[[ -f "$APP" ]] || { echo "Missing Wan2GP launcher: $APP" >&2; exit 4; }
mkdir -p "$RUN_DIR" "$LOG_DIR"
existing_pid="$(read_pid || true)"
if [[ -n "$existing_pid" ]] && pid_is_wan2gp "$existing_pid"; then
  echo "Wan2GP is already running (PID $existing_pid). http://127.0.0.1:7860"; exit 0
fi
[[ -n "$existing_pid" ]] && rm -f "$PID_FILE"
if port_listening; then
  echo "Port 7860 is already listening, but no Wan2GP process managed by this script was found. Refusing to start a second service." >&2
  echo "Inspect the listener first (for example: ss -ltnp | grep 7860)." >&2
  exit 2
fi

cd "$ROOT_DIR"
echo "Repository: $ROOT_DIR"
echo "Python: $PYTHON"
echo "Log: $LOG_FILE"
"$PYTHON" "$APP" >>"$LOG_FILE" 2>&1 &
pid=$!
echo "$pid" > "$PID_FILE"
echo "Wan2GP PID: $pid"
echo "Expected URL: http://127.0.0.1:7860"

for ((i=0; i<TIMEOUT_SECONDS; i++)); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:7860/ >/dev/null 2>&1; then
    echo "Wan2GP is ready."
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then rm -f "$PID_FILE"; echo "Wan2GP exited; inspect $LOG_FILE" >&2; exit 1; fi
  sleep 1
done
if ! curl --fail --silent --max-time 2 http://127.0.0.1:7860/ >/dev/null 2>&1; then
  echo "Wan2GP did not become available within ${TIMEOUT_SECONDS}s; inspect $LOG_FILE" >&2; exit 1
fi
[[ "$MODE" == "background" ]] && exit 0
echo "Streaming logs; press Ctrl-C to stop Wan2GP."
tail -n 0 -F "$LOG_FILE" & tail_pid=$!
trap 'kill "$tail_pid" 2>/dev/null || true; kill -INT "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$PID_FILE"' INT TERM
if wait "$pid"; then
  result=0
else
  result=$?
fi
kill "$tail_pid" 2>/dev/null || true; rm -f "$PID_FILE"; exit "$result"
