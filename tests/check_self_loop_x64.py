#!/usr/bin/env python3
"""Execute the emitted x64 self loop against a C value/fuel/stack oracle."""
import os
import re
import tempfile
from pathlib import Path
from check_self_loops import ROOT, fixture, run
from x64_probe import adapt, host, link

def main():
    target = host()
    if target is None:
        print("Self-loop x64 execution SKIP: needs x64 or Rosetta")
        return
    mac, runner, label = target
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
            assembly.write_text(adapt(selected, mac))
            exe = tmp / "oracle"
            link([assembly, harness], exe, mac, env)
            print(f"{label} FPR_SELF_LOOPS={enabled}: " +
                  run([*runner, exe], env).strip(), flush=True)

if __name__ == "__main__":
    main()
