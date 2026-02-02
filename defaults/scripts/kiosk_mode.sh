#!/usr/bin/env bash
# FILE: /data/conf/scripts/kiosk_mode.sh

set -Eeuo pipefail

MODE="${1:-status}"

CONF_DIR="${CONF_DIR:-/data/conf}"
XFCE_TEMPLATES="$CONF_DIR/xfce4"

USER_NAME="${KIOSK_USER:-${USER:-wineuser}}"
if [[ "$USER_NAME" == "root" ]]; then USER_NAME="wineuser"; fi
HOME_DIR="${HOME:-/mnt/vdisk/home/${USER_NAME}}"

# Active kioskrc lives in HOME (always writable)
KIOSK_HOME_DIR="$HOME_DIR/.config/xfce_kiosk"
KIOSK_CUR="$KIOSK_HOME_DIR/kioskrc.current"

# Templates live in /data/conf (persistent)
KIOSK_ON="$XFCE_TEMPLATES/kioskrc.on"
KIOSK_OFF="$XFCE_TEMPLATES/kioskrc.off"

# Shortcut profiles (TSV) live in /data/conf so they survive container restarts
# - shortcuts.vnc.tsv: your normal VNC profile (backup)
# - shortcuts.kiosk.tsv: kiosk profile (typically disables launcher hotkeys)
# - shortcuts.current.tsv: last applied profile (in HOME, for idempotence)
SHORTCUTS_VNC="$XFCE_TEMPLATES/shortcuts.vnc.tsv"
SHORTCUTS_KIOSK="$XFCE_TEMPLATES/shortcuts.kiosk.tsv"
SHORTCUTS_CUR="$KIOSK_HOME_DIR/shortcuts.current.tsv"

log(){ echo "[kiosk_mode] $*"; }

ensure_files() {
  mkdir -p "$XFCE_TEMPLATES" "$KIOSK_HOME_DIR"

  [[ -f "$KIOSK_ON"  ]]  || { log "ERROR: missing $KIOSK_ON";  exit 1; }
  [[ -f "$KIOSK_OFF" ]]  || { log "ERROR: missing $KIOSK_OFF"; exit 1; }

  # Default OFF if no current file
  if [[ ! -f "$KIOSK_CUR" ]]; then
    cp -f "$KIOSK_OFF" "$KIOSK_CUR"
  fi
}

# Import DISPLAY/DBUS from the running XFCE session so xfconf-query works reliably
import_xfce_env() {
  # If DBUS is broken (example: "unix:path"), unset it so tools do not error/pop dialogs
  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    if [[ "$DBUS_SESSION_BUS_ADDRESS" == "unix:path" || "$DBUS_SESSION_BUS_ADDRESS" != *"="* ]]; then
      unset DBUS_SESSION_BUS_ADDRESS
    fi
  fi

  if [[ -n "${DISPLAY:-}" && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    return 0
  fi

  local pid
  pid="$(pgrep -u "$USER_NAME" -n xfce4-session 2>/dev/null || true)"
  [[ -n "$pid" ]] || {
    # Fallback
    export DISPLAY="${DISPLAY:-:0}"
    return 0
  }

  local envline
  envline="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null || true)"

  if [[ -z "${DISPLAY:-}" ]]; then
    DISPLAY="$(printf '%s\n' "$envline" | awk -F= '$1=="DISPLAY"{print $2; exit}')"
    export DISPLAY="${DISPLAY:-:0}"
  fi

  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    DBUS_SESSION_BUS_ADDRESS="$(printf '%s\n' "$envline" | awk -F= '$1=="DBUS_SESSION_BUS_ADDRESS"{print $2; exit}')"
    # Sanity check
    if [[ -n "$DBUS_SESSION_BUS_ADDRESS" && "$DBUS_SESSION_BUS_ADDRESS" == *"="* ]]; then
      export DBUS_SESSION_BUS_ADDRESS
    else
      unset DBUS_SESSION_BUS_ADDRESS
    fi
  fi
}

as_user() {
  # Run a command as USER_NAME with the right session environment.
  if [[ "$(id -un 2>/dev/null || echo "")" == "$USER_NAME" ]]; then
    "$@"
    return $?
  fi

  local -a envcmd
  envcmd=(env "DISPLAY=${DISPLAY:-:0}" "HOME=$HOME_DIR" "USER=$USER_NAME" "LOGNAME=$USER_NAME"
              "XDG_CONFIG_HOME=$HOME_DIR/.config" "XDG_DATA_HOME=$HOME_DIR/.local/share" "PATH=$PATH")

  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    envcmd+=("DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS")
  fi

  # XDG_RUNTIME_DIR helps some desktop components, but only set it if it exists
  local uid
  uid="$(id -u "$USER_NAME" 2>/dev/null || true)"
  if [[ -n "$uid" && -d "/run/user/$uid" ]]; then
    envcmd+=("XDG_RUNTIME_DIR=/run/user/$uid")
  fi

  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$USER_NAME" -- "${envcmd[@]}" "$@"
    return $?
  fi

  # Fallback to su if runuser is not available
  if command -v su >/dev/null 2>&1; then
    local cmd
    cmd="$(printf "%q " "$@")"
    local pre
    pre="DISPLAY=$(printf %q "${DISPLAY:-:0}") HOME=$(printf %q "$HOME_DIR") USER=$(printf %q "$USER_NAME") LOGNAME=$(printf %q "$USER_NAME")"
    pre="$pre XDG_CONFIG_HOME=$(printf %q "$HOME_DIR/.config") XDG_DATA_HOME=$(printf %q "$HOME_DIR/.local/share") PATH=$(printf %q "$PATH")"
    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
      pre="$pre DBUS_SESSION_BUS_ADDRESS=$(printf %q "$DBUS_SESSION_BUS_ADDRESS")"
    fi
    su -s /bin/bash "$USER_NAME" -c "$pre $cmd"
    return $?
  fi

  return 127
}

xfset() {
  # xfset <channel> <property> <type> <value>
  local ch="$1" prop="$2" typ="$3" val="$4"
  command -v xfconf-query >/dev/null 2>&1 || return 0
  as_user xfconf-query -n -c "$ch" -p "$prop" -t "$typ" -s "$val" >/dev/null 2>&1 || true
}

xfget() {
  local ch="$1" prop="$2"
  command -v xfconf-query >/dev/null 2>&1 || return 1
  as_user xfconf-query -c "$ch" -p "$prop" 2>/dev/null || return 1
}

refresh_xfconf_cache() {
  pkill -u "$USER_NAME" xfconfd >/dev/null 2>&1 || true
  sleep 0.15
}

# -----------------------------
# Shortcut profiles (/commands/custom/*)
# -----------------------------
shortcuts_export_current() {
  # Export /commands/custom/* into a TSV: path<TAB>type<TAB>value
  # Robust parsing: xfconf-query -lv output is column-aligned with spaces on some distros.
  local out="$1"
  mkdir -p "$(dirname "$out")"

  if ! command -v xfconf-query >/dev/null 2>&1; then
    log "xfconf-query missing; cannot export shortcuts"
    return 1
  fi

  as_user xfconf-query -c xfce4-keyboard-shortcuts -lv 2>/dev/null \
    | awk '
        $1 ~ "^/commands/custom/" {
          path=$1;
          val="";
          if (NF >= 2) {
            val=$2;
            for (i=3; i<=NF; i++) val=val " " $i;
          }
          typ="string";
          if (path ~ "/startup-notify$" || path ~ "/override$") typ="bool";
          print path "\t" typ "\t" val;
        }
      ' > "$out" || return 1

  return 0
}

shortcuts_clear_custom() {
  if ! command -v xfconf-query >/dev/null 2>&1; then
    return 0
  fi

  # Use -l which prints one property per line (no alignment issues).
  as_user xfconf-query -c xfce4-keyboard-shortcuts -l 2>/dev/null \
    | grep '^/commands/custom/' \
    | while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        as_user xfconf-query -c xfce4-keyboard-shortcuts -p "$p" -r >/dev/null 2>&1 || true
      done
}

shortcuts_apply_profile() {
  local in="$1"
  [[ -f "$in" ]] || return 1

  if ! command -v xfconf-query >/dev/null 2>&1; then
    log "xfconf-query missing; cannot apply shortcuts"
    return 1
  fi

  # If already applied, skip to avoid flicker
  if [[ -f "$SHORTCUTS_CUR" ]] && cmp -s "$SHORTCUTS_CUR" "$in"; then
    return 0
  fi

  shortcuts_clear_custom

  while IFS=$'\t' read -r path typ val; do
    [[ -n "$path" ]] || continue
    [[ -n "$typ" ]] || typ="string"

    if [[ "$typ" == "bool" ]]; then
      if [[ "$val" != "true" && "$val" != "false" ]]; then
        val="false"
      fi
      as_user xfconf-query -n -c xfce4-keyboard-shortcuts -p "$path" -t bool -s "$val" >/dev/null 2>&1 || true
    else
      # string (val may be empty to disable a shortcut)
      as_user xfconf-query -n -c xfce4-keyboard-shortcuts -p "$path" -t string -s "${val-}" >/dev/null 2>&1 || true
    fi
  done < "$in"

  cp -f "$in" "$SHORTCUTS_CUR"
  return 0
}

shortcuts_make_kiosk_profile_from_vnc() {
  # Default kiosk profile: disable all /commands/custom/* launchers by blanking string values.
  # Keep bool keys like /startup-notify and /override.
  [[ -f "$SHORTCUTS_VNC" ]] || return 1

  mkdir -p "$(dirname "$SHORTCUTS_KIOSK")"

  awk -F'\t' '
    {
      path=$1; typ=$2; val=$3;
      if (typ == "bool") {
        print path "\t" typ "\t" val;
      } else {
        print path "\t" "string" "\t";
      }
    }
  ' "$SHORTCUTS_VNC" > "$SHORTCUTS_KIOSK"
}

shortcuts_profile_sane() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  # Must look like TSV with at least two tab-separated fields and a /commands/custom path.
  awk -F'\t' 'NF >= 2 && $1 ~ "^/commands/custom/" {ok=1} END{exit ok?0:1}' "$f"
}

ensure_shortcuts_profiles() {
  # Create VNC backup if missing (export current)
  if [[ ! -f "$SHORTCUTS_VNC" ]] || ! shortcuts_profile_sane "$SHORTCUTS_VNC"; then
    if shortcuts_export_current "$SHORTCUTS_VNC"; then
      log "created shortcut backup: $SHORTCUTS_VNC"
    else
      log "WARN: could not create $SHORTCUTS_VNC (xfce not ready yet?)"
    fi
  fi

  # Create kiosk profile if missing (default: disable all custom commands)
  if [[ ! -f "$SHORTCUTS_KIOSK" ]]; then
    if [[ -f "$SHORTCUTS_VNC" ]]; then
      shortcuts_make_kiosk_profile_from_vnc || true
      if [[ -f "$SHORTCUTS_KIOSK" ]]; then
        log "created default kiosk shortcuts: $SHORTCUTS_KIOSK (all custom launchers disabled)"
      fi
    fi
  fi
}

apply_shortcuts_on() {
  ensure_shortcuts_profiles
  if [[ -f "$SHORTCUTS_KIOSK" ]]; then
    shortcuts_apply_profile "$SHORTCUTS_KIOSK" || true
  fi
}

apply_shortcuts_off() {
  ensure_shortcuts_profiles
  if [[ -f "$SHORTCUTS_VNC" ]]; then
    shortcuts_apply_profile "$SHORTCUTS_VNC" || true
  fi
}

# -----------------------------
# Visual kiosk behavior
# -----------------------------
apply_visual_on() {
  # Disable right-click desktop menu
  xfset xfce4-desktop "/desktop-menu/show" bool false

  # Disable middle-click window list menu
  xfset xfce4-desktop "/windowlist-menu/show" bool false

  # Disable desktop icons
  xfset xfce4-desktop "/desktop-icons/style" int 0
}

apply_visual_off() {
  # Enable right-click desktop menu
  xfset xfce4-desktop "/desktop-menu/show" bool true

  # Enable middle-click window list menu
  xfset xfce4-desktop "/windowlist-menu/show" bool true

  # Enable desktop icons
  xfset xfce4-desktop "/desktop-icons/style" int 2
}

panel_hide() {
  # No D-Bus, no popup dialogs
  pkill -u "$USER_NAME" xfce4-panel >/dev/null 2>&1 || true
  sleep 0.15
}

panel_show() {
  # Start panel if not running
  if ! pgrep -u "$USER_NAME" xfce4-panel >/dev/null 2>&1; then
    as_user nohup xfce4-panel >/tmp/xfce4-panel.log 2>&1 &
    disown || true
    sleep 0.25
  fi
}

desktop_reload() {
  # Make desktop menu/icon settings take effect
  if command -v xfdesktop >/dev/null 2>&1; then
    as_user xfdesktop --reload >/dev/null 2>&1 || {
      pkill -u "$USER_NAME" xfdesktop >/dev/null 2>&1 || true
      sleep 0.15
      as_user nohup xfdesktop >/tmp/xfdesktop.log 2>&1 &
      disown || true
    }
  fi
  sleep 0.25
}

verify_and_fix_once() {
  local want="$1"
  local menu winmenu icons panel_running

  menu="$(xfget xfce4-desktop /desktop-menu/show 2>/dev/null || echo "unknown")"
  winmenu="$(xfget xfce4-desktop /windowlist-menu/show 2>/dev/null || echo "unknown")"
  icons="$(xfget xfce4-desktop /desktop-icons/style 2>/dev/null || echo "unknown")"

  if pgrep -u "$USER_NAME" xfce4-panel >/dev/null 2>&1; then
    panel_running="yes"
  else
    panel_running="no"
  fi

  if [[ "$want" == "on" ]]; then
    # Expect: menu=false, winmenu=false, icons=0, panel_running=no
    if [[ "$menu" != "false" || "$winmenu" != "false" || "$icons" != "0" || "$panel_running" != "no" ]]; then
      log "verify mismatch (menu=$menu winmenu=$winmenu icons=$icons panel=$panel_running). retry once..."
      refresh_xfconf_cache
      apply_shortcuts_on
      apply_visual_on
      panel_hide
      desktop_reload
    fi
  else
    # Expect: menu=true, winmenu=true, icons=2, panel_running=yes
    if [[ "$menu" != "true" || "$winmenu" != "true" || "$icons" != "2" || "$panel_running" != "yes" ]]; then
      log "verify mismatch (menu=$menu winmenu=$winmenu icons=$icons panel=$panel_running). retry once..."
      refresh_xfconf_cache
      apply_shortcuts_off
      apply_visual_off
      panel_show
      desktop_reload
    fi
  fi
}

status() {
  if [[ -f "$KIOSK_CUR" ]]; then
    if cmp -s "$KIOSK_CUR" "$KIOSK_ON"; then
      echo "kiosk"
      return
    fi
    if cmp -s "$KIOSK_CUR" "$KIOSK_OFF"; then
      echo "show"
      return
    fi
    echo "custom"
    return
  fi
  echo "unknown"
}

set_mode() {
  local want="$1"

  ensure_files
  import_xfce_env

  # Ensure shortcut profiles exist before we start changing anything
  ensure_shortcuts_profiles

  case "$want" in
    on)
      cp -f "$KIOSK_ON" "$KIOSK_CUR"
      refresh_xfconf_cache
      apply_shortcuts_on
      apply_visual_on
      panel_hide
      desktop_reload
      verify_and_fix_once on
      log "mode=on"
      ;;
    off)
      cp -f "$KIOSK_OFF" "$KIOSK_CUR"
      refresh_xfconf_cache
      apply_shortcuts_off
      apply_visual_off
      panel_show
      desktop_reload
      verify_and_fix_once off
      log "mode=off"
      ;;
    *)
      echo "Usage: $0 on|off|status" >&2
      exit 2
      ;;
  esac
}

case "$MODE" in
  status) ensure_files; status ;;
  on|off) set_mode "$MODE" ;;
  *) echo "Usage: $0 on|off|status" >&2; exit 2 ;;
esac
