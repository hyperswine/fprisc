#!/usr/bin/env python3
"""Type-directed call synthesis cannot discard a selected global's contract.

Inference chooses Int.mod/Int.pow for %/^ after the source precondition pass.
Exercise that actual path in both frontends, including imports and a guard,
then check that ordinary direct-call proof/cost discharge stays unchanged.
The selected compiler executable must already have been built.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / "fpr"

with tempfile.TemporaryDirectory(prefix="fpr-contract-rewrites-") as directory:
    tmp = Path(directory)
    env = {**os.environ, "FPR_HOME": str(ROOT), "FPR_PATH": str(ROOT),
           "XDG_CACHE_HOME": os.environ.get("XDG_CACHE_HOME", str(tmp / "cache")),
           "SOL_CACHE_DIR": str(tmp / "sol-cache"), "SOL_GPU": "0"}
    env.pop("FPR_FOREIGN", None)

    def run(args, code=0, needle=None):
        result = subprocess.run(list(map(str, args)), cwd=tmp, env=env,
                                capture_output=True, text=True, timeout=180)
        output = result.stdout + result.stderr
        assert result.returncode == code, (args, result.returncode, output)
        if needle is not None:
            assert needle in output, (args, needle, output)
        return result

    def execute(name, definitions, body, mode, code=0, needle=None):
        source = tmp / (name + (".sol" if mode == "sol" else ".fpr"))
        entry = "> " if mode == "sol" else "main = "
        source.write_text(definitions + entry + body + ".\n")
        if mode == "sol":
            return run([FPR, "sol", source], code, needle)
        image = tmp / name
        run([FPR, "build", source, "-o", image])
        return run([image], code, needle)

    contracts = """
Int.mod : Int -> (divisor : Int | divisor > 0) -> Int.
Int.pow : Int -> (exponent : Int | exponent >= 2) -> Int.
"""
    for mode in ("native", "sol"):
        got = execute("accepted-" + mode, contracts,
                      'print "operator: {19 % 5} {2 ^ 3}; direct: {Int.mod 19 5} {Int.pow 2 3}"', mode)
        assert got.stdout.strip() == "operator: 4 8; direct: 4 8", got.stdout
        for label, expression, function in [
            ("mod-operator", "3 % (-2)", "Int.mod"),
            ("mod-direct", "Int.mod 3 (-2)", "Int.mod"),
            ("pow-operator", "2 ^ 1", "Int.pow"),
            ("pow-direct", "Int.pow 2 1", "Int.pow"),
        ]:
            # Without the selected-global guard, the two operator forms
            # execute their bodies and return 1/2 despite invalid inputs.
            execute(label + "-" + mode, contracts,
                    'print "must-not-return: {' + expression + '}"', mode,
                    1, "precondition violated: " + function)
        guarded = contracts + """
decide divisor | 3 % divisor == 1 = True.
decide _ = False.
"""
        execute("guard-" + mode, guarded, 'print (decide (-2))', mode,
                1, "precondition violated: Int.mod")

        module = tmp / "operator-client.fpr"
        module.write_text("remainder a b = a % b.\n")
        execute("import-" + mode, contracts + 'M = use "operator-client.fpr".\n',
                'print (M.remainder 3 (-2))', mode,
                1, "precondition violated: Int.mod")

    # A shared unit's generated guards depend on the merged contract table,
    # including foreign declarations supplied by its root. Reusing this cache
    # entry under a stronger contract must not revive unchecked unit code.
    shared = tmp / "shared-delay.fpr"
    shared.write_text("delay n = Sys.sleepUs n.\n")
    execute("cache-weak", """
Sys.sleepUs : (n : Int | n >= 0) -> Unit.
M = use "shared-delay.fpr".
""", 'u = M.delay 0; print "cached weak contract"', "native",
            needle="cached weak contract")
    execute("cache-strong", """
Sys.sleepUs : (n : Int | n > 0) -> Unit.
M = use "shared-delay.fpr".
""", 'u = M.delay 0; print "must-not-run"', "native", 1,
            "precondition violated: Sys.sleepUs")

    direct = tmp / "direct-budget.fpr"
    direct.write_text("""
positive : (n : Int | n > 0) -> Int | work positive <= 0 | alloc positive <= 0.
positive n = n.
main : Int | work main <= 1 | alloc main <= 0.
main = positive 2.
""")
    report = run([FPR, "build", "--cost", direct, "-o", tmp / "direct-budget"])
    for claim in ["positive: declared work <= 0   derived 0   PROVEN",
                  "positive: declared alloc <= 0   derived 0   PROVEN",
                  "main: declared work <= 1   derived 1   PROVEN",
                  "main: declared alloc <= 0   derived 0   PROVEN"]:
        assert claim in report.stdout, report.stdout + report.stderr

print("Contract rewrites: selected operators, guards and imported unit calls retain contracts in native/Sol; native cache context is isolated; direct budgets still prove")
