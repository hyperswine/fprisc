#!/usr/bin/env python3
"""The ESP32-P4 examples, on an attached board, through `fpr run --system=esp-idf`.

    python3 tests/check_esp_board.py [--quick] [--port P]

Opt-in hardware regression: it flashes the board (each example replaces the
last) and needs ESP-IDF 5.3 (machine/esp-idf/env.sh finds it).  With no board
attached it says so and exits 0, so it can sit beside the other suites.
--quick leaves out the radio examples (about three minutes of the run).
Each check is the program's own exit status and what it printed, exactly as
a posix program is checked -- the board is the host.
"""
import glob
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
args = sys.argv[1:]
quick = "--quick" in args
port = args[args.index("--port") + 1] if "--port" in args else os.environ.get("FPR_ESP_PORT")
if not port:
    found = sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/cu.usbserial*") + glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*"))
    if len(found) != 1:
        print(f"ESP board: none attached ({len(found)} serial devices); skipped")
        sys.exit(0)
    port = found[0]
idf = os.environ.get("IDF_PATH") or os.path.expanduser("~/.espressif/esp-idf/v5.3.2")
if not os.path.isdir(idf):
    print("ESP board: ESP-IDF 5.3 not found; skipped")
    sys.exit(0)
subprocess.run(["make", "fpr"], check=True, capture_output=True)

def run(example, expect_status, must, stdin="", out="suite", timeout=None, env=None):
    e = {**os.environ, **(env or {})}
    if timeout:
        e["FPR_ESP_TIMEOUT"] = str(timeout)
    p = subprocess.run(["./fpr", "run", f"machine/esp-idf/examples/{example}.fpr", "--system=esp-idf",
                        "--port", port, "-o", f"build/esp-idf/{out}"],
                       input=stdin, capture_output=True, text=True, env=e, timeout=1200)
    missing = [m for m in must if m not in p.stdout]
    if p.returncode != expect_status or missing:
        raise AssertionError(f"{example}: status {p.returncode} (expected {expect_status}); missing {missing}\n"
                             f"--- stdout\n{p.stdout}\n--- stderr\n{p.stderr[-3000:]}")
    return p

run("cores", 0, ["worker 0: core 0 -> 0", "worker 1: core 1 -> 1", "parallel speedup", "cross-core round trips"])
print("cores: actors pinned to both cores, parallel speedup, cross-core round trips: PASS")
run("gpio", 0, ["GPIOs; configuration and level now", "sampler on core 0", "sampler on core 1"])
print("gpio: every pin read from its registers, sampled from both cores: PASS")
run("files", 0, ["tree: create, write, append, lines, info, rename, exists passed",
                 "patched at byte 1000", "both cores: 200 appends at once", "errors: missing file -> No such file or directory"])
print("files: FAT at /data through std/file and std/dir, appends from both cores: PASS")
p = run("console", 3, ['you said "hello" (5 characters; line 1)', 'you said "wörld" (6 characters; line 2)', "read 2 line(s); exiting"],
        stdin="hello\nwörld\nquit\n")
assert "MUST NOT PRINT" not in p.stdout, p.stdout
print("console: std/program over the serial console, lines in, Program.exit 3 is the status: PASS")
run("load", 0, ["4 at once: 4 connected", "8 at once: 8 connected", "12 at once: 12 connected"])
print("load: 12 loopback connections held at once (24 sockets), echo on each: PASS")
run("posix-poller", 0, ["80 stops, duplicate waiter cancellation passed", "10 TCP exchanges through Stream.readOn and Poller.await passed"],
    out="suite-io-smoke", env={"FPR_ESP_IO_SMOKE": "1"})
print("posix-poller: shared sockets, streams, poller and watcher lifecycle on loopback: PASS")
p = subprocess.run(["./fpr", "run", "machine/esp-idf/examples/stack-guard.fpr", "--system=esp-idf", "--port", port,
                    "-o", "build/esp-idf/suite-guard"], capture_output=True, text=True, timeout=1200,
                   env={**os.environ, "FPR_ESP_IO_SMOKE": "1", "FPR_ESP_STACK_GUARD": "1", "FPR_ESP_TIMEOUT": "60"})
assert p.returncode == 2 and "32 KiB of C frames on an actor stack: fine" in p.stdout \
    and "NOT CAUGHT" not in p.stdout and "that is the stack guard" in p.stderr, (p.returncode, p.stdout, p.stderr[-2000:])
print("stack-guard: C code past an actor's stack bottom is a named fault (watchpoint), not a quiet write: PASS")
if not quick:
    run("wifi", 0, ["radio: station ", "network(s) in", "while Wi-Fi jobs ran", "access point fpr-p4-test on channel 6, wpa2, at 192.168.4.1"])
    print("wifi: typed info, scan while another core runs, WPA2 access point: PASS")
    run("ble", 0, ["advertising as fpr-p4-ble from", "an over-long name: a BLE advertising name is 1 to 26 bytes", "scan: "])
    print("ble: advertise, over-long name refused, three scans: PASS")
    run("ap-server", 124, ["password rule: short password, 33-byte SSID and non-hex key refused",
                           "self-test: the page answered on 192.168.4.1:80", "READY: join fpr-p4-test"], timeout=45)
    print("ap-server: password rule, HTTP through std/httpcore on the access point, self-test: PASS")
