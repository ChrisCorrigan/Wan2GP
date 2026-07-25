#!/usr/bin/env bash
# macOS helper: keeps the local-only Wan2GP SSH forward alive. No RunPod endpoint is stored here.
set -Eeuo pipefail
STATE_DIR="${WAN2GP_TUNNEL_STATE_DIR:-$HOME/.wan2gp}"; PID_FILE="$STATE_DIR/tunnel.pid"; LOG_FILE="$STATE_DIR/tunnel.log"
host="${WAN2GP_HOST:-}"; port="${WAN2GP_PORT:-}"; user="${WAN2GP_USER:-root}"; identity="${WAN2GP_IDENTITY:-}"; replace=0
usage() { cat <<'EOF'
Usage: wan2gp-tunnel.sh [status|stop] | --host HOST --port PORT [--user USER] [--identity PATH] [--replace]
The RunPod external SSH port can change after a pod restart; copy its current value from the dashboard.
EOF
}
read_pid() { [[ -f "$PID_FILE" ]] && tr -d '[:space:]' < "$PID_FILE"; }
pid_alive() { [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }
pid_is_managed_tunnel() {
  pid_alive "$1" && ps -p "$1" -o command= 2>/dev/null | grep -Eq '(ssh|autossh|wan2gp-tunnel)'
}
listener() { lsof -nP -iTCP:7860 -sTCP:LISTEN 2>/dev/null || true; }
status() {
  local pid="$(read_pid || true)" info; info="$(listener)"
  if [[ -n "$pid" ]] && pid_is_managed_tunnel "$pid"; then
    echo "Local tunnel: running"; echo "Tunnel PID: $pid"
  elif [[ -n "$info" ]] && echo "$info" | grep -Eq '(^|[[:space:]])(ssh|autossh)[[:space:]]'; then
    echo "Local tunnel: running (not managed by this helper)"; echo "Tunnel PID: $(lsof -t -iTCP:7860 -sTCP:LISTEN 2>/dev/null | head -n 1)"
    echo "Note: stop will only stop tunnels created by this helper."
  elif [[ -n "$info" ]]; then echo "Local port 7860: occupied by a process not managed by this helper"; echo "$info"; return 1
  else echo "Local tunnel: not running"; return 1; fi
  echo "Local port: 7860"
  if curl -I --silent --show-error --max-time 5 http://127.0.0.1:7860 2>/dev/null | head -n 1 | grep -Eq 'HTTP/.* 2[0-9][0-9]'; then echo "Wan2GP HTTP response: 200 OK"; else echo "Wan2GP HTTP response: unavailable"; fi
  echo "URL: http://localhost:7860"
}
stop() {
  local pid="$(read_pid || true)"
  [[ -n "$pid" ]] || { echo "No tunnel managed by this helper."; return 0; }
  if ! pid_alive "$pid"; then rm -f "$PID_FILE"; echo "Removed stale tunnel PID file."; return 0; fi
  if ! pid_is_managed_tunnel "$pid"; then echo "Refusing to stop unexpected PID $pid." >&2; return 1; fi
  kill -TERM "$pid"; for _ in {1..10}; do pid_alive "$pid" || { rm -f "$PID_FILE"; echo "Tunnel stopped."; return 0; }; sleep 1; done
  echo "Tunnel PID $pid did not stop." >&2; return 1
}
[[ "${1:-}" == "status" ]] && { status; exit $?; }; [[ "${1:-}" == "stop" ]] && { stop; exit $?; }
while (( $# )); do case "$1" in
  --host) host="${2:-}"; shift 2;; --port) port="${2:-}"; shift 2;; --user) user="${2:-}"; shift 2;; --identity) identity="${2:-}"; shift 2;; --replace) replace=1; shift;; -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; usage >&2; exit 64;; esac; done
[[ -n "$host" && -n "$port" ]] || { echo "--host and --port are required (or set WAN2GP_HOST/WAN2GP_PORT)." >&2; exit 64; }
[[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port > 0 && port < 65536 )) || { echo "Invalid SSH port: $port" >&2; exit 64; }
[[ -z "$identity" || -f "$identity" ]] || { echo "Identity file does not exist: $identity" >&2; exit 64; }
mkdir -p "$STATE_DIR"; existing="$(read_pid || true)"
if [[ -n "$existing" ]] && pid_is_managed_tunnel "$existing"; then
  (( replace )) || { echo "Tunnel already managed by this helper (PID $existing). Use --replace to restart it." >&2; exit 1; }; stop
elif [[ -n "$existing" ]]; then
  echo "Removing stale tunnel PID file."
  rm -f "$PID_FILE"
fi
info="$(listener)"
if [[ -n "$info" ]]; then echo "Local port 7860 is already occupied:" >&2; echo "$info" >&2; echo "Refusing to replace an unrelated listener." >&2; exit 1; fi
opts=(-N -T -p "$port" -o TCPKeepAlive=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -L 7860:127.0.0.1:7860)
[[ -n "$identity" ]] && opts+=(-i "$identity")
if command -v autossh >/dev/null 2>&1; then
  echo "Using autossh for automatic reconnection."
  AUTOSSH_GATETIME=0 nohup autossh -M 0 "${opts[@]}" "$user@$host" >>"$LOG_FILE" 2>&1 &
else
  echo "autossh is not installed; using an SSH reconnect loop (install with: brew install autossh)."
  nohup bash -c '
    child=""
    stop() { [ -n "$child" ] && kill -TERM "$child" 2>/dev/null || true; exit 0; }
    trap stop INT TERM
    while true; do
      ssh "$@" & child=$!
      wait "$child"; code=$?
      child=""
      [ "$code" -eq 0 ] && exit 0
      sleep 5
    done
  ' _ "${opts[@]}" "$user@$host" >>"$LOG_FILE" 2>&1 &
fi
pid=$!; echo "$pid" > "$PID_FILE"; sleep 1
if ! pid_alive "$pid"; then rm -f "$PID_FILE"; echo "Tunnel failed to start; inspect $LOG_FILE" >&2; exit 1; fi
echo "Tunnel active:"; echo "http://localhost:7860"; echo "PID: $pid"; echo "RunPod's external SSH port may change after a pod restart; update --port from the dashboard."
