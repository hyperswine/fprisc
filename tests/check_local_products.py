"""Local products and string pieces: same answers and traps as the build with
them off (FPR_NO_REUSE=1 turns off reuse, local products and string pieces),
and sim's shape (an inlined pair taken apart at once) allocates nothing."""
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tests/bench/reclamation/local_products.fpr"
CASES = [["sum", "200000"], ["keep"], ["divs", "2"], ["divs", "0"], ["pieces"]]

with tempfile.TemporaryDirectory(prefix="fpr-local-products-") as d:
    base = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
    base.update(FPR_HOME=str(ROOT), XDG_CACHE_HOME=d, FPR_COST_PROBE="1", FPR_COST_REPORT="1")
    results = {}
    for mode, extra in (("on", {}), ("off", {"FPR_NO_REUSE": "1"})):
        env = dict(base, **extra)
        exe = Path(d) / mode / "lp"
        exe.parent.mkdir()
        subprocess.run([ROOT / "fpr", "build", SOURCE, "-o", exe], env=env, cwd=ROOT,
                       check=True, capture_output=True, text=True, timeout=600)
        for args in CASES:
            p = subprocess.run([exe, *args], env=env, cwd=ROOT, capture_output=True, text=True, timeout=120)
            panic = re.search(r"PANIC[^\n]*", p.stderr)
            requests = re.search(r'"alloc_requests":(\d+)', p.stderr)
            results[(mode, tuple(args))] = (p.returncode, p.stdout, panic[0] if panic else None,
                                           int(requests[1]) if requests else None)
    for args in CASES:
        on, off = results[("on", tuple(args))], results[("off", tuple(args))]
        assert on[:3] == off[:3], (args, on, off)
    assert results[("on", ("divs", "0"))][2], "the zero divisor must still trap"
    # 200000 steps, a pair and a record each: none allocated
    on_sum, off_sum = results[("on", ("sum", "200000"))][3], results[("off", ("sum", "200000"))][3]
    assert on_sum < 1000 and off_sum > 200000, (on_sum, off_sum)
    print(f"local products and string pieces: answers and traps match, sum {off_sum} -> {on_sum} requests: PASS")
