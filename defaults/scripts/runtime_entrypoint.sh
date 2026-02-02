#!/usr/bin/env bash
# ------------------------------------------------------------
# runtime_entrypoint.sh
#
# Runtime bootstrap. Responsibilities:
# - Mount the vdisk first (native filesystem) so Wine/Winetricks do not touch
#   the v9fs bind-mount volume for executable/unpacked files.
# - Re-assert critical runtime environment after mount (authoritative HOME,
#   WINEPREFIX, WINEARCH, DISPLAY, USER).
# - Create minimal HOME subfolders and fix ownership on HOME/WINEPREFIX.
# - Hand off to seed_and_run.sh which seeds configs and starts supervisord.
#
# Environment notes:
# - HOME is authoritative here because it must point to the vdisk after mount.
# ------------------------------------------------------------
set -euo pipefail

log(){ echo "[runtime-entrypoint] $*"; }

# ------------------------------------------------------------
# Mount vdisk FIRST
# (vdisk_mount.sh also enforces HOME on vdisk and /home/$USER symlink)
# ------------------------------------------------------------
log "mounting vdisk (and enforcing HOME on vdisk)"

if [ -x "$SCRIPTS_DIR/vdisk_mount.sh" ]; then
  "$SCRIPTS_DIR/vdisk_mount.sh"
elif [ -x /opt/defaults/scripts/vdisk_mount.sh ]; then
  /opt/defaults/scripts/vdisk_mount.sh
else
  log "ERROR: vdisk_mount.sh not found"
  exit 1
fi

# ------------------------------------------------------------
# Enforce HOME for this process environment (authoritative)
# ------------------------------------------------------------
export HOME="/mnt/vdisk/home/${USER}"
log "Using HOME=$HOME"

mkdir -p "$HOME/Desktop" "$HOME/.config" "$HOME/.local/share" || true
chown -R "$USER:$USER" "$HOME" "$WINEPREFIX" 2>/dev/null || true

log "ENV: USER=$USER HOME=$HOME DISPLAY=$DISPLAY WINEPREFIX=$WINEPREFIX"

# Continue normal startup
exec "$SCRIPTS_DIR/seed_and_run.sh"
