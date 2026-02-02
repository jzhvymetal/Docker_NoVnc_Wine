#!/usr/bin/env bash
# FILE: defaults/scripts/run_xfce.sh
set -Eeuo pipefail

log(){ echo "[run_xfce] $*"; }

DISPLAY="${DISPLAY:-:0}"
USER_NAME="${USER:-wineuser}"
HOME_DIR="${HOME:-/mnt/vdisk/home/${USER_NAME}}"
WALLPAPER="${WALLPAPER:-/data/background.jpg}"

export DISPLAY
export USER="$USER_NAME"
export HOME="$HOME_DIR"

mkdir -p "$HOME_DIR" "$HOME_DIR/.config" "$HOME_DIR/Desktop" 2>/dev/null || true
chown -R "${USER_NAME}:${USER_NAME}" "$HOME_DIR" 2>/dev/null || true

# Keyboard layout (best-effort)
setxkbmap -layout us -option >/dev/null 2>&1 || true

have_xfconf() { command -v xfconf-query >/dev/null 2>&1; }

xfset() {
  # Compatibility wrapper: xfset <channel> <property> <type> <value>
  # Example: xfset xfwm4 /general/workspace_count int 1
  local channel="${1:-}" prop="${2:-}" type="${3:-}" value="${4:-}"
  [[ -n "$channel" && -n "$prop" && -n "$type" ]] || return 0
  have_xfconf || return 0

  case "$type" in
    int)    xfconf-query -c "$channel" -p "$prop" -s "${value:-0}" -t int    --create >/dev/null 2>&1 || true ;;
    bool)   xfconf-query -c "$channel" -p "$prop" -s "${value:-false}" -t bool --create >/dev/null 2>&1 || true ;;
    string) xfconf-query -c "$channel" -p "$prop" -s "${value:-}" -t string --create >/dev/null 2>&1 || true ;;
    *)      xfconf-query -c "$channel" -p "$prop" -s "${value:-}" -t string --create >/dev/null 2>&1 || true ;;
  esac
}

remove_panel_plugin_by_type() {
  # Usage: remove_panel_plugin_by_type <panel_id> <plugin_type>
  # Example: remove_panel_plugin_by_type 1 pager

  local panel_id="${1:-}"
  local plugin_type="${2:-}"

  [[ -n "$panel_id" && -n "$plugin_type" ]] || {
    echo "usage: remove_panel_plugin_by_type <panel_id> <plugin_type>" >&2
    return 2
  }

  command -v xfconf-query >/dev/null 2>&1 || return 0

  local panel_path="/panels/panel-${panel_id}/plugin-ids"

  # Read panel plugin-ids robustly.
  # Handles both:
  #   1) "Value is an array with N items:" then N lines of numbers
  #   2) "[1,2,3]" style single line
  local ids_raw ids
  ids_raw="$(xfconf-query -c xfce4-panel -p "$panel_path" 2>/dev/null || true)"

  if echo "$ids_raw" | grep -q "Value is an array"; then
    # Only lines that are purely an integer, so we do not capture the "N" in the header.
    ids="$(echo "$ids_raw" | awk 'NF==1 && $1 ~ /^[0-9]+$/ {print $1}' | xargs)"
  else
    # Bracket or mixed format.
    ids="$(echo "$ids_raw" | tr '[],' '   ' | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) print $i}' | xargs)"
  fi

  [[ -n "$ids" ]] || { echo "[xfce] no ids found for $panel_path (raw=$ids_raw)" >&2; return 1; }

  # Find plugin IDs whose type matches (pager, clock, systray, actions, etc)
  local remove_ids
  remove_ids="$(
    xfconf-query -c xfce4-panel -p /plugins -lv 2>/dev/null \
      | awk -v t="$plugin_type" '$2==t {print $1}' \
      | sed -n 's#^.*/plugin-\([0-9]\+\)$#\1#p' \
      | tr '\n' ' ' | xargs
  )"

  [[ -n "$remove_ids" ]] || { echo "[xfce] no plugins of type '$plugin_type' exist" >&2; return 0; }

  # Build new list, keeping order
  local new="" id rid removed=0
  for id in $ids; do
    for rid in $remove_ids; do
      if [[ "$id" == "$rid" ]]; then
        removed=1
        continue 2
      fi
    done
    new="$new $id"
  done
  new="$(echo "$new" | xargs)"

  if [[ "$removed" -eq 0 ]]; then
    echo "[xfce] panel-$panel_id: no '$plugin_type' present in [$ids]" >&2
    return 0
  fi

  [[ -n "$new" ]] || { echo "[xfce] refusing to empty panel-$panel_id" >&2; return 1; }

  echo "[xfce] panel-$panel_id remove '$plugin_type': [$ids] -> [$new]" >&2

  # Stop panel (dbus method) with fallback to pkill if dbus is flaky
  if pgrep -x xfce4-panel >/dev/null 2>&1; then
    xfce4-panel -q >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      pgrep -x xfce4-panel >/dev/null 2>&1 || break
      sleep 0.1
    done
    if pgrep -x xfce4-panel >/dev/null 2>&1; then
      pkill -TERM xfce4-panel >/dev/null 2>&1 || true
      for _ in $(seq 1 30); do
        pgrep -x xfce4-panel >/dev/null 2>&1 || break
        sleep 0.1
      done
    fi
  fi

  # Write array back in one shot
  local -a cmd
  cmd=(xfconf-query -c xfce4-panel -p "$panel_path" --force-array)
  for id in $new; do
    cmd+=(-t int -s "$id")
  done
  "${cmd[@]}" >/dev/null 2>&1 || true

  # Start panel again
  xfce4-panel >/dev/null 2>&1 || true
}

post_start() {
  # Wait a bit for xfconfd to be ready
  sleep 2

  # Force single workspace (xfwm4)
  xfset xfwm4 /general/workspace_count int 1

  # Wallpaper (best-effort)
  if [[ -f "$WALLPAPER" ]]; then
    for p in \
      /backdrop/screen0/monitor0/image-path \
      /backdrop/screen0/monitor0/workspace0/last-image \
      /backdrop/screen0/monitor0/workspace0/image-path \
      /backdrop/screen0/monitor0/workspace0/last-image \
      /backdrop/screen0/monitor1/workspace0/last-image \
      /backdrop/screen0/monitor1/workspace0/image-path \
      /backdrop/screen1/monitor0/workspace0/last-image \
      /backdrop/screen1/monitor0/workspace0/image-path
    do
      xfset xfce4-desktop "$p" string "$WALLPAPER"
    done
    xfset xfce4-desktop /backdrop/screen0/monitor0/workspace0/image-style int 3
  fi

  # Desktop menu knobs (best-effort)
  xfset xfce4-desktop /desktop-menu/show bool false
  xfset xfce4-desktop /desktop-menu/show-icons bool true

  # xfce4-terminal copy on select (best-effort)
  if have_xfconf; then
    xfconf-query -c xfce4-terminal -p /misc-copy-on-select -n -t bool -s true >/dev/null 2>&1 || true
    xfconf-query -c xfce4-desktop -p /desktop-icons/confirm-sorting -n -t bool -s false >/dev/null 2>&1 || true
  fi

  # Remove thumbnail-mode
  xfconf-query -c thunar -p /misc-thumbnail-mode -n -t string -s "never"	
	
  # Remove workspace pager from panel(s)
  remove_panel_plugin_by_type 1 pager
  
  xfce4-panel -r

  log "post_start applied (best-effort)"
}

log "Starting XFCE (HOME=$HOME_DIR DISPLAY=$DISPLAY)"
post_start &

# Start XFCE session (session bus)
if command -v dbus-launch >/dev/null 2>&1; then
  exec dbus-launch --exit-with-session startxfce4
fi

exec startxfce4