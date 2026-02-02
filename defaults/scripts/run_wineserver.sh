#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[wineserver] $*"; }

# Defaults if not already set by the container environment
export WINEPREFIX="${WINEPREFIX:-/mnt/vdisk/wineprefix}"
export WINEARCH="${WINEARCH:-win32}"

mkdir -p "$WINEPREFIX"

cleanup() {
  log "stopping (wineserver -k)"
  wineserver -k || true
  exit 0
}
trap cleanup TERM INT

log "starting (persistent)"
wineserver -p || true

# Block forever so Supervisor can manage this program.
# If wineserver ever dies, restart it.
while true; do
  wineserver -w || true
  sleep 0.5
  wineserver -p || true
done
