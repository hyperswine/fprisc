#!/usr/bin/env python3
"""Self-tail frame reuse: argument cycles, effects, fuel, stacks and caches."""
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def run(args, env, code=0):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                       capture_output=True, timeout=240)
    assert p.returncode == code, (args, p.returncode, p.stdout[-3000:], p.stderr[-3000:])
    return p.stdout

def fixture():
    text = """unsafe base.
Loops.arm : Unit -> Unit .
Loops.used : Unit -> Int .
Loops.force : Unit -> Unit .
ticks : unsafe Int -> Int -> Int .
ticks n a = if n == 0 then a else ticks (n - 1) (a + 1).
deep : unsafe Int -> Int .
deep n = if n == 0 then 0 else 1 + deep (n - 1).
mixed : unsafe Int -> Int -> Int .
mixed n a = if n == 0 then a else mixed (n - 1) (a + deep 10000).
mark n = _ = print n; n.
effects : unsafe Int -> Int -> Int -> Int .
effects n a b = if n == 0 then a * 10 + b
  else effects (n - 1) (mark b) (mark a).
spin : unsafe Int -> Unit .
spin n = spin n.
hog parent self = _ = send parent 1; spin 0.
"""
    cases = []
    expected = {}
    for width in (2, 7, 8, 63):
        names = [f"a{i}" for i in range(1, width + 1)]
        text += f"""rotate{width} : unsafe {' -> '.join(['Int'] * (width + 2))} .
rotate{width} n {' '.join(names)} = if n == 0 then {' + '.join(f'{i} * {n}' for i, n in enumerate(names, 1))}
  else rotate{width} (n - 1) {' '.join(names[1:] + names[:1])}.
"""
        cases.append(f'["rotate{width}"] -> _ = Loops.force Unit; print (rotate{width} 20001 {" ".join(map(str, range(1, width + 1)))})')
        values = list(range(1, width + 1))
        shift = 20001 % width
        values = values[shift:] + values[:shift]
        expected[f"rotate{width}"] = f"{sum(i*v for i, v in enumerate(values, 1))}\n"
    cases += [
        '["ticks"] -> _ = Loops.arm Unit; a = ticks 20000 0; count = Loops.used Unit; print "{a} {count}"',
        '["stack"] -> print (mixed 20 0)',
        '["effects"] -> print (effects 2 1 2)',
        '["fair"] -> me = myself 0; child = spawn (hog me); msg = receiveFrom me child; saved = keep msg; _ = kill child; print saved',
        '_ -> print "self loops"',
    ]
    # 20,001 loop entries plus the uninlined Unit entry passed to used.
    expected.update(ticks="20000 20002\n", stack="200000\n",
                    effects="2\n1\n1\n2\n12\n", fair="1\n")
    return text + "main = case Sys.args Unit of\n  " + "\n | ".join(cases) + ".\n", expected

def main():
    with tempfile.TemporaryDirectory(prefix="fpr-self-loops-") as td:
        tmp = Path(td)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / "cache"), FPR_NO_INLINE="1",
                   FPR_NO_SCALAR_WORKERS="1", FPR_NO_FIELD_WORKERS="1")
        env.pop("FPR_FOREIGN", None)
        # FPR_SELF_LOOPS is a legacy-emission switch, and the exact tick count
        # below counts legacy entries: this check names the legacy backend
        env.pop("FPR_TYPED_IR_BACKEND", None)
        ghc = ["cabal", "exec", "--", "runghc"] if shutil.which("cabal") else ["runghc"]
        print(run([*ghc, "-w", "-icompiler", "tests/SelfLoops.hs"], env), end="", flush=True)
        print(run([*ghc, "-w", "-icompiler", "tests/NullaryConstants.hs"], env), end="", flush=True)
        source = tmp / "selfloops.fpr"
        text, expected = fixture()
        source.write_text(text)
        units = []
        run_entries = []
        rv32_emission = []
        builtin_emission = []
        builtin = tmp / "builtin.fpr"
        builtin.write_text("profile builtin.\nloop n a = if n == 0 then a else loop (n - 1) (a + 1).\nmain = loop 10 0.\n")
        for enabled in ("0", "1", "0"):
            mode = dict(env, FPR_SELF_LOOPS=enabled)
            for no_regs in ("0", "1"):
                local = dict(mode, FPR_NO_REGISTERS=no_regs)
                exe = tmp / "probe"
                run([ROOT / "fpr", "build", source, "--harts", "4",
                     "--with", ROOT / "tests/base/selfloops_probe.c", "-o", exe], local)
                for harts in ("1", "4"):
                    for case, want in expected.items():
                        got = run([exe, case], dict(local, FPR_HARTS=harts))
                        assert got == want, (enabled, no_regs, harts, case, got, want)
            for target in ("rv64", "a64", "x64", "rv32"):
                asm = tmp / (target + ".s")
                run([ROOT / "fpr", "compile", "--target=" + target, source, asm], mode)
                assembly = asm.read_text()
                assert bool(re.search(r"^\.?Lself\d+:", assembly, re.M)) == (enabled == "1" and target != "rv32"), target
                assert "segmax=UNBOUNDED" not in assembly, target
                if target == "rv32":
                    rv32_emission.append(assembly)
                if target == "rv64":
                    # The stack and fuel checks lie after the back-edge target,
                    # while allocation and preserved-register saves lie before it.
                    mixed = assembly.split("# fn mixed (arity 2)", 1)[1].split("# wcet:", 1)[0]
                    if enabled == "1":
                        entry = re.search(r"^(\.Lself\d+):", mixed, re.M)
                        assert entry and "    j " + entry[1] in mixed, mixed
                        loop = mixed[entry.start():]
                        assert "call fpr_stack_grow" in loop and "call fpr_fuel_exhausted" in loop, loop
                        assert "addi sp, sp, -" not in loop, loop
                    paths = set(Path(str(asm) + ".units").read_text().splitlines())
                    assert paths and all(("-selfloops" in p) == (enabled == "1") for p in paths)
                    units.append(paths)
            asm = tmp / "builtin.s"
            run([ROOT / "fpr", "compile", "--target=rv64", builtin, asm], mode)
            builtin_emission.append(asm.read_text())
            assert run([ROOT / "fpr", "run", "tests/bench/fib.fpr"], mode).strip() == "fib 35 = 9227465"
            run_entries.append({p.name for p in (tmp / "cache/fpr/run").glob("fib-*") if p.is_file()})
        assert units[0] == units[2] and units[0].isdisjoint(units[1]), units
        assert len(run_entries[0]) == 1 and len(run_entries[1]) == 2, run_entries
        assert run_entries[0] < run_entries[1] == run_entries[2], run_entries
        assert rv32_emission[0] == rv32_emission[1] == rv32_emission[2]
        assert builtin_emission[0] == builtin_emission[1] == builtin_emission[2]
        print("Self loops: 1/4 harts, registers off/on, 3/8/9/64 args, exact fuel ticks, effects, stack growth, fairness, emission and off/on/off caches PASS", flush=True)
        # SHA/prelude exposed stores retained by introducing a back-edge
        # before slot cleanup. Compare every function, not just a global
        # maximum that could hide a smaller function's regression.
        tables = []
        for enabled in ("0", "1"):
            asm = tmp / "sha.s"
            run([ROOT / "fpr", "compile", "--target=rv64",
                 ROOT / "tests/bench/sha.fpr", asm],
                dict(env, FPR_SELF_LOOPS=enabled, FPR_NO_INLINE="0",
                     FPR_NO_SCALAR_WORKERS="0", FPR_NO_FIELD_WORKERS="0"))
            files = [asm] + [Path(p) for p in Path(str(asm) + ".units").read_text().splitlines()]
            table = {}
            for file in files:
                for name, count in re.findall(r"^# wcet: (\S+) segmax=(\S+)", file.read_text(), re.M):
                    assert count != "UNBOUNDED", (enabled, name)
                    # Specialization names embed the unit cache filename.
                    if name.startswith("$spec."):
                        name = re.sub(r"-selfloops(?=rt\d+pc\d+-)", "", name)
                    table[name] = int(count)
            tables.append(table)
        assert tables[0].keys() == tables[1].keys()
        increases = {k: (v, tables[1][k]) for k, v in tables[0].items() if tables[1][k] > v}
        assert not increases, increases
        print(f"Self loops: SHA and imported units, {len(tables[0])} finite WCET bounds, no per-function increase PASS", flush=True)

if __name__ == "__main__":
    main()
