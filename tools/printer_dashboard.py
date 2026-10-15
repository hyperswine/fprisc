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
import secrets
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
NATIVE_FIELDS = {"connection", "state", "job", "progress", "remaining", "layers", "nozzle", "bed", "nozzle_target", "bed_target", "wifi", "reports", "report_hz", "last_report", "last_report_iso", "error", "filament", "note"}


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
    def __init__(self, config, demo=False, native_binary=None, native_camera_binary=None):
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
        self.native_binary = native_binary
        self.native_state = None
        self.native_received = 0.0
        self.native_environment = None
        self.native = None
        self.camera = NativeCamera(self, native_camera_binary) if native_camera_binary else Camera(self)

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
            if self.native_state is not None:
                result = dict(self.native_state)
                if not self.connected:
                    result.update(connection="OFFLINE", note=self.note)
                elif now - self.native_received >= 2:
                    result["connection"] = "STALE"
                result.update(id=self.config["id"], name=self.config["name"], model=self.config["model"],
                              location=self.config.get("location", "Workshop"),
                              camera_available=self.config.get("camera", "bambu-jpeg") == "bambu-jpeg", **self.camera.stats())
                return result
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
        if self.native_binary:
            self.native = NativeTelemetry(self, self.native_binary)
            self.native.start()
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
        if self.native:
            self.native.close()
        if self.client:
            self.client.disconnect()
            self.client.loop_stop()


class NativeTelemetry:
    """Supervision only: MQTT, TLS and report projection run in FP-RISC.

    The child receives one code through its environment; stdout is a bounded
    public projection. It never receives the gateway's browser auth sessions.
    """
    def __init__(self, printer, binary):
        self.printer, self.binary = printer, binary
        self.process = None
        self.thread = None

    def start(self):
        p = self.printer
        c = p.config
        code = os.environ.get(c["access_code_env"], "")
        if not code:
            p.note = "Printer access-code environment variable is not set."
            return
        environment = dict(p.native_environment if p.native_environment is not None else view_environment({c["id"]: p}, os.environ))
        environment["FPR_PRINTER_CODE"] = code
        try:
            self.process = subprocess.Popen(
                [self.binary, c["host"], str(c.get("mqtt_port", 8883)), c["serial"], c["tls_peer"], c["tls_ca"], "FPR_PRINTER_CODE"],
                env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError:
            p.note = "Cannot start native printer telemetry."
            return
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        p = self.printer
        try:
            while True:
                line = self.process.stdout.readline(32769)
                if not line:
                    break
                if len(line) > 32768 or not line.endswith(b"\n"):
                    break
                value = json.loads(line)
                if not isinstance(value, dict) or set(value) != NATIVE_FIELDS:
                    break
                if any(isinstance(v, (dict, list)) or (isinstance(v, str) and len(v) > 4096)
                       or (isinstance(v, float) and not math.isfinite(v)) for v in value.values()):
                    break
                if value["connection"] not in ("ONLINE", "STALE", "OFFLINE") or not isinstance(value["last_report"], int):
                    break
                with p.lock:
                    p.native_state = value
                    p.native_received = time.monotonic()
                    p.connected = value["connection"] != "OFFLINE"
                    p.note = value["note"]
        except (ValueError, OSError, TypeError):
            pass
        finally:
            with p.lock:
                p.connected = False
                p.note = "Native telemetry stopped. Last known values are retained."
            if self.process.poll() is None:
                self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.process.stdout.close()

    def close(self):
        if self.process:
            if self.process.poll() is None:
                self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.thread:
            self.thread.join(timeout=5)


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


class NativeCamera:
    """Supervise a private native HTTP service; relay its body without framing.

    FP-RISC owns camera TLS, login, JPEG records, viewer sharing and MJPEG.
    The public gateway still owns browser authentication and revocation.
    """
    def __init__(self, printer, binary):
        self.printer, self.binary = printer, binary
        self.lock = threading.RLock()
        self.process = None
        self.port = None
        self.gate = None
        self.closed = False
        self.cached = None
        self.cache_time = 0

    def stop(self):
        with self.lock:
            self.closed = True
            self.retire()

    def retire(self):
        if self.process:
            if self.process.poll() is None:
                self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.process.stdout.close()
        self.process, self.port, self.gate = None, None, None
        self.cached = None

    def ensure(self):
        with self.lock:
            if self.closed:
                raise RuntimeError('camera stopped')
            if self.process and self.process.poll() is None:
                return self.port, self.gate
            self.retire()
            p, c = self.printer, self.printer.config
            code = os.environ.get(c['access_code_env'], '')
            if not code:
                raise RuntimeError('camera configuration')
            environment = dict(p.native_environment if p.native_environment is not None else view_environment({c['id']: p}, os.environ))
            environment['FPR_PRINTER_CODE'] = code
            self.gate = secrets.token_urlsafe(32)
            environment['FPR_CAMERA_GATE'] = self.gate
            try:
                self.process = subprocess.Popen(
                    [self.binary, c['host'], str(c.get('camera_port', 6000)), c.get('camera_tls_peer', c['tls_peer']), c.get('camera_tls_ca', c['tls_ca'])],
                    env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                if not select.select([self.process.stdout], [], [], 5)[0]:
                    raise RuntimeError('camera startup')
                line = self.process.stdout.readline(128)
                match = re.fullmatch(rb'camera-ready ([0-9]{1,5})\n', line)
                if not match or not 1 <= int(match[1]) <= 65535:
                    raise RuntimeError('camera startup')
                self.port = int(match[1])
                return self.port, self.gate
            except (OSError, ValueError, RuntimeError):
                self.retire()
                raise RuntimeError('native camera unavailable') from None

    def stats(self):
        with self.lock:
            empty = {'camera_state': 'OFF', 'camera_hz': 0, 'camera_last_frame': 0, 'camera_connections': 0, 'camera_viewers': 0}
            if not self.process:
                return empty
            if self.process.poll() is not None:
                return {**empty, 'camera_state': 'UNAVAILABLE'}
            if self.cached and time.monotonic() - self.cache_time < .5:
                return dict(self.cached)
            connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=1)
            try:
                connection.request('GET', '/stats', headers={'X-Fpr-Camera': self.gate})
                response = connection.getresponse()
                value = json.loads(response.read(2049))
                if response.status != 200 or not isinstance(value, dict) or set(value) != set(empty):
                    raise ValueError('camera metadata')
                if any(isinstance(v, (dict, list)) or (isinstance(v, float) and not math.isfinite(v)) for v in value.values()):
                    raise ValueError('camera metadata')
                self.cached, self.cache_time = value, time.monotonic()
                return dict(value)
            except (OSError, ValueError, http.client.HTTPException):
                return {**empty, 'camera_state': 'UNAVAILABLE'}
            finally:
                connection.close()

    def relay(self, handler):
        upstream = None
        started = False
        try:
            port, gate = self.ensure()
            upstream = socket.create_connection(('127.0.0.1', port), timeout=5)
            upstream.sendall(f'GET /stream HTTP/1.1\r\nHost: localhost\r\nX-Fpr-Camera: {gate}\r\nConnection: close\r\n\r\n'.encode())
            # This is an ordinary bounded HTTP header. Camera record/JPEG and
            # multipart boundaries are never parsed or rebuilt in Python.
            deadline = time.monotonic() + 13
            data = bytearray()
            while b'\r\n\r\n' not in data:
                left = deadline - time.monotonic()
                if left <= 0 or len(data) >= 8192 or not handler.authenticated() or handler.server.stopping.is_set():
                    raise RuntimeError('camera unavailable')
                upstream.settimeout(min(left, .25))
                try:
                    part = upstream.recv(4096)
                except socket.timeout:
                    continue
                if not part:
                    raise RuntimeError('camera unavailable')
                data.extend(part)
            head, body = bytes(data).split(b'\r\n\r\n', 1)
            if not head.startswith(b'HTTP/1.1 200 '):
                raise RuntimeError('camera unavailable')
            if not handler.authenticated():
                return handler.response(401, b'Sign in required\n')
            handler.send_response(200)
            handler.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
            handler.send_header('Cache-Control', 'no-store')
            handler.send_header('Connection', 'close')
            handler.end_headers()
            started = True
            upstream.settimeout(1)
            while handler.authenticated() and not handler.server.stopping.is_set():
                if body:
                    handler.wfile.write(body)
                    handler.wfile.flush()
                    body = b''
                ready, _, _ = select.select([upstream, handler.connection], [], [], .25)
                if handler.connection in ready:
                    return
                if upstream in ready:
                    body = upstream.recv(65536)
                    if not body:
                        return
        except (OSError, RuntimeError):
            if not started:
                with contextlib.suppress(OSError):
                    handler.response(503, b'Camera unavailable\n')
        finally:
            if upstream:
                upstream.close()


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
            if isinstance(camera, NativeCamera):
                return camera.relay(self)
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


def credential_environment(path, printers):
    """Select configured code bindings from the existing non-executable file.

    Hosts/serials/trust remain in --config; no file values are logged or passed
    in process arguments. This parser accepts only the known A1/P1S fields.
    """
    values = printer_env(path)
    names = {p['access_code_env'] for p in printers}
    allowed = {f'BAMBU_{tag}_ACCESS_CODE' for _, tag, _ in ENV_PRINTERS}
    if not names or not names.issubset(allowed) or any(not values.get(name) for name in names):
        raise ValueError('configured printer code is missing from the credential file')
    return {name: values[name] for name in names}


def view_environment(printers, environment):
    private = {p.config.get("access_code_env") for p in printers.values()}
    return {k: v for k, v in environment.items() if k not in private and k not in ("FPR_PRINTER_CODE", "FPR_CAMERA_GATE") and not k.startswith("BAMBU_")}


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
    parser.add_argument("--native-telemetry", help="Native collector executable; live --config entries require tls_ca and tls_peer")
    parser.add_argument("--native-camera", help="Native shared-camera executable; live --config entries require verified TLS trust")
    parser.add_argument("--credentials-env-file", help="With --config: load only configured A1/P1S code bindings from the existing environment file")
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
        if args.credentials_env_file:
            if not args.config:
                raise ValueError('credentials-env-file requires --config')
            os.environ.update(credential_environment(args.credentials_env_file, loaded))
        if args.native_telemetry or args.native_camera:
            if args.demo or args.env_file or any(path and not Path(path).is_file() for path in (args.native_telemetry, args.native_camera)):
                raise ValueError("native services require --config and existing executables")
            for c in loaded:
                if not all(isinstance(c.get(k), str) and c[k] for k in ("tls_ca", "tls_peer")) or not Path(c["tls_ca"]).is_file():
                    raise ValueError("native telemetry requires a CA file and verified peer for each printer")
                if type(c.get("mqtt_port", 8883)) is not int or not 1 <= c.get("mqtt_port", 8883) <= 65535:
                    raise ValueError("invalid native MQTT port")
                if args.native_camera:
                    if type(c.get("camera_port", 6000)) is not int or not 1 <= c.get("camera_port", 6000) <= 65535:
                        raise ValueError("invalid native camera port")
                    if not all(isinstance(c.get('camera_' + k, c[k]), str) and c.get('camera_' + k, c[k]) for k in ('tls_peer', 'tls_ca')) or not Path(c.get('camera_tls_ca', c['tls_ca'])).is_file():
                        raise ValueError("native camera requires a CA file and verified peer")
        printers = {c["id"]: Printer(c, args.demo, args.native_telemetry, args.native_camera) for c in loaded}
        public_environment = view_environment(printers, os.environ)
        for printer in printers.values():
            printer.native_environment = public_environment
    except (OSError, ValueError, TypeError) as exc:
        # Only our fixed validation messages are safe; never echo source lines.
        if args.env_file and type(exc) is ValueError:
            parser.error(str(exc))
        parser.error("cannot load printer configuration; see examples/printer-dashboard/README.md")
    if not args.demo and not args.native_telemetry:
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
