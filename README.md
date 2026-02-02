# Containerized Desktop with noVNC, Wine, and Native Storage
_Based on Debian Trixie_

## Overview

This project provides a browser-accessible Linux desktop environment running
inside a Docker container based on Debian Trixie. It is designed for x86-based
Docker environments including Linux hosts, Windows Docker Desktop, and other
standard x86 container runtimes.

The system exposes a full graphical desktop through a web browser using noVNC.
Internally it uses a virtual X11 display, a lightweight desktop environment,
and a reverse proxy to route HTTP and WebSocket traffic. Wine and Winetricks
are included to allow Windows-based graphical applications to run inside the
Linux desktop session.

The architecture is designed to:

- Work consistently across x86 Docker environments
- Support both modern and legacy web browsers
- Switch dynamically between full desktop and kiosk-style operation
- Allow runtime customization without rebuilding the image
- Avoid instability caused by non-native bind-mounted filesystems

All persistent runtime state is stored on a native Linux filesystem mounted
inside the container.

---

## Quick Start

### Requirements

- Docker installed
- x86-based host
- A web browser

### Steps

1. Build the image

```bash
docker build -t docker_novnc_wine .
```

2. Run the container

```bash
docker run \
  -p 8080:8080 \
  -v ./data:/data \
  --privileged \
  docker_novnc_wine
```

3. Open a browser

http://localhost:8080

The desktop should appear in the browser after a short startup delay.
