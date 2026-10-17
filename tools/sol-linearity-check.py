#!/usr/bin/env python3
"""Check that Sol retains inferred ownership for unannotated bindings."""

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get("FPR_TEST_BINARY", ROOT / "fpr")).resolve()
BASE = """Token 1 = Type (Token Int).
consume : Token -> Int.
consume owner = Token value = owner; value.
"""


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix="sol-linearity-") as tmp:
        work = Path(tmp)
        env = {k: v for k, v in os.environ.items() if not k.startswith("SOL_")}
        env |= {"SOL_CACHE": "0", "SOL_GPU": "0", "SOL_JIT": "0",
                "SOL_CACHE_DIR": str(work / "cache")}

        def check(name, source, expected=None):
            nonlocal count
            path = work / f"{name}.sol"
            path.write_text(BASE + source)
            result = subprocess.run([str(FPR), "sol", str(path)], env=env,
                                    capture_output=True, text=True, timeout=30)
            if expected is None:
                assert result.returncode == 1, (name, result)
                assert "LINEARITY" in result.stderr, (name, result.stderr)
                assert not result.stdout, (name, result.stdout)
            else:
                assert result.returncode == 0, (name, result)
                assert result.stdout == expected, (name, result.stdout, result.stderr)
                assert not result.stderr, (name, result.stderr)
            count += 1

        check("inferred_return_duplicate", """
makeUnannotated u = Token 7.
main = t = makeUnannotated 0; print (consume t, consume t).
""")
        check("inferred_parameter_duplicate", """
handleUnannotated t = (consume t, consume t).
main = print (handleUnannotated (Token 7)).
""")
        check("inferred_return_discard", """
makeUnannotated u = Token 7.
main = t = makeUnannotated 0; print "unexpected execution".
""")
        check("inferred_tuple_duplicate", """
makePair u = (Token 7, 8).
main = (t, n) = makePair 0; print (consume t, consume t, n).
""")
        check("inferred_eval_duplicate", """
makeUnannotated u = Token 7.
> t = makeUnannotated 0; print (consume t, consume t).
""")
        check("logic_marks_lost_successor", f'''
L = use "{ROOT}/sol/lib/logic.sol".
main = hp = Vec.new Unit; tr = Vec.new Unit;
       (hm, tm, _) = L.marks (hp, 0, 0, tr, 0, 0);
       print (hm, tm).
''')
        check("inferred_composition", """
makeUnannotated u = Token 7.
nextUnannotated owner = Token value = owner; Token (value + 1).
main = original = makeUnannotated 0;
       next = nextUnannotated original;
       print (consume next).
""", "8\n")
        check("inferred_tuple_composition", """
makePair u = (Token 7, 8).
> (t, n) = makePair 0; print (consume t + n).
""", "15\n")
    print(f"Sol inferred linearity: {count} checks passed")


if __name__ == "__main__":
    main()
