#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[startup-hook] $*"; }

# Normalize STARTUP_SCRIPT:
# - allow it to be empty
# - accept Windows-style slashes
# - accept values like "data/..." and convert to "/data/..."
STARTUP_SCRIPT="${STARTUP_SCRIPT:-}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//\\//}"
if [[ "$STARTUP_SCRIPT" == data/* ]]; then
  STARTUP_SCRIPT="/$STARTUP_SCRIPT"
fi

run_path() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    log "Skip (missing): $path"
    return 0
  fi

  log "BEGIN: $path"
  bash "$path" || log "WARNING: $path exited with $?"
  log "END:   $path"
}

run_cmd() {
  local cmd="$1"
  [[ -n "$cmd" ]] || return 0

  log "BEGIN: command: $cmd"
  bash -lc "$cmd" || log "WARNING: command exited with $?"
  log "END:   command"
}

log "STARTUP_SCRIPT='${STARTUP_SCRIPT}'"

# 1) Always run config startup first (if present)
run_path "/data/conf/scripts/startup.sh"

# 2) Then run CLI-provided script second (if set)
if [[ -n "$STARTUP_SCRIPT" ]]; then
  if [[ -f "$STARTUP_SCRIPT" ]]; then
    run_path "$STARTUP_SCRIPT"
  else
    # Treat as a command string (allows args)
    run_cmd "$STARTUP_SCRIPT"
  fi
else
  log "No STARTUP_SCRIPT provided. Done."
fi
