#!/usr/bin/env python3
"""Verify optional host facilities remain independently linkable.
Run with python3 tests/check_posix_facilities.py (native cc and nm required).
Behavior is covered by check_base.py and check_std.py; this checks the object
boundary so missing process APIs cannot break file/socket-only hosts.
"""
import os
import re
import platform
import shlex
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FACILITIES = {
    "os_fs": "readFile listDir stat mkdir remove rename cwd",
    "os_clock": "wallClock tzOffset",
    "os_io": "open ready readyFor poll read write seek close",
    "os_proc": "run exec exePath",
    "os_net": "connect listen accept localPort prepareSocket",
    "os_watch": "watchOpen watchArm watchTake watchClose watchArmEvents watchTakeEvents",
    "os_term": "ttyRaw ttySize",
    "os_job": "new result",
    "os_owned": "",
    "os_connection": "adopt begin fd status read write close",
    "os_resolver": "pool begin poll abandon close",
    "os_tls_unavailable": "start fd step pending close",
}

def symbols(path):
    output = subprocess.check_output([os.environ.get("NM", "nm"), "-g", str(path)], text=True)
    defined, undefined = set(), set()
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        kind, name = parts[-2:]
        if platform.system() == "Darwin" and name.startswith("_"):
            name = name[1:]
        (undefined if kind == "U" else defined).add(name)
    return defined, undefined

with tempfile.TemporaryDirectory(prefix="fpr-posix-facilities-") as tmp:
    flags = ["-O2", "-w", "-DFPR_POSIX", "-DFPR_NHARTS=2", "-I" + str(ROOT / "runtime"), "-I" + str(ROOT / "machine/posix")]
    if platform.machine().lower() in ("arm64", "aarch64"):
        flags += ["-ffixed-x27", "-ffixed-x28", "-DFPR_HART_X28"]
    exported = set()
    for name, primitives in FACILITIES.items():
        obj = Path(tmp) / (name + ".o")
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + flags +
                       ["-c", str(next(d / (name + ".c") for d in (ROOT / "machine/posix", ROOT / "machine/unix") if (d / (name + ".c")).exists())), "-o", str(obj)], check=True)
        defined, undefined = symbols(obj)
        namespace = {"os_job": "JobHost", "os_connection": "ConnHost", "os_resolver": "DnsHost", "os_tls_unavailable": "TlsHost"}.get(name, "Os")
        expected = {"fpr_g_" + namespace + "_x2e" + p for p in primitives.split()}
        primitive_symbols = {s for s in defined if s.startswith("fpr_g_")}
        # The native ABI also exports direct-call entry points, e.g. _call2.
        # Check facility membership on their base names, and reject orphan calls.
        actual = {s for s in primitive_symbols if not re.search(r"_call\d+$", s)}
        assert all(re.sub(r"_call\d+$", "", s) in actual for s in primitive_symbols)
        assert actual == expected, (name, actual ^ expected)
        assert not (exported & actual), (name, "duplicate primitive")
        exported |= actual
        if name in ("os_fs", "os_clock", "os_io", "os_net", "os_connection", "os_owned", "os_tls_unavailable"):
            forbidden = {"fork", "execvp", "waitpid", "kill", "pipe", "pthread_create", "tcsetattr"}
            assert not (undefined & forbidden), (name, undefined & forbidden)
        print(name + ": primitive exports and dependency boundary PASS")
    assert len(exported) == 52
