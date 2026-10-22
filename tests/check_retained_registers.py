#!/usr/bin/env python3
"""Retained-access scoring: arithmetic oracle, profile boundaries and caches."""
import os
import platform
import re
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
    legacy_host = platform.machine() not in ("arm64", "aarch64", "x86_64", "AMD64")
    with tempfile.TemporaryDirectory(prefix="fpr-retained-registers-") as td:
        tmp = Path(td)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / "cache"), FPR_NO_INLINE="1",
                   FPR_SELF_LOOPS="0", FPR_NO_REGISTERS="0",
                   FPR_COSTED_REGISTERS="0", FPR_COMPACT_FRAMES="0")
        env.pop("FPR_FOREIGN", None)
        # retained registers are a legacy-emission switch: this check names the legacy backend
        env["FPR_TYPED_IR_BACKEND"] = "legacy"
        source = tmp / "retained.fpr"
        definition = ("hot : unsafe Int -> Int -> Int .\n"
                      "hot a b = a * b + a + a + b.\n")
        pairs = [(a, b) for a in (-100, -1, 0, 1, 100)
                 for b in (-77, 0, 93)]
        source.write_text("unsafe base.\n" + definition + "main =\n" +
                          ";\n".join(f"  _ = print (hot ({a}) ({b}))"
                                     for a, b in pairs) + "; Unit.\n")
        expected = "".join(f"{a*b + 2*a + b}\n" for a, b in pairs)
        builtin = tmp / "builtin.fpr"
        builtin.write_text("profile builtin.\nhot a b = a*b+a+a+b.\nmain = hot 7 9.\n")
        assemblies = {t: [] for t in ("rv64", "rv32", "builtin")}
        units = {t: [] for t in ("rv64",)}
        entries = []
        for enabled in ("0", "1", "0"):
            mode = dict(env, FPR_RETAINED_REGISTERS=enabled)
            if legacy_host:
                for registers in ("0", "1"):
                    local = dict(mode, FPR_NO_REGISTERS=registers)
                    exe = tmp / "probe"
                    run([ROOT / "fpr", "build", source, "--harts", "4", "-o", exe], local)
                    for harts in ("1", "4"):
                        assert run([exe], dict(local, FPR_HARTS=harts)) == expected
            for target in assemblies:
                asm = tmp / (target + ".s")
                run([ROOT / "fpr", "compile", "--target=" + ("rv64" if target == "builtin" else target),
                     builtin if target == "builtin" else source, asm], mode)
                text = asm.read_text()
                assemblies[target].append(text)
                if target in units:
                    paths = set(Path(str(asm) + ".units").read_text().splitlines())
                    assert paths and all(Path(p).exists() for p in paths)
                    assert all(("-retainedregs" in p) == (enabled == "1") for p in paths)
                    units[target].append(paths)
            if legacy_host:
                assert run([ROOT / "fpr", "run", source], mode) == expected
                entries.append({p.name for p in (tmp / "cache/fpr/run").glob("retained-*") if p.is_file()})
        for target in ("rv32", "builtin"):
            assert assemblies[target][0] == assemblies[target][1] == assemblies[target][2], target
        markers = {"rv64": r"\bs[1-5]\b"}
        for target in units:
            assert assemblies[target][0] == assemblies[target][2]
            # Check the arithmetic body, not unrelated prelude or main code:
            # an inert mode switch must not pass a differential test.
            bodies = [text.split("# fn hot (arity 2)", 1)[1].split("# wcet:", 1)[0]
                      for text in assemblies[target]]
            assert not re.search(markers[target], bodies[0]), (target, bodies[0])
            assert re.search(markers[target], bodies[1]), (target, bodies[1])
            assert units[target][0] == units[target][2]
            assert units[target][0].isdisjoint(units[target][1])
        if legacy_host:
            assert len(entries[0]) == 1 and len(entries[1]) == 2
            assert entries[0] < entries[1] == entries[2]
        if legacy_host:
            print("Retained registers: native legacy arithmetic, one/four harts and run caches PASS")
        print("Retained registers: RV64 emission, RV32/builtin boundaries and unit caches PASS")


if __name__ == "__main__":
    main()
