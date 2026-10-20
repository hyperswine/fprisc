#!/usr/bin/env python3
"""Execute the emitted x64 self loop against a C value/fuel/stack oracle."""
import os
import platform
import re
import subprocess
import tempfile
from pathlib import Path
from check_self_loops import ROOT, fixture, run

def main():
    mac = platform.system() == "Darwin"
    native = platform.machine() in ("x86_64", "AMD64")
    rosetta = mac and not native and subprocess.run(
        ["arch", "-x86_64", "/usr/bin/true"], capture_output=True).returncode == 0
    if not (native or rosetta):
        print("Self-loop x64 execution SKIP: needs x64 or Rosetta")
        return
    with tempfile.TemporaryDirectory(prefix="fpr-self-x64-") as td:
        tmp = Path(td)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / "cache"), FPR_NO_INLINE="1",
                   FPR_NO_SCALAR_WORKERS="1", FPR_NO_FIELD_WORKERS="1")
        env.pop("FPR_FOREIGN", None)
        source = tmp / "probe.fpr"
        source.write_text(fixture()[0])
        harness = ROOT / "tests/base/selfloops_oracle.c"
        for enabled in ("0", "1"):
            assembly = tmp / "probe.s"
            run([ROOT / "fpr", "compile", "--target=x64", source, assembly],
                dict(env, FPR_SELF_LOOPS=enabled))
            match = re.search(r"(?ms)^\s*\.globl fpr_fn_rotate2\n.*?(?=^# wcet:)",
                              assembly.read_text())
            assert match
            selected = ".text\n" + match[0]
            assert bool(re.search(r"^\.Lself\d+:", selected, re.M)) == (enabled == "1")
            selected = selected.replace("%fs:fpr_posix_hart@tpoff", "probe_hart(%rip)")
            if mac:
                selected = re.sub(r"\bfpr_[A-Za-z0-9_]+\b", lambda m: "_" + m[0], selected)
                selected = selected.replace("probe_hart(%rip)", "_probe_hart(%rip)")
            assembly.write_text(selected)
            exe = tmp / "oracle"
            run(["clang", *(["-arch", "x86_64"] if mac else []), "-O2",
                 assembly, harness, "-o", exe], env)
            print(f"FPR_SELF_LOOPS={enabled}: " +
                  run([*(["arch", "-x86_64"] if rosetta else []), exe], env).strip(), flush=True)

if __name__ == "__main__":
    main()
