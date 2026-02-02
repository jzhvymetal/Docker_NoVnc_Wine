#!/usr/bin/env python3
# toolbar_api.py
#
# Desktop stack API:
# - ensures desktop session is running (via supervisor)
# - applies kiosk mode using an external script (kiosk_mode.sh)
#
# Endpoints (proxied by nginx):
#   GET /kiosk?force=1  -> ensure desktop stack is running + kiosk_mode ON
#   GET /show?force=1   -> ensure desktop stack is running + kiosk_mode OFF
#   GET /mode           -> status (includes current_mode)
#
# Notes:
# - The original version ran kiosk_mode.sh on EVERY /kiosk or /show call.
#   If clients poll these endpoints (keepalive), XFCE can flicker or "flash"
#   as panels/desktop settings get re-applied repeatedly.
# - This version tracks the last applied mode and only calls kiosk_mode.sh
#   when a mode change is needed (or when force=1).
# - HTTP 200 is returned only when both the desktop stack is running AND
#   the requested mode was applied successfully. Otherwise 202 is returned.

import os
import json
import time
import threading
import subprocess
from urllib.parse import urlparse, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("TOOLBAR_API_HOST", "0.0.0.0")
PORT = int(os.environ.get("TOOLBAR_API_PORT", "9001"))

SUPERVISORCTL = os.environ.get("SUPERVISORCTL", "supervisorctl")

# Services controlled by supervisor.
# For XFCE we typically use ONE service: "xfce".
WM_SERVICE = os.environ.get("WM_SERVICE", "xfce").strip() or "xfce"
DESKTOP_SERVICE = os.environ.get("DESKTOP_SERVICE", "none").strip()

# IMPORTANT:
# This script owns all kiosk behavior. Toolbar API stays generic.
KIOSK_SCRIPT = os.environ.get("KIOSK_SCRIPT", "/data/conf/scripts/kiosk_mode.sh")

WAIT_MAX_SEC = float(os.environ.get("DESKTOP_WAIT_MAX_SEC", "8.0"))
WAIT_POLL_SEC = float(os.environ.get("DESKTOP_WAIT_POLL_SEC", "0.2"))

# Extra time to let XFCE/WM apply kiosk changes AFTER kiosk_mode.sh returns.
MODE_APPLY_DELAY_SEC = float(os.environ.get("MODE_APPLY_DELAY_SEC", "0.8"))

# Optional: wait until X is responding before applying kiosk changes.
X_READY_MAX_SEC = float(os.environ.get("X_READY_MAX_SEC", "6.0"))
X_READY_POLL_SEC = float(os.environ.get("X_READY_POLL_SEC", "0.2"))
X_READY_CMD = os.environ.get("X_READY_CMD", "").strip()  # if set, runs this instead of default probes

# ============================
# Client logging (browser info)
# ============================
# Logs a single line per client signature (ip + user-agent) per TTL window.
LOG_CLIENT = os.environ.get("TOOLBAR_LOG_CLIENT", "1").strip().lower() not in ("0", "false", "no", "off")
LOG_CLIENT_TTL_SEC = float(os.environ.get("TOOLBAR_LOG_CLIENT_TTL_SEC", "120"))
LOG_CLIENT_MAX_UA = int(os.environ.get("TOOLBAR_LOG_CLIENT_MAX_UA", "220"))
LOG_CLIENT_MAX_REF = int(os.environ.get("TOOLBAR_LOG_CLIENT_MAX_REF", "300"))

_seen_lock = threading.Lock()
_seen_clients = {}  # key -> last_ts

_switch_lock = threading.Lock()
_last_switch_ts = 0.0

# Mode tracking (best-effort). Prevents repeated re-apply flicker.
_current_mode = "unknown"  # "on" or "off" once applied
_last_apply_ts = 0.0


def _desktop_service_enabled() -> bool:
    ds = (DESKTOP_SERVICE or "").strip()
    if not ds:
        return False
    if ds.lower() in ("none", "null", "0", "false"):
        return False
    if ds == WM_SERVICE:
        return False
    return True


def services_start_order():
    if _desktop_service_enabled():
        return [WM_SERVICE, DESKTOP_SERVICE]
    return [WM_SERVICE]


def services_stop_order():
    if _desktop_service_enabled():
        return [DESKTOP_SERVICE, WM_SERVICE]
    return [WM_SERVICE]


def run_cmd(args, timeout=10):
    env = os.environ.copy()
    env.setdefault("DISPLAY", ":0")
    p = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        env=env,
    )
    return p.returncode, p.stdout, p.stderr


def supervisor_status_map():
    rc, out, _err = run_cmd([SUPERVISORCTL, "status"], timeout=5)
    if rc != 0:
        return {}

    m = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            name = parts[0].strip()
            state = parts[1].strip()
            m[name] = state
    return m


def is_running(service_name, status_map=None):
    if status_map is None:
        status_map = supervisor_status_map()
    return status_map.get(service_name) == "RUNNING"


def stack_running(status_map=None):
    if status_map is None:
        status_map = supervisor_status_map()

    # If supervisorctl isn't giving us anything, don't claim it's down.
    if not status_map:
        return True

    if _desktop_service_enabled():
        return is_running(WM_SERVICE, status_map) and is_running(DESKTOP_SERVICE, status_map)

    return is_running(WM_SERVICE, status_map)


def supervisor_stop(service_name):
    run_cmd([SUPERVISORCTL, "stop", service_name], timeout=10)


def supervisor_start(service_name):
    run_cmd([SUPERVISORCTL, "start", service_name], timeout=10)


def wait_stack_ready(max_sec=WAIT_MAX_SEC):
    end = time.time() + max_sec
    while time.time() < end:
        st = supervisor_status_map()
        if stack_running(st):
            return True
        time.sleep(WAIT_POLL_SEC)
    return False


def desktop_stack(action):
    action = (action or "").lower().strip()

    if action == "stop":
        for s in services_stop_order():
            supervisor_stop(s)
        return True

    if action == "start":
        for s in services_start_order():
            supervisor_start(s)
        return wait_stack_ready()

    # restart
    for s in services_stop_order():
        supervisor_stop(s)
    for s in services_start_order():
        supervisor_start(s)
    return wait_stack_ready()


def wait_x_ready(max_sec=X_READY_MAX_SEC):
    # If user provided a custom ready command, use it.
    if X_READY_CMD:
        end = time.time() + max_sec
        while time.time() < end:
            rc, _out, _err = run_cmd(["/bin/sh", "-lc", X_READY_CMD], timeout=3)
            if rc == 0:
                return True
            time.sleep(X_READY_POLL_SEC)
        return False

    # Default probes (best-effort). If tools aren't installed, we treat as "can't test".
    probes = [
        ["xset", "q"],
        ["xdpyinfo"],
    ]

    end = time.time() + max_sec
    while time.time() < end:
        for cmd in probes:
            try:
                rc, _out, _err = run_cmd(cmd, timeout=3)
            except FileNotFoundError:
                rc = 127
            if rc == 0:
                return True
        time.sleep(X_READY_POLL_SEC)

    return False


def set_kiosk_mode(mode: str):
    # mode: "on" or "off"
    if not os.path.exists(KIOSK_SCRIPT):
        return False, f"missing_script:{KIOSK_SCRIPT}"

    rc, out, err = run_cmd([KIOSK_SCRIPT, mode], timeout=20)
    ok = (rc == 0)
    msg = (out.strip() if out.strip() else err.strip())
    return ok, (msg if msg else "ok")


def build_status_payload():
    st = supervisor_status_map()

    svc_states = {WM_SERVICE: st.get(WM_SERVICE, "UNKNOWN")}
    if _desktop_service_enabled():
        svc_states[DESKTOP_SERVICE] = st.get(DESKTOP_SERVICE, "UNKNOWN")

    return {
        "services": svc_states,
        "running": stack_running(st),
        "last_switch_ts": _last_switch_ts,
        "kiosk_script": KIOSK_SCRIPT,
        "wm_service": WM_SERVICE,
        "desktop_service": (DESKTOP_SERVICE if _desktop_service_enabled() else "none"),
        "current_mode": _current_mode,
        "last_apply_ts": _last_apply_ts,
    }


def ensure_ready(force: bool, want_kiosk: bool):
    global _last_switch_ts, _current_mode, _last_apply_ts

    if not _switch_lock.acquire(blocking=False):
        payload = build_status_payload()
        payload.update({
            "ok": False,
            "busy": True,
            "changed": False,
            "message": "switch_in_progress",
        })
        return 202, payload

    try:
        desired_mode = "on" if want_kiosk else "off"

        st = supervisor_status_map()
        running = stack_running(st)

        restarted = False
        if force or not running:
            ok_stack = desktop_stack("restart" if force else "start")
            restarted = True
            _last_switch_ts = time.time()

            # If supervisor says "RUNNING", still give X a chance to come up.
            # If this probe fails, we keep going (best-effort).
            if ok_stack:
                wait_x_ready()

        # Decide whether we actually need to (re)apply kiosk settings.
        # This prevents repeated XFCE flicker if clients poll /kiosk or /show.
        apply_needed = force or restarted or (_current_mode != desired_mode)

        ok_mode = True
        msg_mode = "skipped"
        if apply_needed:
            ok_mode, msg_mode = set_kiosk_mode(desired_mode)
            if ok_mode:
                _current_mode = desired_mode
                _last_apply_ts = time.time()
                if MODE_APPLY_DELAY_SEC > 0:
                    time.sleep(MODE_APPLY_DELAY_SEC)

        payload = build_status_payload()
        running_now = bool(payload.get("running"))

        # Consider it OK only if:
        # - stack is running, and
        # - kiosk_mode.sh succeeded (or was skipped because already applied), and
        # - our current_mode matches the desired_mode
        ok_all = running_now and bool(ok_mode) and (_current_mode == desired_mode)

        payload.update({
            "ok": ok_all,
            "busy": False,
            "changed": restarted,
            "requested_mode": desired_mode,
            "applied": bool(apply_needed),
            "mode_ok": bool(ok_mode),
            "mode_msg": msg_mode,
            "message": "ready" if ok_all else ("starting" if not running_now else "applying"),
        })

        return (200 if ok_all else 202), payload

    finally:
        _switch_lock.release()


def _clip(s: str, n: int) -> str:
    if s is None:
        return ""
    s = str(s)
    if len(s) <= n:
        return s
    return s[: max(0, n - 3)] + "..."


def _now_iso() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())


class Handler(BaseHTTPRequestHandler):
    server_version = "toolbar_api/kiosk-script-1.2+clientlog"

    def _send_json(self, code: int, payload: dict):
        body = json.dumps(payload, indent=2).encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return

    def log_message(self, fmt, *args):
        return

    def _client_ip(self) -> str:
        # Prefer forwarded headers from nginx if present.
        xff = self.headers.get("X-Forwarded-For", "")
        if xff:
            return xff.split(",")[0].strip()
        xri = self.headers.get("X-Real-IP", "")
        if xri:
            return xri.strip()
        return str(self.client_address[0])

    def _maybe_log_client(self, path: str, force_flag: bool):
        if not LOG_CLIENT:
            return

        ip = self._client_ip()
        ua = self.headers.get("User-Agent", "")
        ref = self.headers.get("Referer", "") or self.headers.get("Referrer", "")
        origin = self.headers.get("Origin", "")
        lang = self.headers.get("Accept-Language", "")
        host = self.headers.get("Host", "")

        key = f"{ip}|{ua}"
        now = time.time()

        with _seen_lock:
            last = _seen_clients.get(key, 0.0)
            if (now - last) < LOG_CLIENT_TTL_SEC:
                return
            _seen_clients[key] = now

            # opportunistic cleanup to keep dict bounded
            if len(_seen_clients) > 2000:
                cutoff = now - LOG_CLIENT_TTL_SEC
                for k, ts in list(_seen_clients.items()):
                    if ts < cutoff:
                        _seen_clients.pop(k, None)

        print(
            f"[{_now_iso()}] [toolbar_api] client "
            f"ip={ip} path={path} force={1 if force_flag else 0} "
            f"host={_clip(host, 120)!r} "
            f"ua={_clip(ua, LOG_CLIENT_MAX_UA)!r} "
            f"lang={_clip(lang, 120)!r} "
            f"origin={_clip(origin, 200)!r} "
            f"referer={_clip(ref, LOG_CLIENT_MAX_REF)!r}",
            flush=True
        )

    def do_GET(self):
        try:
            u = urlparse(self.path)
            path = u.path
            q = parse_qs(u.query)
            force = (q.get("force", ["0"])[0].strip() == "1")

            # Log browser/client info once per TTL window (prevents /mode spam)
            self._maybe_log_client(path=path, force_flag=force)

            if path in ("/", "/debug", "/mode"):
                payload = build_status_payload()
                payload.update({"ok": True})
                self._send_json(200, payload)
                return

            if path in ("/kiosk", "/hide"):
                code, payload = ensure_ready(force=force, want_kiosk=True)
                self._send_json(code, payload)
                return

            if path in ("/show", "/desktop"):
                code, payload = ensure_ready(force=force, want_kiosk=False)
                self._send_json(code, payload)
                return

            if path in ("/restart", "/reset"):
                desktop_stack("restart")
                payload = build_status_payload()
                payload.update({"ok": True, "message": "restarted"})
                self._send_json(200, payload)
                return

            payload = {"ok": False, "error": "not_found", "path": path}
            self._send_json(404, payload)

        except Exception as e:
            payload = {"ok": False, "error": "exception", "message": str(e)}
            self._send_json(500, payload)


def main():
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True
    httpd.serve_forever()


if __name__ == "__main__":
    main()
