#!/usr/bin/env bash
# ------------------------------------------------------------
# entrypoint.sh
#
# Container entrypoint. Responsibilities:
# - Set baseline environment defaults used by all downstream scripts/services
#   (DISPLAY, USER, HOME, CONF_DIR, etc).
# - Ensure base directories exist and the runtime user account exists.
# - Seed /data/conf from /opt/defaults using a VERSION check:
#     - Core runtime files may be force-updated when VERSION changes
#     - User hook files are only seeded if missing (not overwritten)
# - Hand off to runtime_entrypoint.sh for vdisk mount + final runtime setup.
#
# Environment notes:
# - These defaults are set once here and inherited by child processes.
# - HOME is set to the intended vdisk path even before the vdisk is mounted;
#   runtime_entrypoint.sh will mount the vdisk and re-assert HOME.
# ------------------------------------------------------------
set -euo pipefail

log(){ echo "[entrypoint] $*"; }

# ------------------------------------------------------------
# ENV defaults
# ------------------------------------------------------------
export DISPLAY="${DISPLAY:-:0}"
export TZ="${TZ:-America/Chicago}"
export USER="${USER:-wineuser}"
export WINEPREFIX="${WINEPREFIX:-/mnt/vdisk/wineprefix}"
export WINEARCH="${WINEARCH:-win32}"
export W_CACHE="${W_CACHE:-/tmp/WINETRICKS_CACHE}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/XDG_CACHE}"
# HOME lives on the vdisk. The vdisk is mounted later in runtime_entrypoint.sh.
# We still set HOME now so every service agrees on the intended path.
export HOME="${HOME:-/mnt/vdisk/home/${USER}}"
export CONF_DIR="${CONF_DIR:-/data/conf}"
export SCRIPTS_DIR="$CONF_DIR/scripts"
export WALLPAPER="${WALLPAPER:-/data/background.jpg}"


NGINX_DIR="$CONF_DIR/nginx"
SUP_DIR="$CONF_DIR/supervisor"
SSH_DIR="$CONF_DIR/ssh"
WWW_DIR="$CONF_DIR/www"

RUNTIME_ENTRYPOINT="$SCRIPTS_DIR/runtime_entrypoint.sh"

# ------------------------------------------------------------
# Timezone support (set with -e TZ=America/Chicago)
# ------------------------------------------------------------
if [ -n "${TZ:-}" ] && [ -e "/usr/share/zoneinfo/${TZ}" ]; then
  ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi


# ------------------------------------------------------------
# Base dirs
# ------------------------------------------------------------
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

mkdir -p /data "$CONF_DIR" "$SCRIPTS_DIR" "$NGINX_DIR" "$SUP_DIR" "$SSH_DIR" "$WWW_DIR"
mkdir -p /run/sshd

# ------------------------------------------------------------
# Ensure user exists
# ------------------------------------------------------------
if ! id -u "$USER" >/dev/null 2>&1; then
  log "Creating user $USER (home=$HOME)"
  useradd -m -d "$HOME" -s /bin/bash "$USER"
fi

# Placeholders (these may be hidden once vdisk mounts)
mkdir -p /mnt/vdisk /mnt/vdisk/home "$HOME" "$HOME/.config" "$HOME/Desktop" || true
mkdir -p /home || true

chown -R "$USER:$USER" /data "$HOME" 2>/dev/null || true

# ------------------------------------------------------------
# Ensure cache dirs are writable for the runtime USER
# ------------------------------------------------------------
mkdir -p /tmp \
         /tmp/.cache \
         "$XDG_CACHE_HOME" \
         "$W_CACHE" \

chmod 0777 /tmp /tmp/.cache "$XDG_CACHE_HOME" "$W_CACHE" 2>/dev/null || true


# ------------------------------------------------------------
# Remove xfce4-session warnings in containers
# ------------------------------------------------------------
cat >/usr/bin/pm-is-supported <<'EOF'
#!/bin/sh
# Container stub: report "not supported" to avoid xfce session warnings.
exit 1
EOF
chmod 0777  /usr/bin/pm-is-supported

mkdir -p /tmp/.ICE-unix
chmod 1777 /tmp/.ICE-unix

# ------------------------------------------------------------
# fix supervisor.sock 
# ------------------------------------------------------------
mkdir -p /var/run
ln -sf /tmp/supervisor.sock /var/run/supervisor.sock


# ------------------------------------------------------------
# Versioned seeding
# - this avoids "old volume" breakage when we change core services
# ------------------------------------------------------------
DEFAULT_VERSION_FILE="/opt/defaults/VERSION"
CONF_VERSION_FILE="$CONF_DIR/VERSION"

need_upgrade=0
if [[ -f "$DEFAULT_VERSION_FILE" ]]; then
  if [[ ! -f "$CONF_VERSION_FILE" ]]; then
    need_upgrade=1
  elif ! cmp -s "$DEFAULT_VERSION_FILE" "$CONF_VERSION_FILE"; then
    need_upgrade=1
  fi
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
seed_file_if_missing() {
  local src="$1" dst="$2"
  if [[ ! -f "$dst" ]]; then
    log "Seeding $dst"
    cp -a "$src" "$dst"
  fi
  sed -i 's/\r$//' "$dst" 2>/dev/null || true
  chmod a+rx "$dst" 2>/dev/null || true
}

seed_file_force() {
  local src="$1" dst="$2"
  log "Updating $dst"
  cp -a "$src" "$dst"
  sed -i 's/\r$//' "$dst" 2>/dev/null || true
  chmod a+rx "$dst" 2>/dev/null || true
}

seed_dir_missing_files() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"
  find "$src" -type f -print0 | while IFS= read -r -d '' f; do
    rel="${f#$src/}"
    out="$dst/$rel"
    if [[ ! -e "$out" ]]; then
      mkdir -p "$(dirname "$out")"
      cp -a "$f" "$out"
      log "Seeded $out"
    fi
  done
}

# ------------------------------------------------------------
# Seed scripts
# - user hooks: seed only if missing
# - core runtime: force update if VERSION changed
# ------------------------------------------------------------
if [[ "$need_upgrade" == "1" ]]; then
  log "Config upgrade detected: refreshing core runtime files"
  seed_file_force /opt/defaults/scripts/seed_and_run.sh        "$SCRIPTS_DIR/seed_and_run.sh"
  seed_file_force /opt/defaults/scripts/runtime_entrypoint.sh  "$RUNTIME_ENTRYPOINT"
  seed_file_force /opt/defaults/scripts/kiosk_mode.sh          "$SCRIPTS_DIR/kiosk_mode.sh"
  seed_file_force /opt/defaults/scripts/vdisk_mount.sh         "$SCRIPTS_DIR/vdisk_mount.sh"
  seed_file_force /opt/defaults/scripts/run_xfce.sh            "$SCRIPTS_DIR/run_xfce.sh"
else
  seed_file_if_missing /opt/defaults/scripts/seed_and_run.sh        "$SCRIPTS_DIR/seed_and_run.sh"
  seed_file_if_missing /opt/defaults/scripts/runtime_entrypoint.sh  "$RUNTIME_ENTRYPOINT"
  seed_file_if_missing /opt/defaults/scripts/kiosk_mode.sh          "$SCRIPTS_DIR/kiosk_mode.sh"
  seed_file_if_missing /opt/defaults/scripts/vdisk_mount.sh         "$SCRIPTS_DIR/vdisk_mount.sh"
  seed_file_if_missing /opt/defaults/scripts/run_xfce.sh            "$SCRIPTS_DIR/run_xfce.sh"
  
fi

seed_file_if_missing /opt/defaults/scripts/onconnect.sh       "$SCRIPTS_DIR/onconnect.sh"
seed_file_if_missing /opt/defaults/scripts/ondisconnect.sh    "$SCRIPTS_DIR/ondisconnect.sh"
seed_file_if_missing /opt/defaults/scripts/startup.sh         "$SCRIPTS_DIR/startup.sh"
seed_file_if_missing /opt/defaults/scripts/vnc_hook.sh        "$SCRIPTS_DIR/vnc_hook.sh"
seed_file_if_missing /opt/defaults/scripts/kiosk_hook.sh      "$SCRIPTS_DIR/kiosk_hook.sh"

# toolbar_api.py: seed once (do not overwrite)
if [[ ! -f "$SCRIPTS_DIR/toolbar_api.py" ]]; then
  log "Seeding $SCRIPTS_DIR/toolbar_api.py"
  cp -a /opt/defaults/scripts/toolbar_api.py "$SCRIPTS_DIR/toolbar_api.py"
  sed -i 's/\r$//' "$SCRIPTS_DIR/toolbar_api.py" 2>/dev/null || true
fi
chmod a+r "$SCRIPTS_DIR/toolbar_api.py" 2>/dev/null || true

# ------------------------------------------------------------
# Seed configs
# - force update supervisor/nginx on version change
# ------------------------------------------------------------
if [[ "$need_upgrade" == "1" ]]; then
  seed_file_force /opt/defaults/nginx/nginx.conf            "$NGINX_DIR/nginx.conf"
  seed_file_force /opt/defaults/supervisor/supervisord.conf "$SUP_DIR/supervisord.conf"
  cp -a "$DEFAULT_VERSION_FILE" "$CONF_VERSION_FILE" 2>/dev/null || true
else
  seed_file_if_missing /opt/defaults/nginx/nginx.conf            "$NGINX_DIR/nginx.conf"
  seed_file_if_missing /opt/defaults/supervisor/supervisord.conf "$SUP_DIR/supervisord.conf"
  if [[ -f "$DEFAULT_VERSION_FILE" && ! -f "$CONF_VERSION_FILE" ]]; then
    cp -a "$DEFAULT_VERSION_FILE" "$CONF_VERSION_FILE" 2>/dev/null || true
  fi
fi

# ------------------------------------------------------------
# Seed WWW (missing files only)
# ------------------------------------------------------------
seed_dir_missing_files /opt/defaults/www "$WWW_DIR"

# ------------------------------------------------------------
# SSH
# ------------------------------------------------------------
echo "${USER}:${SSH_PASSWORD:-$USER}" | chpasswd
ssh-keygen -A >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Always seed cwinetricks.sh (overwrite every boot) and install next to winetricks
# ------------------------------------------------------------
seed_file_force /opt/defaults/scripts/cwinetricks.sh "$SCRIPTS_DIR/cwinetricks.sh"
chmod a+rx "$SCRIPTS_DIR/cwinetricks.sh" 2>/dev/null || true

WT_BIN="$(command -v winetricks 2>/dev/null || echo /usr/local/bin/winetricks)"
WT_DIR="$(dirname "$WT_BIN")"
install -m 0755 "$SCRIPTS_DIR/cwinetricks.sh" "$WT_DIR/cwinetricks"

log "Starting runtime entrypoint"
exec "$RUNTIME_ENTRYPOINT"
