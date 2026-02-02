#!/usr/bin/env bash
# ------------------------------------------------------------
# seed_and_run.sh
#
# Seed configs and start services. Responsibilities:
# - Ensure /data/conf layout exists (scripts, xfce4, nginx, supervisor, etc).
# - Ensure HOME layout exists (Desktop, Templates, .config, etc).
# - Seed defaults from /opt/defaults into /data/conf:
#     - Missing-only by default
#     - If FORCE_RESEED=1, overwrite existing files from /opt/defaults
# - Set up XFCE config redirection:
#     - ~/.config/xfce4 -> /data/conf/xfce4 (symlink, no overwrite)
# - Set up XFCE kiosk config plumbing (kioskrc current file + system symlink).
# - Apply xfce4-terminal accelerator preferences for clipboard hotkeys.
# - Start supervisord using /data/conf/supervisor/supervisord.conf.
#
# Environment notes:
# - Assumes runtime_entrypoint.sh already mounted the vdisk and set HOME to
#   /mnt/vdisk/home/$USER. This script uses that HOME for user configs.
# ------------------------------------------------------------
set -Eeuo pipefail

log(){ echo "[seed] $*"; }

umask 022

FORCE_RESEED="${FORCE_RESEED:-0}"

XFCE_DIR="$CONF_DIR/xfce4"

# ------------------------------------------------------------
# Ensure dirs
# ------------------------------------------------------------
mkdir -p \
  "$CONF_DIR" \
  "$SCRIPTS_DIR" \
  "$XFCE_DIR" \
  "$CONF_DIR/nginx" \
  "$CONF_DIR/supervisor" \
  "$HOME" \
  "$HOME/.config" \
  "$HOME/Desktop" \
  "$HOME/Templates"

touch "$HOME/.Xauthority" 2>/dev/null || true
chmod 600 "$HOME/.Xauthority" 2>/dev/null || true

# ------------------------------------------------------------
# Helper: remove CRLF
# ------------------------------------------------------------
fix_crlf() {
  local f="$1"
  sed -i 's/\r$//' "$f" 2>/dev/null || true
}

# ------------------------------------------------------------
# Ownership + perms
# ------------------------------------------------------------
if [[ "$(id -u)" == "0" ]]; then
  chown -R "$USER:$USER" "$CONF_DIR" "$HOME" 2>/dev/null || true
fi

chmod -R u+rwX \
  "$SCRIPTS_DIR" \
  "$XFCE_DIR" \
  "$CONF_DIR/nginx" \
  "$CONF_DIR/supervisor" \
  2>/dev/null || true

# ------------------------------------------------------------
# Seed defaults (missing only OR forced overwrite)
# ------------------------------------------------------------
seed_dir_files() {
  local src="$1" dst="$2" mode="${3:-missing}"  # missing|force
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"

  find "$src" -type f -print0 | while IFS= read -r -d '' f; do
    local rel out
    rel="${f#$src/}"
    out="$dst/$rel"
    mkdir -p "$(dirname "$out")"

    if [[ "$mode" == "force" ]]; then
      cp -af "$f" "$out"
      fix_crlf "$out"
      log "Re-seeded (forced) $out"
    else
      if [[ ! -e "$out" ]]; then
        cp -a "$f" "$out"
        fix_crlf "$out"
        log "Seeded $out"
      fi
    fi
  done
}

SEED_MODE="missing"
if [[ "$FORCE_RESEED" == "1" ]]; then
  SEED_MODE="force"
  log "FORCE_RESEED=1 enabled, overwriting existing files from /opt/defaults"
fi

seed_dir_files /opt/defaults/xfce4        "$XFCE_DIR"            "$SEED_MODE"
seed_dir_files /opt/defaults/scripts      "$SCRIPTS_DIR"         "$SEED_MODE"
seed_dir_files /opt/defaults/nginx        "$CONF_DIR/nginx"      "$SEED_MODE"
seed_dir_files /opt/defaults/supervisor   "$CONF_DIR/supervisor" "$SEED_MODE"

find "$SCRIPTS_DIR" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# After seeding, enforce ownership again (important if FORCE_RESEED copied root-owned files)
if [[ "$(id -u)" == "0" ]]; then
  chown -R "$USER:$USER" \
    "$SCRIPTS_DIR" \
    "$XFCE_DIR" \
    "$CONF_DIR/nginx" \
    "$CONF_DIR/supervisor" \
    "$HOME" \
    2>/dev/null || true
fi

chmod -R u+rwX \
  "$SCRIPTS_DIR" \
  "$XFCE_DIR" \
  "$CONF_DIR/nginx" \
  "$CONF_DIR/supervisor" \
  2>/dev/null || true

# ------------------------------------------------------------
# Redirect HOME XFCE config via symlink (no overwrite)
# ------------------------------------------------------------
mkdir -p "$HOME/.config" || true

# ~/.config/xfce4 -> /data/conf/xfce4
if [[ -L "$HOME/.config/xfce4" ]]; then
  :
elif [[ -e "$HOME/.config/xfce4" ]]; then
  log "NOTE: $HOME/.config/xfce4 exists and is not a symlink (leaving as-is)"
else
  ln -s "$XFCE_DIR" "$HOME/.config/xfce4"
  [[ "$(id -u)" == "0" ]] && chown -h "$USER:$USER" "$HOME/.config/xfce4" 2>/dev/null || true
  log "Linked ~/.config/xfce4 -> /data/conf/xfce4"
fi

# ------------------------------------------------------------
# XFCE kiosk mode (kioskrc)
# Templates live in /data/conf/xfce4:
#   /data/conf/xfce4/kioskrc.on
#   /data/conf/xfce4/kioskrc.off
#
# Active kioskrc lives in HOME so wineuser can always write:
#   $HOME/.config/xfce_kiosk/kioskrc.current
#
# System kioskrc points to it (created as root):
#   /etc/xdg/xfce4/kiosk/kioskrc -> $HOME/.config/xfce_kiosk/kioskrc.current
# ------------------------------------------------------------
KIOSK_HOME_DIR="$HOME/.config/xfce_kiosk"
KIOSK_CUR="$KIOSK_HOME_DIR/kioskrc.current"
KIOSK_OFF="$XFCE_DIR/kioskrc.off"

mkdir -p "$KIOSK_HOME_DIR"

# Ensure active kioskrc exists (default OFF)
if [[ ! -f "$KIOSK_CUR" ]]; then
  if [[ -f "$KIOSK_OFF" ]]; then
    cp -f "$KIOSK_OFF" "$KIOSK_CUR"
  else
    : > "$KIOSK_CUR"
  fi
fi

# Ensure user owns HOME kiosk dir
if [[ "$(id -u)" == "0" ]]; then
  chown -R "$USER:$USER" "$KIOSK_HOME_DIR" 2>/dev/null || true
fi

# Create system kioskrc symlink (root only)
if [[ "$(id -u)" == "0" ]]; then
  SYS_KIOSK_DIR="/etc/xdg/xfce4/kiosk"
  SYS_KIOSK_RC="$SYS_KIOSK_DIR/kioskrc"
  mkdir -p "$SYS_KIOSK_DIR"
  ln -sf "$KIOSK_CUR" "$SYS_KIOSK_RC"
fi

# ------------------------------------------------------------
# Force Windows-style copy/paste in xfce4-terminal
#   Copy  = Ctrl+X
#   Paste = Ctrl+V
# ------------------------------------------------------------
apply_xfce_terminal_windows_clipboard() {
  local accels_dir="$HOME/.config/xfce4/terminal"
  local accels="$accels_dir/accels.scm"

  mkdir -p "$accels_dir"

  local COPY_LINE='(gtk_accel_path "<Actions>/terminal-window/copy" "<Primary>x")'
  local PASTE_LINE='(gtk_accel_path "<Actions>/terminal-window/paste" "<Primary>v")'

  if [[ -f "$accels" ]]; then
    # Remove any existing copy/paste bindings (keep everything else)
    grep -vE '^\(gtk_accel_path "<Actions>/terminal-window/(copy|paste)" ' "$accels" > "${accels}.tmp" || true
  else
    # Create a new one
    cat > "${accels}.tmp" <<'EOF'
; xfce4-terminal accelerator file
EOF
  fi

  # Append our desired bindings
  {
    printf "\n%s\n" "$COPY_LINE"
    printf "%s\n" "$PASTE_LINE"
  } >> "${accels}.tmp"

  install -m 0644 "${accels}.tmp" "$accels"
  rm -f "${accels}.tmp"

  # Fix ownership if running as root
  if [[ "$(id -u)" == "0" ]]; then
    chown "$USER:$USER" "$accels" 2>/dev/null || true
  fi

  log "Applied xfce4-terminal Windows clipboard hotkeys: Ctrl+C / Ctrl+V"
}

apply_xfce_terminal_windows_clipboard || true

# ------------------------------------------------------------
# Start supervisor
# ------------------------------------------------------------
exec /usr/bin/supervisord -c "$CONF_DIR/supervisor/supervisord.conf"

