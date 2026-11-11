"""A nominated persistent loop reclaims scratch while preserving old versions."""
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tests/bench/reclamation/persistent_aliases.fpr"


def run(args, env):
    return subprocess.run(args, env=env, cwd=ROOT, text=True, capture_output=True,
                          check=True, timeout=180)


with tempfile.TemporaryDirectory(prefix="fpr-persistent-") as d:
    env = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
    env.update(FPR_HOME=str(ROOT), XDG_CACHE_HOME=d, FPR_COST_PROBE="1", FPR_COST_REPORT="1")
    exe = Path(d) / "alias"
    for loop, args, answer in (("walk", ["list", "256"], "785920 523776"),
                               ("treeLoop", ["tree", "10000"], "10000 0"),
                               ("mapLoop", ["map", "50000"], "8257 1"),
                               ("history", ["history", "20000"], "200030000"),
                               ("scan", ["scan", "1000000"], "3999994")):
        for selected, rollback in ((False, False), (True, False), (True, True), (True, False)):
            enabled = selected and not rollback
            mode = dict(env)
            if rollback:
                mode["FPR_NO_PERSISTENT_COPY_OUT"] = "1"
            if selected:
                mode["FPR_PERSISTENT_LOOP"] = loop
            run([ROOT / "fpr", "build", SOURCE, "-o", exe], mode)
            p = run([exe, *args], mode)
            assert p.stdout.strip() == answer, (args, p.stdout)
            copies = int(re.search(r'"state_copies":(\d+)', p.stderr)[1])
            assert (copies > 0) == enabled, (loop, enabled, copies)
            if loop == "history" and enabled:
                # the versions share their tails: copy-out copies distinct cells
                # (about 2n), not the n*n/2 a tree walk finds (4.2 GB unshared)
                copied = int(re.search(r'"state_bytes":(\d+)', p.stderr)[1])
                assert copied < 16 << 20, (loop, copied)
            if loop == "scan" and enabled:
                # the input was built before the loop, in the caller's pool: it
                # outlives the region and is never copied (4.9 GB when it was)
                copied = int(re.search(r'"state_bytes":(\d+)', p.stderr)[1])
                assert copied < 4 << 20, (loop, copied)
        print(f"{loop}: output, old version, copy-out and cache rollback PASS")
