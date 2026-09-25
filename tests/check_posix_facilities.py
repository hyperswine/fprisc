#!/usr/bin/env python3
"""Verify optional host facilities remain independently linkable.
Run with python3 tests/check_posix_facilities.py (native cc and nm required).
Behavior is covered by check_base.py and check_std.py; this checks the object
boundary so missing process APIs cannot break file/socket-only hosts.
"""
import os
import platform
import shlex
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FACILITIES = {
    "os": "readFile listDir stat mkdir remove rename cwd wallClock tzOffset",
    "os_io": "open ready poll read write seek close",
    "os_proc": "run exec",
    "os_net": "connect listen accept localPort",
    "os_watch": "watchOpen watchArm watchTake watchClose",
    "os_term": "ttyRaw ttySize",
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
    flags = ["-O2", "-w", "-DFPR_POSIX", "-DFPR_NHARTS=2", "-I" + str(ROOT / "runtime")]
    if platform.machine().lower() in ("arm64", "aarch64"):
        flags += ["-ffixed-x27", "-ffixed-x28", "-DFPR_HART_X28"]
    exported = set()
    for name, primitives in FACILITIES.items():
        obj = Path(tmp) / (name + ".o")
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + flags +
                       ["-c", str(ROOT / "machine/posix" / (name + ".c")), "-o", str(obj)], check=True)
        defined, undefined = symbols(obj)
        expected = {"fpr_g_Os_x2e" + p for p in primitives.split()}
        actual = {s for s in defined if s.startswith("fpr_g_Os_")}
        assert actual == expected, (name, actual ^ expected)
        assert not (exported & actual), (name, "duplicate primitive")
        exported |= actual
        if name in ("os", "os_io", "os_net"):
            forbidden = {"fork", "execvp", "waitpid", "kill", "pipe", "pthread_create", "tcsetattr"}
            assert not (undefined & forbidden), (name, undefined & forbidden)
        print(name + ": primitive exports and dependency boundary PASS")
    assert len(exported) == 28
