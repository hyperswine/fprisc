#!/usr/bin/env python3
"""Bounded register placement and compact frames: values, bounds and cache modes."""
import os
import platform
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(args, env):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout


def bounds(asm):
    files = [asm] + [Path(p) for p in Path(str(asm) + ".units").read_text().splitlines()]
    result = {}
    for path in files:
        for name, seg, tail, cc in re.findall(
                r"^# wcet: (\S+) segmax=(\S+) exittail=(\S+) ccalls=(\d+)",
                path.read_text(), re.M):
            name = name.replace("-costedregs", "").replace("-compactframes", "")
            assert seg != "UNBOUNDED" and tail != "UNBOUNDED", name
            result[name] = tuple(map(int, (seg, tail, cc)))
    return result


def main():
    legacy_host = platform.machine() not in ("arm64", "aarch64", "x86_64", "AMD64")
    with tempfile.TemporaryDirectory(prefix="fpr-frame-placement-") as td:
        tmp = Path(td)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / "cache"), FPR_NO_INLINE="1",
                   FPR_SELF_LOOPS="1", FPR_RETAINED_REGISTERS="0",
                   FPR_COSTED_REGISTERS="0", FPR_COMPACT_FRAMES="0")
        env.pop("FPR_FOREIGN", None)
        # compact frames are a legacy-emission switch: this check names the legacy backend
        env["FPR_TYPED_IR_BACKEND"] = "legacy"
        print(run(["cabal", "exec", "--", "runghc", "-w", "-icompiler",
                   "tests/FramePlacement.hs"], env), end="")
        source = tmp / "placement.fpr"
        source.write_text("""unsafe base.
hot : unsafe Int -> Int -> Int .
hot a b = if a < 0 then a - b else a * b + a + a + b.
sum : unsafe Int -> Int -> Int .
sum n a = if n == 0 then a else sum (n - 1) (a + n).
deep : unsafe Int -> Int .
deep n = if n == 0 then 0 else 1 + deep (n - 1).
mixed : unsafe String -> Int -> (String, Int) .
mixed s n = (s, n * n + n + 7).
main = _ = print (hot 7 9); _ = print (hot (0 - 7) 9);
  _ = print (sum 10000 0); _ = print (deep 10000);
  (s, n) = mixed ("ab" + "cd") 13; print "{s} {n}".
""")
        expected = "86\n-16\n50005000\n10000\nabcd 189\n"
        assemblies = {}
        entries = []
        for costed, compact in [(0, 0), (1, 0), (0, 1), (1, 1), (0, 0)]:
            mode = dict(env, FPR_COSTED_REGISTERS=str(costed), FPR_COMPACT_FRAMES=str(compact))
            if legacy_host:
                exe = tmp / "placement"
                run([ROOT / "fpr", "build", source, "--harts", "4", "-o", exe], mode)
                for harts in ("1", "4"):
                    assert run([exe], dict(mode, FPR_HARTS=harts)) == expected
            for target in ("rv64", "rv32"):
                asm = tmp / f"{target}-{costed}-{compact}.s"
                run([ROOT / "fpr", "compile", "--target=" + target, source, asm], mode)
                assemblies[target, costed, compact] = asm
            if legacy_host:
                assert run([ROOT / "fpr", "run", source], mode) == expected
                entries.append({p.name for p in (tmp / "cache/fpr/run").glob("placement-*") if p.is_file()})
        for target in ("rv64",):
            for compact in (0, 1):
                old = bounds(assemblies[target, 0, compact])
                new = bounds(assemblies[target, 1, compact])
                assert old.keys() == new.keys()
                assert all(all(b <= a for a, b in zip(old[k], new[k])) for k in old), target
        a = assemblies["rv64", 0, 0].read_text()
        b = assemblies["rv64", 0, 1].read_text()
        frame = lambda s: int(re.search(r"# fn deep \(arity 1\).*?addi sp, sp, -(\d+)", s, re.S)[1])
        assert frame(b) < frame(a), (frame(a), frame(b))
        rv32 = [assemblies["rv32", c, f].read_text() for c in (0, 1) for f in (0, 1)]
        assert all(s == rv32[0] for s in rv32)
        if legacy_host:
            assert [len(x) for x in entries] == [1, 2, 3, 4, 4], entries
        if legacy_host:
            print("Frame placement: native legacy values, stacks, harts and run caches PASS")
        print(f"Frame placement: RV64 fuel bounds, RV32 boundary PASS; deep frame {frame(a)} -> {frame(b)} bytes")


if __name__ == "__main__":
    main()
