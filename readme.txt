============================================================
Containerized Desktop with noVNC, Wine, and Native Storage
(Based on Debian Trixie)
============================================================

OVERVIEW
--------

This project provides a browser-accessible Linux desktop environment
running inside a Docker container based on Debian Trixie. It is designed
for x86-based Docker environments including Linux hosts, Windows Docker
Desktop, and other standard x86 container runtimes.

The system exposes a full graphical desktop through a web browser using
noVNC. Internally it uses a virtual X11 display, a lightweight desktop
environment, and a reverse proxy to route HTTP and WebSocket traffic.
Wine and Winetricks are included to allow Windows-based graphical
applications to run inside the Linux desktop session.

The architecture is designed to:
- Work consistently across x86 Docker environments
- Support both modern and legacy web browsers
- Switch dynamically between full desktop and kiosk-style operation
- Allow runtime customization without rebuilding the image
- Avoid instability caused by non-native bind-mounted filesystems

All persistent runtime state is stored on a native Linux filesystem
mounted inside the container.

------------------------------------------------------------

QUICK START
-----------

Requirements:
- Docker installed
- x86-based host
- A web browser

1. Build the image:

   docker build -t docker_novnc_wine .

2. Run the container:

   docker run \
     -p 8080:8080 \
     -v ./data:/data \
     --privileged \
     docker_novnc_wine

3. Open a browser and navigate to:

   http://localhost:8080

The desktop should appear in the browser after a short startup delay.

------------------------------------------------------------

HIGH-LEVEL ARCHITECTURE
----------------------

Browser
  -> nginx (HTTP and WebSocket routing)
  -> noVNC (HTML5 VNC client)
  -> websockify (WebSocket to TCP bridge)
  -> x11vnc (VNC server)
  -> Xvfb (virtual X11 display)
  -> XFCE (desktop environment)
  -> Wine (Windows compatibility layer)

A lightweight HTTP control API coordinates runtime behavior such as
switching between desktop and kiosk modes.

All long-running services are managed by supervisor.

------------------------------------------------------------

CORE COMPONENTS AND PURPOSE
---------------------------

Xvfb (Virtual X Server)
----------------------
Provides an in-memory X11 display. Containers do not have access to
physical displays, but graphical applications require an X server.
Xvfb enables deterministic, headless graphical operation without GPU
access.

XFCE Desktop Environment
------------------------
Provides window management, panels, keyboard shortcuts, and desktop
behavior.

XFCE is used because it is lightweight, stable in remote sessions,
scriptable through its configuration system, and predictable when
dynamically locked down or restored.

Wine and Winetricks
-------------------
Wine provides a compatibility layer that allows Windows-based graphical
applications to run inside the Linux desktop environment without
requiring a Windows virtual machine.

Winetricks is included as a helper tool to install runtime components,
libraries, fonts, and configuration commonly required by Windows
applications running under Wine.

x11vnc
------
Exports the Xvfb display using the VNC protocol.

Raw VNC access is optional and primarily intended for debugging or
fallback access. Browser access uses noVNC instead.

websockify
----------
Bridges browser WebSocket connections to the raw VNC TCP stream.

Browsers cannot speak VNC directly. websockify enables noVNC to operate
entirely over standard web technologies.

noVNC (Default and Legacy)
--------------------------
noVNC runs entirely in the browser and renders the remote desktop.

Two versions are installed:
- A modern default version
- A legacy version for older or embedded browsers

nginx automatically selects the appropriate version based on the
client User-Agent.

nginx
-----
Acts as a reverse proxy and static file server.

It is responsible for:
- Serving the web UI
- Routing traffic to the correct noVNC version
- Proxying required WebSocket connections
- Proxying the control API

nginx is required for normal operation of the web interface.

Wrapper Pages
-------------
Wrapper pages load noVNC inside an iframe and coordinate runtime
behavior, including mode switching and session coordination.

Mode Control API
----------------
A small HTTP control API coordinates runtime mode switching between
desktop and kiosk modes.

Supervisor
----------
Supervisor runs as PID 1 and manages all long-running services.

------------------------------------------------------------

SCRIPTS AND RUNTIME LOGIC
------------------------

The container uses a set of shell and Python scripts to orchestrate
startup, configuration, mode switching, and user customization.

entrypoint.sh        - Root. Primary container entrypoint.
runtime_entrypoint.sh- Root. Mounts storage and prepares runtime.
vdisk_mount.sh       - Root. Creates and mounts the ext4 disk image.
seed_and_run.sh      - Root. Seeds config and starts supervisor.
startup.sh           - User. Optional user startup hook.
kiosk_mode.sh        - User. Applies desktop or kiosk configuration.
toolbar_api.py       - Root service. Invokes user-level actions safely.
vnc_hook.sh          - User. Optional VNC session hook.
kiosk_hook.sh        - User. Optional kiosk-mode hook.

Scripts are intentionally small, idempotent, and separated by
responsibility to keep runtime behavior transparent and adjustable.

------------------------------------------------------------

PERSISTENT NATIVE FILESYSTEM
----------------------------

All runtime state is stored on a loop-mounted ext4 filesystem inside
the container.

This avoids instability and performance problems associated with
non-native filesystems commonly used by Docker Desktop and other
container environments.

Why --privileged is required
----------------------------
The container mounts an ext4 filesystem image using Linux loop devices.
Mounting and managing loop devices requires kernel privileges not
granted to standard containers.

--privileged enables:
- Access to /dev/loop-control and /dev/loop* devices
- Loop device setup
- Mount operations inside the container

------------------------------------------------------------

EXTERNAL ENVIRONMENT VARIABLES
------------------------------

Only the variables listed below are intended for external use.
All others are internal implementation details.

TZ - Sets the container timezone.
     Example: TZ=America/Chicago

SCREEN_WIDTH - Sets the virtual desktop width in pixels.
               Requires a container restart.

SCREEN_HEIGHT - Sets the virtual desktop height in pixels.
                Requires a container restart.

SCREEN_DPI - Controls DPI and font scaling for the virtual display.
             Requires a container restart.

VDISK_SIZE - Size of the internal ext4 filesystem image.
             Used only on first creation.

STARTUP_SCRIPT - Optional script or command executed once after startup.

WALLPAPER - Path to a wallpaper image on the persistent volume.

SSH_PASSWORD - Password for SSH login.
               SSH access is optional and for debugging only.

------------------------------------------------------------

PORT USAGE
----------

Required external ports:
- 8080  Web UI (HTTP + WebSocket)

Optional external ports:
- 5900  Raw VNC
- 22    SSH

Internal-only ports (DO NOT publish):
- 6080  websockify
- 9001  control API

------------------------------------------------------------

BUILDING THE IMAGE (DOCKER CLI)
-------------------------------

docker build -t docker_novnc_wine .

------------------------------------------------------------

WINDOWS BATCH FILES
------------------

run.cmd    - Runs the container.
build.cmd  - Builds the image.
cbuild.cmd - Cleans config, rebuilds, and runs.
abuild.cmd - Cleans all data, rebuilds, and runs.

------------------------------------------------------------

MINIMAL RECOMMENDED USAGE
------------------------

docker run \
  -p 8080:8080 \
  -v ./data:/data \
  --privileged \
  docker_novnc_wine

------------------------------------------------------------

FULL EXAMPLE WITH ALL SUPPORTED ENV AND OPTIONAL PORTS
-----------------------------------------------------

docker run \
  -p 8080:8080 \
  -p 5900:5900 \
  -p 22:22 \
  -e TZ=America/Chicago \
  -e SCREEN_WIDTH=1920 \
  -e SCREEN_HEIGHT=1080 \
  -e SCREEN_DPI=96 \
  -e VDISK_SIZE=6G \
  -e STARTUP_SCRIPT=/data/startup/startup.sh \
  -e WALLPAPER=/data/background.jpg \
  -e SSH_PASSWORD=changeme \
  -v ./data:/data \
  --privileged \
  docker_novnc_wine

------------------------------------------------------------

INTERNAL-ONLY CONFIGURATION
---------------------------

Any option, variable, or port not documented above is considered an
internal implementation detail and should not be modified.

============================================================
