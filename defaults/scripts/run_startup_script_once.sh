#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo "[startup-once] $*"; }

export DISPLAY="${DISPLAY:-:0}"
export USER="${USER:-wineuser}"

wait_for_x() {
  for _ in $(seq 1 240); do
    if command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1; then return 0; fi
    if command -v xset >/dev/null 2>&1 && xset q >/dev/null 2>&1; then return 0; fi
    [[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]] && return 0
    sleep 0.25
  done
  return 1
}

wait_for_proc() {
  local name="$1"
  for _ in $(seq 1 240); do
    pgrep -u "$USER" -x "$name" >/dev/null 2>&1 && return 0
    pgrep -x "$name" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

log "Waiting for X on DISPLAY=$DISPLAY"
wait_for_x || log "WARNING: X not ready, continuing anyway"

log "Waiting for xfce4-session"
wait_for_proc xfce4-session || log "WARNING: xfce4-session not detected, continuing anyway"

log "Calling /data/conf/scripts/entrypoint_startup.sh"
if [[ -x /data/conf/scripts/entrypoint_startup.sh ]]; then
  /data/conf/scripts/entrypoint_startup.sh || true
else
  log "WARNING: /data/conf/scripts/entrypoint_startup.sh not executable"
fi

log "Done"
