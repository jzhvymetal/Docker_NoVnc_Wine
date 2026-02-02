#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[vdisk] $*"; }
die(){ echo "[vdisk][ERROR] $*"; exit 1; }

VDISK_DIR="${VDISK_DIR:-/data/vdisk}"
VDISK_FILE="${VDISK_FILE:-/data/vdisk/vdisk.img}"
VDISK_SIZE="${VDISK_SIZE:-6G}"
VDISK_MOUNT="${VDISK_MOUNT:-/mnt/vdisk}"

# Runtime user (used for HOME + ownership)
RUN_USER="${USER:-wineuser}"

# Where Wine lives on the vdisk
WINEPREFIX_DIR="${WINEPREFIX_DIR:-${WINEPREFIX:-${VDISK_MOUNT}/wineprefix}}"

# Persistent Linux HOME on the vdisk
VDISK_HOME_BASE="${VDISK_HOME_BASE:-${VDISK_MOUNT}/home}"
VDISK_HOME="${VDISK_HOME:-${VDISK_HOME_BASE}/${RUN_USER}}"

# Compatibility HOME path in container
OLD_HOME_BASE="/home"
OLD_HOME="${OLD_HOME_BASE}/${RUN_USER}"

log "dir=$VDISK_DIR file=$VDISK_FILE size=$VDISK_SIZE mount=$VDISK_MOUNT"
log "run_user=$RUN_USER"
log "vdisk_home=$VDISK_HOME"
log "old_home=$OLD_HOME"
log "wineprefix=$WINEPREFIX_DIR"
log "id=$(id)"
log "/data fstype=$(stat -f -c %T /data 2>/dev/null || echo unknown)"

mkdir -p /data || true

# If /data/vdisk exists but isn't a directory, fix it
if [ -e "$VDISK_DIR" ] && [ ! -d "$VDISK_DIR" ]; then
  log "WARN: $VDISK_DIR exists but is not a directory -> renaming to ${VDISK_DIR}.bak"
  mv -f "$VDISK_DIR" "${VDISK_DIR}.bak" 2>/dev/null || rm -f "$VDISK_DIR" || true
fi

mkdir -p "$VDISK_DIR" "$VDISK_MOUNT" || true

DES_BYTES="$(numfmt --from=iec "$VDISK_SIZE" 2>/dev/null || true)"
[ -n "${DES_BYTES:-}" ] || die "Cannot parse VDISK_SIZE='$VDISK_SIZE'"

# Ensure fixed-size file exists and is exactly DES_BYTES
need_recreate=0
if [ ! -f "$VDISK_FILE" ]; then
  need_recreate=1
else
  CUR_BYTES="$(stat -c%s "$VDISK_FILE" 2>/dev/null || echo 0)"
  log "existing image bytes=$CUR_BYTES (desired=$DES_BYTES)"
  if [ "$CUR_BYTES" -ne "$DES_BYTES" ]; then
    need_recreate=1
  fi
fi

if [ "$need_recreate" = "1" ]; then
  log "creating FIXED image using dd seek: $VDISK_FILE ($VDISK_SIZE)"
  rm -f "$VDISK_FILE" || true
  dd if=/dev/zero of="$VDISK_FILE" bs=1 count=0 seek="$DES_BYTES" status=none || true
fi

CUR_BYTES="$(stat -c%s "$VDISK_FILE" 2>/dev/null || echo 0)"
log "final image bytes=$CUR_BYTES (desired=$DES_BYTES)"
if [ "$CUR_BYTES" -ne "$DES_BYTES" ]; then
  die "vdisk.img size mismatch (Windows bind-mount may not support this). Use a Docker named volume for /data instead of C:\\...:/data."
fi

# Format ext4 if no filesystem signature
if ! blkid "$VDISK_FILE" >/dev/null 2>&1; then
  log "formatting ext4..."
  mkfs.ext4 -F "$VDISK_FILE"
else
  log "filesystem already present (blkid OK)"
fi

# Mount if not already mounted
if ! mountpoint -q "$VDISK_MOUNT"; then
  log "mounting loop,rw..."
  mount -o loop,rw "$VDISK_FILE" "$VDISK_MOUNT" || die "mount failed (need --privileged)"
fi

mountpoint -q "$VDISK_MOUNT" || die "mountpoint check failed: $VDISK_MOUNT"
log "mounted OK: $(df -hT "$VDISK_MOUNT" 2>/dev/null || true)"

# ------------------------------------------------------------
# Multi-user permissions on /mnt/vdisk
# - keep writable for everyone (sticky like /tmp)
# - BUT owner must be RUN_USER so Wine does not reject it
# ------------------------------------------------------------
mkdir -p "$VDISK_MOUNT/shared" "$VDISK_HOME_BASE" || true


# Make Wine happy: /mnt/vdisk must be owned by the user running wine
if id "$RUN_USER" >/dev/null 2>&1; then
chown "$RUN_USER:$RUN_USER" "$VDISK_MOUNT" 2>/dev/null || true
fi


# Sticky bit so all users can create folders/files safely
chmod 1777 "$VDISK_MOUNT" 2>/dev/null || true
chmod 1777 "$VDISK_MOUNT/shared" 2>/dev/null || true
chmod 1777 "$VDISK_HOME_BASE" 2>/dev/null || true

# ------------------------------------------------------------
# Create required persistent dirs AFTER mount (otherwise mount hides them)
# ------------------------------------------------------------
mkdir -p "$WINEPREFIX_DIR" || die "failed to create $WINEPREFIX_DIR"
mkdir -p "$VDISK_HOME" || die "failed to create $VDISK_HOME"

# ------------------------------------------------------------
# FORCE HOME ON VDISK:
# 1) passwd home -> /mnt/vdisk/home/$USER
# 2) /home/$USER -> /mnt/vdisk/home/$USER symlink
# 3) one-time migrate old /home/$USER content if needed
# ------------------------------------------------------------
HOME_FROM_PASSWD="$(getent passwd "$RUN_USER" | cut -d: -f6 || true)"
if [ -n "$HOME_FROM_PASSWD" ] && [ "$HOME_FROM_PASSWD" != "$VDISK_HOME" ]; then
  log "Fixing passwd HOME ($HOME_FROM_PASSWD) -> $VDISK_HOME"
  usermod -d "$VDISK_HOME" "$RUN_USER" 2>/dev/null || true
fi

mkdir -p "$OLD_HOME_BASE" || true

if [ -L "$OLD_HOME" ]; then
  tgt="$(readlink "$OLD_HOME" || true)"
  if [ "$tgt" != "$VDISK_HOME" ]; then
    log "WARN: $OLD_HOME links to '$tgt', fixing -> $VDISK_HOME"
    rm -f "$OLD_HOME" || true
    ln -s "$VDISK_HOME" "$OLD_HOME"
  else
    log "OK: $OLD_HOME already links to $VDISK_HOME"
  fi
else
  if [ -e "$OLD_HOME" ]; then
    timestamp="$(date +%Y%m%d_%H%M%S)"
    backup_path="${OLD_HOME}.bak.${timestamp}"

    if [ -d "$OLD_HOME" ]; then
      if [ -z "$(ls -A "$VDISK_HOME" 2>/dev/null || true)" ]; then
        log "Migrating contents: $OLD_HOME -> $VDISK_HOME (vdisk home is empty)"
        cp -a "$OLD_HOME/." "$VDISK_HOME/" || true
      else
        log "VDISK home not empty, skipping migration"
      fi
    fi

    log "Moving existing $OLD_HOME -> $backup_path"
    mv -f "$OLD_HOME" "$backup_path" 2>/dev/null || rm -rf "$OLD_HOME" || true
  fi

  log "Creating symlink: $OLD_HOME -> $VDISK_HOME"
  ln -s "$VDISK_HOME" "$OLD_HOME"
fi

# ------------------------------------------------------------
# Ownership
# - Do NOT chown -R /mnt/vdisk/home (breaks multi-user)
# - Only set ownership on the current user's home + wineprefix
# ------------------------------------------------------------
if id "$RUN_USER" >/dev/null 2>&1; then
  chown -R "$RUN_USER:$RUN_USER" "$WINEPREFIX_DIR" "$VDISK_HOME" 2>/dev/null || true
  chown -h "$RUN_USER:$RUN_USER" "$OLD_HOME" 2>/dev/null || true

  # ensure user can use their own home
  chmod 0755 "$VDISK_HOME" 2>/dev/null || true
fi

log "wineprefix:  $(ls -ld "$WINEPREFIX_DIR" 2>/dev/null || true)"
log "home(vdisk): $(ls -ld "$VDISK_HOME" 2>/dev/null || true)"
log "home(link):  $(ls -ld "$OLD_HOME" 2>/dev/null || true)"
log "shared:      $(ls -ld "$VDISK_MOUNT/shared" 2>/dev/null || true)"