#!/usr/bin/env python3
"""A64 paired frames: independent call oracle and mode/cache boundaries."""
import os
import platform
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(args, env):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=240)
    assert p.returncode == 0, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout


def main():
    with tempfile.TemporaryDirectory(prefix="fpr-frame-pairs-") as td:
        tmp = Path(td)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / "cache"), FPR_RETAINED_REGISTERS="0",
                   FPR_COSTED_REGISTERS="0", FPR_COMPACT_FRAMES="0", FPR_SELF_LOOPS="0")
        env.pop("FPR_FOREIGN", None)
        # frame pairs are a legacy-emission switch: this check names the legacy backend
        env["FPR_TYPED_IR_BACKEND"] = "legacy"
        print(run(["runghc", "-w", "-icompiler", "tests/A64FramePairs.hs", tmp], env), end="")
        run(["clang", "--target=aarch64-linux-gnu", "-c", tmp / "pair-elf.s",
             "-o", tmp / "pair-elf.o"], env)
        if platform.machine() in ("arm64", "aarch64"):
            driver = tmp / "oracle.c"
            driver.write_text("""
#include <assert.h>
#include <stdio.h>
extern long fpr_fn_pair_probe(long);
long pair_clobber(long n) { volatile long x = n; return x + 3; }
int main(void) {
    for (long n=-1000; n<=1000; ++n) assert(fpr_fn_pair_probe(n) == 2*n+3);
    puts("A64 frame pairs: 2001 independent C call/return cases PASS");
}
""")
            asm = tmp / ("pair-mac.s" if platform.system() == "Darwin" else "pair-elf.s")
            run(["cc", "-O2", "-fno-omit-frame-pointer", driver, asm, "-o", tmp / "oracle"], env)
            print(run([tmp / "oracle"], env), end="")
        else:
            print("A64 frame pair native oracle SKIP: requires A64 host")
        units = []
        entries = []
        other = {}
        for flag in ("0", "1", "0"):
            mode = dict(env, FPR_A64_FRAME_PAIRS=flag)
            paths = set()
            for target in ("a64", "a64mac", "rv64", "x64"):
                asm = tmp / f"{target}.s"
                run([ROOT / "fpr", "compile", "--target=" + target,
                     "tests/bench/fib.fpr", asm], mode)
                text = asm.read_text()
                if target.startswith("a64"):
                    assert ("stp x29, x30" in text) == (flag == "1")
                    assert ("ldp x29, x30" in text) == (flag == "1")
                    current = set(Path(str(asm) + ".units").read_text().splitlines())
                    assert current and all(("-framepairs" in p) == (flag == "1") for p in current)
                    paths |= current
                else:
                    assert other.setdefault(target, text) == text
            units.append(paths)
            assert run([ROOT / "fpr", "run", "tests/bench/fib.fpr"], mode).strip() == "fib 35 = 9227465"
            entries.append({p.name for p in (tmp / "cache/fpr/run").glob("fib-*") if p.is_file()})
        assert units[0] == units[2] and units[0].isdisjoint(units[1])
        assert len(entries[0]) == 1 and len(entries[1]) == 2 and entries[0] < entries[1] == entries[2]
        print("A64 frame pairs: ELF/Mach-O emission, off/on/off unit and executable caches, unchanged RV64/x64 PASS")


if __name__ == "__main__":
    main()
