#!/usr/bin/env python3
"""A64 raw Int guards: machine oracle, exact panics and cache separation."""
import os
import platform
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def run(args, env, code=0):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=240)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout + p.stderr

def main():
    with tempfile.TemporaryDirectory(prefix="fpr-a64-guards-") as d:
        tmp = Path(d)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / "cache"))
        env.pop("FPR_FOREIGN", None)
        print(run(["runghc", "-w", "-icompiler", "tests/A64Guards.hs", tmp], env), end="")
        # The ELF form must assemble too, including its local branch labels.
        run(["clang", "--target=aarch64-linux-gnu", "-c", tmp / "fit-elf.s",
             "-o", tmp / "fit-elf.o"], env)
        if platform.machine() not in ("arm64", "aarch64"):
            print("A64 native execution SKIP: needs A64 host")
            return
        oracle = tmp / "oracle.c"
        oracle.write_text(r"""
#include <stdint.h>
#include <stdio.h>
#include <assert.h>
extern long fit_old(int64_t), fit_new(int64_t);
extern int64_t norm_old(int64_t), norm_new(int64_t);
static void check(uint64_t u) {
    int64_t x = (int64_t)u;
    long want = x >= -INT64_C(4611686018427387904) && x <= INT64_C(4611686018427387903);
    assert(fit_old(x) == want && fit_new(x) == want);
    uint64_t low = u & (UINT64_MAX >> 1);
    int64_t norm = (int64_t)((__int128)low - ((low >> 62) ? ((__int128)1 << 63) : 0));
    assert(norm_old(x) == norm && norm_new(x) == norm);
}
int main(void) {
    uint64_t edges[] = {0,1,UINT64_MAX,UINT64_C(1)<<62,(UINT64_C(1)<<62)-1,
        UINT64_C(1)<<63,(UINT64_C(1)<<63)-1,UINT64_C(3)<<62,(UINT64_C(3)<<62)-1};
    for (unsigned i=0;i<sizeof(edges)/sizeof(edges[0]);i++) check(edges[i]);
    uint64_t x=20261020;
    for (int i=0;i<100000;i++) { x^=x<<13; x^=x>>7; x^=x<<17; check(x); }
    puts("A64 guard execution: 100009 boundary/random C-reference cases PASS");
}
""")
        asm = tmp / ("fit-mac.s" if platform.system() == "Darwin" else "fit-elf.s")
        run(["cc", "-O2", asm, oracle, "-o", tmp / "oracle"], env)
        print(run([tmp / "oracle"], env), end="")
        reference = {}
        run_entries = []
        unit_entries = {"a64": [], "a64mac": []}
        for off in ("1", "0", "1"):
            mode = dict(env, FPR_A64_FIT_GUARDS="1" if off == "0" else "0")
            exe = tmp / "intovf"
            run([ROOT / "fpr", "build", "tests/base/intovf.fpr", "-o", exe], mode)
            for harts in ("1", "4"):
                local = dict(mode, FPR_HARTS=harts)
                for arg in ("ok", "add", "sub", "mul", "mulsmall", "div", "neg", "kernel", "kernel2", "fold"):
                    output = run([exe, arg], local, 0 if arg == "ok" else 1)
                    value = output if arg == "ok" else next(
                        line for line in output.splitlines() if line.startswith("[ERR] "))
                    assert "Int overflow" in value or arg == "ok", (arg, value)
                    assert reference.setdefault(arg, value) == value, (off, harts, arg, value)
            for target in ("a64", "a64mac"):
                output = tmp / (target + ".s")
                run([ROOT / "fpr", "compile", "--target=" + target,
                     "tests/bench/fib.fpr", output], mode)
                text = output.read_text()
                assert ("sbfx x10, x9, #0, #63" in text) == (off == "0"), (off, target)
                units = set(Path(str(output) + ".units").read_text().splitlines())
                assert units and all(Path(p).exists() for p in units), units
                assert all(("-fitguards" in p) == (off == "0") for p in units), units
                unit_entries[target].append(units)
            # Exercise executable-run caches with the same source and compiler.
            assert run([ROOT / "fpr", "run", "tests/bench/fib.fpr"], mode).strip() == "fib 35 = 9227465"
            run_entries.append({p.name for p in (tmp / "cache/fpr/run").glob("fib-*") if p.is_file()})
        assert len(run_entries[0]) == 1 and len(run_entries[1]) == 2, run_entries
        assert run_entries[0] < run_entries[1] == run_entries[2], run_entries
        for units in unit_entries.values():
            assert units[0] == units[2] and units[0].isdisjoint(units[1]), units
        # The switch must not change non-A64 output.
        for target in ("rv64", "x64"):
            emitted = []
            for off in ("1", "0"):
                output = tmp / (target + ".s")
                run([ROOT / "fpr", "compile", "--target=" + target,
                     "tests/bench/fib.fpr", output], dict(env, FPR_A64_FIT_GUARDS="1" if off == "0" else "0"))
                emitted.append(output.read_text())
            assert emitted[0] == emitted[1], target
        print("A64 guards: exact overflow reasons, 1/4 harts, off/on/off caches, ELF/Mach-O and unchanged RV64/x64 PASS")

if __name__ == "__main__":
    main()
