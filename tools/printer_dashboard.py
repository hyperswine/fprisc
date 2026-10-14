#!/usr/bin/env python3
"""LAN transport for examples/printers.fpr. No printer control endpoints.

One MQTT subscription per printer; public snapshot only contains an allowlist.
Camera TLS sockets exist only while a visible browser requests the MJPEG URL.
The FP-RISC binary owns rendering, sessions and update policy.
"""
from __future__ import annotations
import argparse
import collections
import contextlib
import datetime as dt
import http.client
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import select
import shlex
import signal
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie, CookieError
from urllib.parse import urlsplit
from printer_auth import Auth, load_keys, COOKIE, BINDING, CHALLENGE_SECONDS, SESSION_SECONDS

ROOT = Path(__file__).resolve().parents[1]
MAX_FRAME = 4 * 1024 * 1024
STATUS_FIELDS = {"gcode_state", "mc_percent", "nozzle_temper", "bed_temper", "mc_remaining_time", "layer_num", "total_layer_num", "nozzle_target_temper", "bed_target_temper", "gcode_file", "subtask_name", "wifi_signal", "print_error", "ams", "vt_tray"}


def merge(dst, src):
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            merge(dst[key], value)
        else:
            dst[key] = value


def numeric(value):
    return round(value, 1) if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else None


def short(value, default="—"):
    return str(value)[:160] if isinstance(value, (str, int, float)) else default


class Printer:
    def __init__(self, config, demo=False):
        self.config = config
        self.demo = demo
        self.lock = threading.RLock()
        self.state = {}
        self.connected = False
        self.last = 0.0
        self.last_wall = 0
        self.reports = 0
        self.times = collections.deque()
        self.note = "Demo telemetry. No printer is connected." if demo else "Waiting for a status report."
        self.client = None
        self.camera = Camera(self)

    def report(self, data):
        # Command acknowledgements are not a fresh telemetry sample.
        payload = data.get("print")
        if not isinstance(payload, dict) or not any(k in payload for k in ("gcode_state", "nozzle_temper", "bed_temper", "mc_percent", "layer_num", "mc_remaining_time")):
            return
        with self.lock:
            merge(self.state, {k: v for k, v in payload.items() if k in STATUS_FIELDS})
            self.last = time.monotonic()
            self.last_wall = int(time.time())
            self.reports += 1
            self.times.append(self.last)
            self.note = "Demo telemetry. No printer is connected." if self.demo else ""

    def snapshot(self):
        now = time.monotonic()
        with self.lock:
            while self.times and self.times[0] < now - 30:
                self.times.popleft()
            p = self.state
            status = "ONLINE" if self.connected and self.last and now - self.last < 15 else "STALE" if self.connected else "OFFLINE"
            # Reports per second over a complete sliding window, not reciprocal
            # of the last two packets (which overstates bursts).
            hz = round(len(self.times) / 30, 2)
            percent = numeric(p.get("mc_percent"))
            remaining = numeric(p.get("mc_remaining_time"))
            filament = []
            ams = p.get("ams") or {}
            if isinstance(ams, dict):
                for unit in (ams.get("ams") if isinstance(ams.get("ams"), list) else []):
                    if not isinstance(unit, dict):
                        continue
                    for tray in (unit.get("tray") if isinstance(unit.get("tray"), list) else []):
                        if isinstance(tray, dict) and tray.get("tray_type"):
                            filament.append(short(tray["tray_type"]))
            ext = p.get("vt_tray") or {}
            if isinstance(ext, dict) and ext.get("tray_type"):
                filament.append(short(ext["tray_type"]))
            error = p.get("print_error")
            return {"id": self.config["id"], "name": self.config["name"], "model": self.config["model"],
                    "location": self.config.get("location", "Workshop"), "connection": status,
                    "state": short(p.get("gcode_state"), "Waiting for telemetry"), "job": short(p.get("subtask_name") or p.get("gcode_file"), "No current job reported"),
                    "progress": max(0, min(100, int(percent))) if percent is not None else 0,
                    "remaining": f"{int(remaining)} min remaining" if remaining is not None else "Time unavailable",
                    "layers": f"Layer {short(p.get('layer_num'))} / {short(p.get('total_layer_num'))}",
                    "nozzle": numeric(p.get("nozzle_temper")), "nozzle_target": numeric(p.get("nozzle_target_temper")),
                    "bed": numeric(p.get("bed_temper")), "bed_target": numeric(p.get("bed_target_temper")),
                    "wifi": short(p.get("wifi_signal"), "Wi-Fi unavailable"), "report_hz": hz, "reports": self.reports,
                    "last_report": self.last_wall, "last_report_iso": dt.datetime.fromtimestamp(self.last_wall, dt.timezone.utc).isoformat() if self.last_wall else "—",
                    "error": "None reported" if error == 0 else short(error, "Not reported"), "filament": ", ".join(filament) or "Not reported",
                    "camera_available": self.config.get("camera", "bambu-jpeg") == "bambu-jpeg", "note": self.note, **self.camera.stats()}

    def start(self):
        if self.demo:
            self.connected = True
            return
        # Values are inherited at runtime. Never copy them into a public
        # snapshot, logs, browser attributes, URLs or subprocess arguments.
        import paho.mqtt.client as mqtt
        code = os.environ.get(self.config["access_code_env"], "")
        if not code:
            self.note = "Printer access-code environment variable is not set."
            return
        c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"fpr-read-{self.config['id']}-{os.getpid()}")
        c.username_pw_set("bblp", code)
        c.tls_set_context(printer_tls())
        c.reconnect_delay_set(1, 30)
        serial = self.config["serial"]

        def on_connect(client, userdata, flags, reason, props):
            with self.lock:
                self.connected = reason == 0
                self.note = "Waiting for a status report." if self.connected else "Printer MQTT connection refused."
            if reason == 0:
                client.subscribe(f"device/{serial}/report")

        def on_subscribe(client, userdata, mid, reasons, props):
            if any(r.is_failure for r in reasons):
                with self.lock:
                    self.note = "Printer status subscription refused."
                return
            # This is the only message sent to a printer: request a status
            # snapshot after subscribing, including after reconnection.
            client.publish(f"device/{serial}/request", json.dumps({"pushing": {"sequence_id": "1", "command": "pushall", "version": 1, "push_target": 1}}))

        def on_message(client, userdata, message):
            if len(message.payload) > 262144:
                return
            try:
                value = json.loads(message.payload)
                if isinstance(value, dict):
                    self.report(value)
            except (ValueError, TypeError, RecursionError):
                with self.lock:
                    self.note = "Malformed status report ignored."

        def on_disconnect(client, userdata, flags, reason, props):
            with self.lock:
                self.connected = False
                self.note = "Disconnected; retrying automatically. Last known values are retained."

        c.on_connect, c.on_subscribe, c.on_message, c.on_disconnect = on_connect, on_subscribe, on_message, on_disconnect
        c.connect_async(self.config["host"], 8883, keepalive=30)
        c.loop_start()
        self.client = c

    def close(self):
        self.camera.stop()
        if self.client:
            self.client.disconnect()
            self.client.loop_stop()


def printer_tls():
    # Bambu LAN devices use self-signed certificates, as in bambu-lan.
    # Kept private to this transport; not used for arbitrary Internet hosts.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def recv_exact(conn, count):
    result = bytearray()
    while len(result) < count:
        chunk = conn.recv(count - len(result))
        if not chunk:
            raise ConnectionError("camera closed")
        result.extend(chunk)
    return bytes(result)


class Camera:
    def __init__(self, printer):
        self.printer = printer
        self.condition = threading.Condition()
        self.users = 0
        self.seq = 0
        self.frame = None
        self.error = False
        self.thread = None
        self.sock = None
        self.shutdown = False
        self.generation = 0
        self.starts = 0
        self.last_frame = 0.0
        self.last_frame_wall = 0
        self.frames = collections.deque()

    def stats(self):
        with self.condition:
            now = time.monotonic()
            while self.frames and self.frames[0] < now - 30:
                self.frames.popleft()
            state = "OFF" if self.users == 0 else "UNAVAILABLE" if self.error else "CONNECTING" if not self.last_frame else "STALE" if now - self.last_frame > 10 else "LIVE"
            return {"camera_state": state, "camera_hz": round(len(self.frames) / 30, 2), "camera_last_frame": self.last_frame_wall, "camera_connections": self.starts, "camera_viewers": self.users}

    def acquire(self):
        with self.condition:
            if self.users >= 8 or self.shutdown:
                raise RuntimeError("camera capacity")
            if self.users == 0:
                self.frame = None
                self.error = False
                self.last_frame = 0.0
                self.last_frame_wall = 0
                self.frames.clear()
            self.users += 1
            if not self.thread or not self.thread.is_alive():
                self.frame = None
                self.last_frame = 0.0
                self.last_frame_wall = 0
                self.frames.clear()
                self.error = False
                self.generation += 1
                self.starts += 1
                self.thread = threading.Thread(target=self.run, args=(self.generation,), daemon=True)
                self.thread.start()
            return self.seq

    def release(self):
        with self.condition:
            self.users = max(0, self.users - 1)
            if self.users == 0:
                self.frame = None
                self.generation += 1
                self.disconnect()
            self.condition.notify_all()

    def disconnect(self):
        if self.sock:
            with contextlib.suppress(OSError):
                self.sock.shutdown(socket.SHUT_RDWR)
            self.sock.close()
            self.sock = None

    def stop(self):
        with self.condition:
            self.shutdown = True
            self.generation += 1
            self.disconnect()
            self.condition.notify_all()

    def run(self, generation):
        conn = None
        try:
            if not self.printer.demo:
                config = self.printer.config
                code = os.environ.get(config["access_code_env"], "")
                if not code or len(code.encode()) > 32:
                    raise ValueError("camera configuration")
                raw = socket.create_connection((config["host"], 6000), timeout=5)
                try:
                    conn = printer_tls().wrap_socket(raw, server_hostname=config["host"])
                except BaseException:
                    raw.close()
                    raise
                conn.settimeout(10)
                conn.sendall(struct.pack("<IIII", 0x40, 0x3000, 0, 0) + b"bblp".ljust(32, b"\0") + code.encode().ljust(32, b"\0"))
                with self.condition:
                    if generation != self.generation or not self.users:
                        return
                    self.sock = conn
            while True:
                with self.condition:
                    if self.shutdown or self.users == 0 or generation != self.generation:
                        return
                if self.printer.demo:
                    frame = (ROOT / "examples/printer-dashboard/demo-camera.jpg").read_bytes()
                    time.sleep(.5)
                else:
                    size = struct.unpack("<I", recv_exact(conn, 16)[:4])[0]
                    if not 4 <= size <= MAX_FRAME:
                        raise ValueError("invalid frame length")
                    frame = recv_exact(conn, size)
                    if not (frame.startswith(b"\xff\xd8") and frame.endswith(b"\xff\xd9")):
                        raise ValueError("invalid JPEG")
                with self.condition:
                    if generation != self.generation:
                        return
                    self.frame = frame
                    self.last_frame = time.monotonic()
                    self.last_frame_wall = int(time.time())
                    self.frames.append(self.last_frame)
                    self.seq += 1
                    self.condition.notify_all()
        except (OSError, ValueError, ConnectionError):
            with self.condition:
                if generation == self.generation:
                    self.error = True
                    self.condition.notify_all()
        finally:
            if conn:
                conn.close()
            with self.condition:
                if self.sock is conn:
                    self.sock = None
                # A new viewer may have arrived while an old socket was closing.
                if generation != self.generation and self.users and not self.shutdown:
                    self.generation += 1
                    self.frame = None
                    self.error = False
                    self.starts += 1
                    self.thread = threading.Thread(target=self.run, args=(self.generation,), daemon=True)
                    self.thread.start()

    def next(self, seq):
        with self.condition:
            self.condition.wait_for(lambda: self.seq > seq or self.error or self.shutdown, timeout=12)
            if self.error or self.shutdown or self.seq <= seq or self.frame is None:
                raise ConnectionError("camera unavailable")
            return self.seq, self.frame


class Gateway(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *args):
        pass

    def handle(self):
        with contextlib.suppress(OSError):
            super().handle()

    def response(self, status, body, content_type="text/plain; charset=utf-8", headers=()):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.close_connection = True
        self.response(405, b"Read-only dashboard\n")

    def origin(self):
        host = self.headers.get("Host", "")
        parsed = urlsplit(self.server.origin)
        if host == parsed.netloc:
            expected = self.server.origin
        elif host in (f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"):
            expected = "http://" + host
        else:
            return None
        origin = self.headers.get("Origin")
        if (origin and origin != expected) or self.headers.get("Sec-Fetch-Site") == "cross-site":
            return None
        return expected

    def cookie(self, name):
        try:
            cookies = SimpleCookie(self.headers.get("Cookie", ""))
            return cookies[name].value if name in cookies else ""
        except CookieError:
            return ""

    def set_cookie(self, name, value, seconds, origin):
        secure = "; Secure" if origin.startswith("https://") else ""
        return ("Set-Cookie", f"{name}={value}; Path=/; Max-Age={seconds}; HttpOnly; SameSite=Strict{secure}")

    def authenticated(self):
        return self.server.auth.valid(self.cookie(COOKIE), self.origin())

    def do_POST(self):
        self.close_connection = True
        origin = self.origin()
        if not origin or self.headers.get("Origin") != origin:
            return self.response(403, b"Same-origin requests only\n")
        path = self.path.split("?", 1)[0]
        if path not in ("/auth/challenge", "/auth/verify", "/auth/logout"):
            return self.response(405, b"Read-only dashboard\n")
        try:
            if self.headers.get("Transfer-Encoding") or self.headers.get("Content-Type") != "application/json":
                raise ValueError("JSON request required.")
            size = int(self.headers.get("Content-Length", "0"))
            if not 1 <= size <= 1024:
                raise ValueError("Invalid request size.")
            raw = self.rfile.read(size)
            value = json.loads(raw)
            if path == "/auth/challenge":
                if value != {}:
                    raise ValueError("Challenge request must be empty.")
                value, binding = self.server.auth.challenge(origin, self.client_address[0])
                return self.response(200, json.dumps(value).encode(), "application/json", [self.set_cookie(BINDING, binding, CHALLENGE_SECONDS, origin)])
            if path == "/auth/logout":
                if value != {}:
                    raise ValueError("Logout request must be empty.")
                self.server.auth.logout(self.cookie(COOKIE))
                return self.response(200, b'{"ok":true}', "application/json", [self.set_cookie(COOKIE, "", 0, origin), self.set_cookie(BINDING, "", 0, origin)])
            token = self.server.auth.verify(value, origin, self.cookie(BINDING))
            return self.response(200, b'{"ok":true}', "application/json", [self.set_cookie(COOKIE, token, SESSION_SECONDS, origin), self.set_cookie(BINDING, "", 0, origin)])
        except (ValueError, UnicodeError, RecursionError):
            return self.response(400, b'{"error":"Sign in failed. Check your key, or request a fresh challenge."}', "application/json")

    do_PUT = do_DELETE = do_PATCH = do_OPTIONS

    def do_GET(self):
        self.close_connection = True
        self.connection.settimeout(5)
        path = self.path.split("?", 1)[0]
        if not self.origin():
            return self.response(403, b"Same-origin requests only\n")
        if path == "/health":
            return self.response(200, b"ok\n")
        if path == "/auth/login.js":
            return self.response(200, (ROOT / "tools/printer_login.js").read_bytes(), "text/javascript; charset=utf-8")
        if not self.authenticated():
            if path == "/":
                return self.response(200, (ROOT / "tools/printer_login.html").read_bytes(), "text/html; charset=utf-8", [("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")])
            return self.response(401, b"Sign in required\n")
        if path == "/auth/session":
            return self.response(200, b'{"ok":true}', "application/json")
        if path == "/auth/session.js":
            return self.response(200, (ROOT / "tools/printer_session.js").read_bytes(), "text/javascript; charset=utf-8")
        if path == "/api/status":
            return self.response(200, json.dumps(self.server.snapshot(), allow_nan=False).encode(), "application/json")
        match = re.fullmatch(r"/camera/([a-z0-9-]{1,32})\.mjpg", path)
        if match:
            printer = self.server.printers.get(match[1])
            if not printer:
                return self.response(404, b"Unknown printer\n")
            if not printer.snapshot()["camera_available"]:
                return self.response(404, b"No supported camera\n")
            camera = printer.camera
            try:
                seq = camera.acquire()
            except RuntimeError:
                return self.response(503, b"Camera busy\n")
            try:
                try:
                    seq, frame = camera.next(seq)
                except ConnectionError:
                    return self.response(503, b"Camera unavailable\n")
                self.send_response(200)
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Connection", "close")
                self.end_headers()
                while self.authenticated() and not self.server.stopping.is_set():
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(frame)).encode() + b"\r\n\r\n" + frame + b"\r\n")
                    self.wfile.flush()
                    seq, frame = camera.next(seq)
            except (OSError, ConnectionError):
                pass
            finally:
                camera.release()
            return
        if path not in ("/", "/ws"):
            return self.response(404, b"Not found\n")
        if path == "/ws":
            return self.websocket()
        upstream = http.client.HTTPConnection("127.0.0.1", self.server.fpr_port, timeout=5)
        try:
            upstream.request("GET", "/")
            r = upstream.getresponse()
            body = r.read(2 * 1024 * 1024).replace(b"</head>", b'<script src="/auth/session.js" defer></script></head>')
            self.response(r.status, body, "text/html; charset=utf-8")
        except OSError:
            self.response(502, b"FP-RISC view is unavailable\n")
        finally:
            upstream.close()

    def websocket(self):
        if self.headers.get("Upgrade", "").lower() != "websocket":
            return self.response(400, b"WebSocket upgrade required\n")
        try:
            with socket.create_connection(("127.0.0.1", self.server.fpr_port), timeout=5) as upstream:
                headers = [f"GET {self.path} HTTP/1.1", "Host: 127.0.0.1", "Upgrade: websocket", "Connection: Upgrade"]
                for name in ("Sec-WebSocket-Key", "Sec-WebSocket-Version"):
                    headers.append(f"{name}: {self.headers.get(name, '')}")
                upstream.sendall(("\r\n".join(headers) + "\r\n\r\n").encode())
                # Forward the complete handshake and frames unchanged. Browser
                # socket is unbuffered here (BaseHTTPRequestHandler rbufsize=0).
                self.connection.settimeout(5)
                upstream.settimeout(5)
                while not self.server.stopping.is_set() and self.authenticated():
                    ready, _, _ = select.select([upstream, self.connection], [], [], 1)
                    for source in ready:
                        data = source.recv(65536)
                        if not data:
                            return
                        target = self.connection if source is upstream else upstream
                        target.sendall(data)
        except OSError:
            return

    rbufsize = 0


def configs(path, demo):
    if demo:
        return [{"id": "a1", "name": "Bambu A1", "model": "A1 · AMS Lite", "location": "Work bench"},
                {"id": "p1s", "name": "Bambu P1S", "model": "P1S", "location": "Enclosure shelf"}]
    value = json.loads(Path(path).read_text())
    if not isinstance(value, list) or not 1 <= len(value) <= 24:
        raise ValueError("configuration must be a list of 1..24 printers")
    ids = set()
    for p in value:
        if not isinstance(p, dict) or not all(isinstance(p.get(k), str) and p[k] for k in ("id", "name", "model", "host", "serial", "access_code_env")):
            raise ValueError("each printer needs id, name, model, host, serial and access_code_env")
        if not re.fullmatch(r"[a-z0-9-]{1,32}", p["id"]) or p["id"] in ids:
            raise ValueError("printer ids must be unique lower-case slugs")
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", p["access_code_env"]):
            raise ValueError("access_code_env must name an environment variable")
        if p.get("camera", "bambu-jpeg") not in ("bambu-jpeg", "none"):
            raise ValueError("supported cameras: bambu-jpeg (A1/P1 series), none")
        if not isinstance(p.get("location", "Workshop"), str):
            raise ValueError("location must be text")
        if any(len(p[k]) > 160 for k in ("name", "model", "host", "serial")):
            raise ValueError("configuration text is too long")
        ids.add(p["id"])
    return value


ENV_PRINTERS = (("a1", "A1", "A1 + AMS Lite"), ("p1s", "P1S", "P1S"))


def printer_env(path):
    """Parse only printer fields, without executing shell code or echoing values."""
    allowed = {f"BAMBU_{tag}_{key}" for _, tag, _ in ENV_PRINTERS for key in ("HOST", "ACCESS_CODE", "SERIAL")}
    values = {}
    for line in Path(path).read_text().splitlines():
        match = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$", line)
        if not match or match[1] not in allowed:
            continue
        try:
            parts = shlex.split(match[2], comments=True, posix=True)
        except ValueError:
            raise ValueError("invalid quoted printer configuration") from None
        if len(parts) != 1 or not parts[0]:
            raise ValueError("empty or malformed printer configuration")
        values[match[1]] = parts[0]
    return values


def serial_from_advertisement(data):
    headers = {}
    for line in data.decode("utf-8", errors="replace").splitlines():
        key, sep, value = line.partition(":")
        if sep:
            headers[key.strip().lower()] = value.strip()
    if "devmodel.bambu.com" not in headers:
        return None
    serial = headers.get("usn", "").removeprefix("uuid:").split("::", 1)[0]
    return serial if re.fullmatch(r"[A-Za-z0-9]{6,32}", serial) else None


def discover_serials(hosts, seconds=20):
    """Listen only to advertisements from configured IPs. No credentials sent."""
    found = {}
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        listener.bind(("", 2021))
        deadline = time.monotonic() + seconds
        while hosts - found.keys() and time.monotonic() < deadline:
            listener.settimeout(min(1, max(.01, deadline - time.monotonic())))
            try:
                data, (ip, _) = listener.recvfrom(8192)
            except socket.timeout:
                continue
            if ip in hosts:
                serial = serial_from_advertisement(data)
                if serial:
                    found[ip] = serial
    return found


def env_configs(path, seconds=20, selected=("a1", "p1s")):
    values = printer_env(path)
    result = []
    if not selected or len(set(selected)) != len(selected) or any(id not in ("a1", "p1s") for id in selected):
        raise ValueError("printers must select a1, p1s, or both")
    for id, tag, model in ENV_PRINTERS:
        if id not in selected:
            continue
        prefix = f"BAMBU_{tag}_"
        if prefix + "HOST" not in values or prefix + "ACCESS_CODE" not in values:
            raise ValueError(f"missing {tag} printer configuration")
        host = values[prefix + "HOST"]
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            raise ValueError("printer HOST must be an IP address") from None
        if address.version != 4 or not address.is_private or address.is_loopback:
            raise ValueError("printer HOST must be a private LAN IPv4 address")
        code = values[prefix + "ACCESS_CODE"]
        if len(code.encode()) > 32:
            raise ValueError("printer access code exceeds the camera protocol limit")
        os.environ[prefix + "ACCESS_CODE"] = code
        result.append({"id": id, "name": f"Bambu {tag}", "model": model, "location": "Local workshop",
                       "host": host, "serial": values.get(prefix + "SERIAL", ""), "access_code_env": prefix + "ACCESS_CODE", "camera": "bambu-jpeg"})
    missing = {p["host"] for p in result if not p["serial"]}
    heard = discover_serials(missing, seconds) if missing else {}
    for p in result:
        p["serial"] = p["serial"] or heard.get(p["host"], "")
        if not p["serial"]:
            raise ValueError(f"{p['name']} was not heard on LAN discovery; supply BAMBU_{p['id'].upper()}_SERIAL or retry")
        if not re.fullmatch(r"[A-Za-z0-9]{6,32}", p["serial"]):
            raise ValueError("invalid printer serial identifier")
    return result


def atomic_snapshot(path, value):
    text = json.dumps(value, allow_nan=False)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as f:
        temp = Path(f.name)
        f.write(text)
    try:
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def view_environment(printers, environment):
    private = {p.config.get("access_code_env") for p in printers.values()}
    return {k: v for k, v in environment.items() if k not in private and not k.startswith("BAMBU_")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--demo", action="store_true")
    source.add_argument("--config", help="JSON list of printers (no access-code values)")
    source.add_argument("--env-file", help="Existing A1/P1S .env file; codes stay in this process only")
    parser.add_argument("--discovery-seconds", type=int, default=20)
    parser.add_argument("--printers", default="a1,p1s", help="With --env-file: a1, p1s, or a1,p1s")
    parser.add_argument("--address", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6730)
    parser.add_argument("--poll-ms", type=int, default=1000)
    parser.add_argument("--binary", default=str(ROOT / "build/printers"))
    parser.add_argument("--auth", default=str(ROOT / "examples/printer-dashboard/auth.json"), help="Public Ed25519 key allowlist (required in all modes)")
    parser.add_argument("--origin", help="Public origin, e.g. https://3dprint.cswine.cloud; defaults to local listener")
    args = parser.parse_args()
    try:
        auth = Auth(load_keys(args.auth))
    except (ValueError, OSError, TypeError):
        parser.error("cannot load public auth registry; refusing to start without authentication")
    if args.origin:
        origin = urlsplit(args.origin)
        if (origin.scheme not in ("http", "https") or not origin.netloc or origin.path or origin.query or origin.fragment
                or origin.username or origin.password or (origin.scheme == "http" and origin.hostname not in ("localhost", "127.0.0.1"))):
            parser.error("origin must be HTTPS (or HTTP localhost), without a path")
    if not 250 <= args.poll_ms <= 10000 or not 0 <= args.port <= 65535:
        parser.error("poll-ms must be 250..10000, port 0..65535")
    if not 1 <= args.discovery_seconds <= 60:
        parser.error("discovery-seconds must be 1..60")
    if not Path(args.binary).is_file():
        parser.error("build the view first: ./fpr build examples/printers.fpr -o build/printers")
    try:
        loaded = env_configs(args.env_file, args.discovery_seconds, tuple(args.printers.split(","))) if args.env_file else configs(args.config, args.demo)
        printers = {c["id"]: Printer(c, args.demo) for c in loaded}
    except (OSError, ValueError, TypeError) as exc:
        # Only our fixed validation messages are safe; never echo source lines.
        if args.env_file and type(exc) is ValueError:
            parser.error(str(exc))
        parser.error("cannot load printer configuration; see examples/printer-dashboard/README.md")
    if not args.demo:
        try:
            import paho.mqtt.client
        except ImportError:
            parser.error("live mode needs paho-mqtt: install tools/printer-dashboard-requirements.txt")
    stopping = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopping.set())
    with tempfile.TemporaryDirectory(prefix="fpr-printers-") as tmp:
        snapshot_path = Path(tmp) / "status.json"
        def snapshot():
            return {"schema": 1, "generated_at": int(time.time()), "demo": args.demo, "auth": auth.keys, "printers": [p.snapshot() for p in printers.values()]}
        def writer():
            step = 0
            while not stopping.is_set():
                if args.demo:
                    for i, p in enumerate(printers.values()):
                        p.report({"print": {"gcode_state": "RUNNING" if i == 0 else "IDLE", "mc_percent": min(99, 42 + step // 20) if i == 0 else 0,
                                            "subtask_name": "Tesseract · corner fit test" if i == 0 else "Ready for the next build",
                                            "nozzle_temper": 218 + (step % 3) if i == 0 else 27, "nozzle_target_temper": 220 if i == 0 else 0,
                                            "bed_temper": 60 if i == 0 else 26, "bed_target_temper": 60 if i == 0 else 0,
                                            "mc_remaining_time": max(1, 38 - step // 60) if i == 0 else 0,
                                            "layer_num": 84 if i == 0 else 0, "total_layer_num": 200 if i == 0 else 0,
                                            "print_error": 0, "wifi_signal": "-48 dBm" if i == 0 else "-55 dBm", "vt_tray": {"tray_type": "PLA"}}})
                    step += 1
                atomic_snapshot(snapshot_path, snapshot())
                stopping.wait(1)
        proc = None
        writer_thread = None
        try:
            for p in printers.values():
                p.start()
            writer_thread = threading.Thread(target=writer, daemon=True)
            writer_thread.start()
            # The private UI listener is chosen by FP-RISC itself (port 0).
            proc = subprocess.Popen([args.binary, "--port=0", "--address=127.0.0.1", f"--poll-ms={args.poll_ms}", f"--status={snapshot_path}", f"--store={tmp}/view.kvlog"], stdout=subprocess.PIPE, stderr=None, text=True, env=view_environment(printers, os.environ))
            ready, _, _ = select.select([proc.stdout], [], [], 30)
            line = proc.stdout.readline() if ready else ""
            if not re.fullmatch(r"ready \d+\n", line):
                raise RuntimeError("FP-RISC view did not start (check listener permissions and build output)")
            with Gateway((args.address, args.port), Handler) as server:
                server.auth = auth
                server.origin = args.origin or f"http://{args.address}:{server.server_port}"
                server.fpr_port = int(line.split()[1])
                server.snapshot, server.printers, server.stopping = snapshot, printers, stopping
                server.timeout = .5
                print(f"Print room: http://{args.address}:{server.server_port}/ ({'DEMO' if args.demo else 'LAN / read only'})", flush=True)
                while not stopping.is_set() and proc.poll() is None:
                    server.handle_request()
                if proc.poll() is not None and not stopping.is_set():
                    raise RuntimeError("FP-RISC view exited unexpectedly")
        finally:
            stopping.set()
            if writer_thread:
                writer_thread.join(timeout=3)
            for p in printers.values():
                p.close()
            if proc:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                proc.stdout.close()


if __name__ == "__main__":
    main()
