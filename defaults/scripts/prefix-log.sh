#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

name="${LOG_PREFIX:-${SUPERVISOR_PROCESS_NAME:-log}}"
export PREFIX="[$name]"

# Helps if anything inside is python
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"

prefix_perl() {
  perl -pe 'BEGIN{$|=1} print $ENV{PREFIX}." ";'
}

# Preferred: run under a PTY so output streams live (like a real terminal)
if command -v script >/dev/null 2>&1; then
  cmd="$(printf '%q ' "$@")"
  script -q -f -c "$cmd" /dev/null 2>&1 | prefix_perl
  exit "${PIPESTATUS[0]}"
fi

# Fallback: no PTY (some programs may buffer)
"$@" 2>&1 | prefix_perl
exit "${PIPESTATUS[0]}"
