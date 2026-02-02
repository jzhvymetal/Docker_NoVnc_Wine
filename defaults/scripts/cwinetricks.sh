#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------
# cwinetricks.sh
#
# Copies a per-verb cached folder from a "persistent" cache into W_CACHE, then runs real winetricks.
#
# Example:
#   export W_CACHE=/mnt/vdisk/winetricks-cache
#   export SRC_INSTALLS=/data/winetricks-cache
#   cwinetricks -q dotnet46
#
# Notes:
# - Expects verb cache layout: $SRC_INSTALLS/<verb>/...
# - Will NOT copy the whole cache, only the verb folder if it exists.

# ----

log(){ echo "[cwinetricks] $*" >&2; }

REAL_WINETRICKS="${REAL_WINETRICKS:-/usr/local/bin/winetricks}"

# Your persistent/volume cache root (where preseeded verb folders live)
SRC_INSTALLS="${SRC_INSTALLS:-/data/winetricks-cache}"

# Working cache root on native filesystem (Winetricks uses W_CACHE)
W_CACHE="${W_CACHE:-}"

if [[ -z "${W_CACHE}" ]]; then
  log "ERROR: W_CACHE is not set."
  log "Set W_CACHE to a native filesystem path (example: /mnt/vdisk/winetricks-cache)."
  exit 2
fi

if [[ ! -x "${REAL_WINETRICKS}" ]]; then
  log "ERROR: REAL_WINETRICKS not found or not executable: ${REAL_WINETRICKS}"
  exit 2
fi

mkdir -p "${W_CACHE}"

# Parse first "verb" token from args:
# - Skip common flags and flag-arguments where appropriate
# - Take the first token that does not start with '-' as the verb
verb=""

args=("$@")
i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"

  # Flags that consume the next argument
  case "$a" in
    -q|-v|-V|-h|--help|--version|--self-update|--force|--unattended|--gui|--no-isolate|--isolate)
      i=$((i+1))
      continue
      ;;
    --country|--keep_isos|--optout|--debug|--arch|--prefix|--bottle|--force-update|--download|--no-download)
      # Some of these may or may not take an arg depending on winetricks version,
      # but treating them as "takes next arg" is safer for verb detection.
      i=$((i+2))
      continue
      ;;
  esac

  if [[ "$a" == --* ]]; then
    # Handle --flag=value
    if [[ "$a" == *=* ]]; then
      i=$((i+1))
      continue
    fi
    # Unknown --flag, assume no arg and skip
    i=$((i+1))
    continue
  fi

  if [[ "$a" == -* ]]; then
    # Unknown short flag, skip it
    i=$((i+1))
    continue
  fi

  # First non-flag token is the verb
  verb="$a"
  break
done

if [[ -n "${verb}" ]]; then
  src_dir="${SRC_INSTALLS%/}/${verb}"
  dst_dir="${W_CACHE%/}/${verb}"

  if [[ -d "${src_dir}" ]]; then
    log "Found cached verb folder: ${src_dir}"
    mkdir -p "${dst_dir}"

    # Copy directory contents, overwrite existing files, keep it fast.
    # Prefer rsync if available, else fallback to cp.
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete --inplace "${src_dir%/}/" "${dst_dir%/}/"
    else
      # Ensure dst exists, then copy contents in
      rm -rf "${dst_dir}"
      mkdir -p "${dst_dir}"
      cp -a "${src_dir%/}/." "${dst_dir%/}/"
    fi
  else
    log "No cached verb folder for '${verb}' at ${src_dir} (will let winetricks download as needed)."
  fi
else
  log "No verb detected in args, running winetricks as-is."
fi

export W_CACHE

# Run the real winetricks with original args
exec "${REAL_WINETRICKS}" "$@"