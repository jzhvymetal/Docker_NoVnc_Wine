#!/usr/bin/env bash
set -Eeuo pipefail

LOG="/tmp/open_xfce_terminal.log"
log(){ echo "[open-xfce-terminal] $*" | tee -a "$LOG" >&2; }

TITLE="Terminal"
CWD=""
KEEP_OPEN=1
CENTER=0

# INHERIT:
#   auto = if called from a real terminal (tty), run inline (no new window)
#   0    = always open a new xfce4-terminal window
#   1    = always run inline
INHERIT="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)      TITLE="${2:-Terminal}"; shift 2;;
    --cwd)        CWD="${2:-}"; shift 2;;
    --keep-open)  KEEP_OPEN="${2:-1}"; shift 2;;
    --inherit)    INHERIT="${2:-auto}"; shift 2;;
    --new-window) INHERIT="0"; shift;;
    --center)     CENTER=1; shift;;
    --) shift; break;;
    *) log "Unknown arg: $1"; exit 2;;
  esac
done

if [[ $# -lt 1 ]]; then
  log "No command provided. Use: ... -- <command...>"
  exit 2
fi

export DISPLAY="${DISPLAY:-:0}"
TARGET_USER="${USER:-wineuser}"

if [[ -z "$CWD" ]]; then
  CWD="${HOME:-/}"
fi

# Decide whether to inherit current terminal
is_tty=0
if [[ -t 0 && -t 1 ]]; then is_tty=1; fi
if tty -s 2>/dev/null; then is_tty=1; fi

case "$INHERIT" in
  1) do_inherit=1;;
  0) do_inherit=0;;
  auto) do_inherit=$is_tty;;
  *) log "Bad --inherit value: $INHERIT (use auto|0|1)"; exit 2;;
esac

if [[ "$do_inherit" == "1" ]]; then
  # Run inside the current terminal, no GUI window
  cd "$CWD" || exit 1

  printf '[terminal] Running:' >&2
  for a in "$@"; do printf ' %q' "$a" >&2; done
  printf '\n' >&2

  set +e
  "$@"
  rc=$?
  set -e

  if [[ "$KEEP_OPEN" == "1" ]]; then
    echo >&2
    echo "[terminal] Exit code: $rc" >&2
    echo >&2
  fi
  exit "$rc"
fi

# Lock so concurrent boot calls do not race the "before/after" window diff
LOCK="/tmp/open_xfce_terminal.lock"
exec 9>"$LOCK"
if ! flock -w 10 9; then
  log "WARNING: could not acquire lock quickly; centering may be less reliable"
fi

# Get DBUS session address from running xfce4-session (best effort)
SESSION_PID="$(pgrep -u "$TARGET_USER" -n xfce4-session 2>/dev/null || true)"
DBUS_ADDR=""
if [[ -n "$SESSION_PID" && -r "/proc/$SESSION_PID/environ" ]]; then
  while IFS= read -r -d '' kv; do
    case "$kv" in
      DBUS_SESSION_BUS_ADDRESS=*) DBUS_ADDR="${kv#DBUS_SESSION_BUS_ADDRESS=}" ;;
    esac
  done <"/proc/$SESSION_PID/environ"
  log "Using xfce4-session pid=$SESSION_PID env: DBUS=${DBUS_ADDR:+set}"
else
  log "WARNING: Could not read xfce4-session environment. pid=${SESSION_PID:-none}"
fi

# Always set a writable XDG_RUNTIME_DIR
UID_NOW="$(id -u)"
XDG_RT="/tmp/xdg-runtime-${UID_NOW}"
mkdir -p "$XDG_RT" 2>/dev/null || true
chmod 700 "$XDG_RT" 2>/dev/null || true

# Require xdotool only if we need centering
if [[ "$CENTER" == "1" ]]; then
  if ! command -v xdotool >/dev/null 2>&1; then
    log "WARNING: --center requested but xdotool not found; skipping centering"
    CENTER=0
  fi
fi

# Capture existing xfce4-terminal windows before launching (for diff)
BEFORE_IDS=""
if [[ "$CENTER" == "1" ]]; then
  BEFORE_IDS="$(xdotool search --onlyvisible --class xfce4-terminal 2>/dev/null || true)"
fi

# Wrapper script that runs the command and optionally keeps the terminal open
TMP="$(mktemp /tmp/xfce_term_cmd.XXXXXX.sh)"
chmod +x "$TMP"

RUNLINE="$(printf '%q ' "$@")"

{
  echo '#!/usr/bin/env bash'
  echo 'set -Eeuo pipefail'
  printf 'cd %q\n' "$CWD"

  # Print what we are running
  printf 'echo "[terminal] Running: %s"\n' "$RUNLINE"

  echo 'set +e'
  # Run the exact command line (already properly %q escaped)
  echo "$RUNLINE"
  echo 'rc=$?'
  echo 'set -e'

  if [[ "$KEEP_OPEN" == "1" ]]; then
    echo 'echo'
    echo 'echo "[terminal] Exit code: $rc"'
    echo 'echo'
    echo 'exec bash'
  else
    echo 'exit $rc'
  fi
} >"$TMP"

TS="$(date +%s)"
TLOG="/tmp/xfce4-terminal.${TS}.log"

ENV_PREFIX=(env DISPLAY="$DISPLAY" XDG_RUNTIME_DIR="$XDG_RT")
[[ -n "$DBUS_ADDR" ]] && ENV_PREFIX+=(DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR")

log "Launching terminal title='$TITLE' cwd='$CWD' wrapper='$TMP' log='$TLOG' center=$CENTER"

"${ENV_PREFIX[@]}" xfce4-terminal \
  --disable-server \
  --title="$TITLE" \
  --working-directory="$CWD" \
  --command="$TMP" \
  >"$TLOG" 2>&1 &

launcher_pid=$!
sleep 0.2 || true

# Center the newly created window by diffing window IDs
if [[ "$CENTER" == "1" ]]; then
  new_wid=""

  # Normalize BEFORE to sorted unique list
  before_sorted="$(printf '%s\n' $BEFORE_IDS 2>/dev/null | awk 'NF' | sort -n | uniq)"

  for _ in $(seq 1 80); do
    after_ids="$(xdotool search --onlyvisible --class xfce4-terminal 2>/dev/null || true)"
    after_sorted="$(printf '%s\n' $after_ids 2>/dev/null | awk 'NF' | sort -n | uniq)"

    # new = after - before
    new_wid="$(comm -13 <(printf '%s\n' "$before_sorted") <(printf '%s\n' "$after_sorted") | tail -n 1 || true)"
    [[ -n "$new_wid" ]] && break
    sleep 0.1
  done

  # Fallback: if diff failed, just take the last visible xfce4-terminal
  if [[ -z "$new_wid" ]]; then
    new_wid="$(xdotool search --onlyvisible --class xfce4-terminal 2>/dev/null | tail -n 1 || true)"
  fi

  if [[ -n "$new_wid" ]]; then
    # Wait for non-zero geometry
    for _ in $(seq 1 40); do
      read -r SW SH < <(xdotool getdisplaygeometry)
      read -r WW WH < <(
        xdotool getwindowgeometry "$new_wid" 2>/dev/null |
        awk -F'[: x]+' '/Geometry:/{print $3, $4; exit}'
      )
      if [[ -n "${WW:-}" && -n "${WH:-}" && "$WW" -gt 0 && "$WH" -gt 0 ]]; then
        NX=$(( (SW - WW) / 2 ))
        NY=$(( (SH - WH) / 2 ))
        (( NX < 0 )) && NX=0
        (( NY < 0 )) && NY=0
        xdotool windowmove "$new_wid" "$NX" "$NY" 2>/dev/null || true
        xdotool windowactivate "$new_wid" 2>/dev/null || true
        log "Centered window id=$new_wid to ${NX},${NY}"
        break
      fi
      sleep 0.1
    done
  else
    log "WARNING: could not detect new xfce4-terminal window to center"
  fi
fi

if ! kill -0 "$launcher_pid" 2>/dev/null; then
  log "WARNING: xfce4-terminal launcher exited quickly. Check $TLOG"
else
  log "xfce4-terminal launcher pid=$launcher_pid launched"
fi
