# FILE: Dockerfile
# syntax=docker/dockerfile:1.6
FROM debian:trixie


# NOTE:
# Docker does NOT expand ${USER} inside ENV the way a shell does.
# We set a fixed default USER and HOME. If you override USER at runtime,
# runtime_entrypoint.sh will still force HOME to /mnt/vdisk/home/$USER.
ENV DEBIAN_FRONTEND=noninteractive \
	TZ=America/Chicago \
    DISPLAY=:0 \
    SCREEN_WIDTH=1920 \
    SCREEN_HEIGHT=1080 \
    SCREEN_DPI=96 \
    USER=wineuser \
    HOME=/mnt/vdisk/home/wineuser \
    WINEARCH=win32 \
    WINEPREFIX=/mnt/vdisk/wineprefix \
    VDISK_DIR=/data/vdisk \
    VDISK_FILE=/data/vdisk/vdisk.img \
    VDISK_SIZE=6G \
    VDISK_MOUNT=/mnt/vdisk \
    WALLPAPER=/data/background.jpg \
    XDG_CACHE_HOME=/tmp/XDG_CACHE \
	W_CACHE=/tmp/WINETRICKS_CACHE  \
    CONF_DIR=/data/conf \
    BROWSER="/usr/bin/chromium"

# -----------------------------
# Base packages
# -----------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg wget git \
      bash tini inotify-tools \
      unzip p7zip-full cabextract xz-utils aria2 unshield zenity \
	  tzdata \
      \
      # X + VNC + Tools
      xvfb x11vnc xfonts-base xauth x11-xserver-utils x11-utils \
      feh xdotool autocutsel\
      \
      # XFCE desktop
      xfce4 xfce4-terminal xfce4-taskmanager dbus dbus-x11 \
      \
	  chromium xdg-utils\
      #reverse proxy
      websockify \
      nginx supervisor \
      python3 procps net-tools \
      winbind \
      fontconfig fonts-dejavu-core fonts-dejavu-extra \
      \
      # vdisk mount tooling
      util-linux e2fsprogs coreutils \
      \
      # SSH
      openssh-server \
      \
      # Windows helpers (optional)
      mingw-w64 \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd


# -----------------------------
# noVNC (upstream via git)
#   /usr/share/novnc        -> master (default)
#   /usr/share/novnc1.5.0   -> v1.5.0  (Need for older browser which lacks modern JS)
# -----------------------------
ARG NOVNC_MASTER_REF=master
ARG NOVNC_LEGACY_REF=v1.5.0

RUN set -eux; \
  \
  clone_novnc() { \
    ref="$1"; dest="$2"; \
    rm -rf "$dest"; \
    mkdir -p "$dest"; \
    git init "$dest"; \
    git -C "$dest" remote add origin https://github.com/novnc/noVNC.git; \
    git -C "$dest" fetch --depth 1 origin "$ref"; \
    git -C "$dest" checkout -q FETCH_HEAD; \
    git -C "$dest" submodule update --init --recursive --depth 1 || true; \
    ln -sf vnc.html "$dest/index.html"; \
  }; \
  \
  clone_novnc "${NOVNC_MASTER_REF}" /usr/share/novnc; \
  clone_novnc "${NOVNC_LEGACY_REF}" /usr/share/novnc1.5.0; \
  \
  # Keep novnc_proxy pointing at the master tree (change if you prefer legacy)
  ln -sf /usr/share/novnc/utils/novnc_proxy /usr/local/bin/novnc_proxy; \
  chmod +x /usr/share/novnc/utils/novnc_proxy || true



# -----------------------------
# WineHQ stable (Trixie)
# -----------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d; \
    curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
      | gpg --dearmor -o /etc/apt/keyrings/winehq-archive.gpg; \
    curl -fsSL https://dl.winehq.org/wine-builds/debian/dists/trixie/winehq-trixie.sources \
      -o /etc/apt/sources.list.d/winehq-trixie.sources; \
    sed -i 's|/etc/apt/keyrings/winehq-archive\.key|/etc/apt/keyrings/winehq-archive.gpg|g' \
      /etc/apt/sources.list.d/winehq-trixie.sources; \
    apt-get update; \
    apt-get install -y --install-recommends winehq-stable; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------
# Winetricks (upstream)
# -----------------------------
RUN set -eux; \
    curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
      -o /usr/local/bin/winetricks; \
    chmod +x /usr/local/bin/winetricks


RUN set -eux; \
    if ! id -u "${USER}" >/dev/null 2>&1; then \
      useradd -m -d "${HOME}" -s /bin/bash "${USER}"; \
    fi; \
    mkdir -p \
      /data \
      /data/conf/scripts \
      /data/conf/xfce4 \
      /opt/defaults \
      /mnt/vdisk \
      /mnt/vdisk/home \
      /home \
      /run/sshd \
      /tmp \
      /tmp/.cache \
      /tmp/.X11-unix \
      "${HOME}/Desktop" \
      "${HOME}/.config" \
      "${XDG_CACHE_HOME}" \
      "${W_CACHE}" \
    ; \
    chmod 1777 /tmp /tmp/.cache /tmp/.X11-unix; \
    chmod -R 0777 /data /mnt/vdisk || true; \
    chmod 0777 "${XDG_CACHE_HOME}" "${W_CACHE}" || true; \
    chown -R "${USER}:${USER}" "${HOME}" /data || true
	
# -----------------------------
# Copy defaults
# -----------------------------
COPY defaults/ /opt/defaults/

# Ensure scripts are executable
RUN set -eux; \
    chmod +x /opt/defaults/scripts/*.sh || true; \
    chmod +x /opt/defaults/scripts/*.py 2>/dev/null || true; \
    true

VOLUME ["/data"]

EXPOSE 8080 5900 22

ENTRYPOINT ["/usr/bin/tini","--","/opt/defaults/scripts/entrypoint.sh"]
