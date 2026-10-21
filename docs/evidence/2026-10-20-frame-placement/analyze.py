"""Rebuild structural evidence from the retained benchmark build directories."""
import hashlib
import json
import re
from pathlib import Path

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]


def roots(directory, name):
    return sorted((ROOT / "build" / directory / "cache/fpr/build").glob(name + "-*.s"),
                  key=lambda p: p.stat().st_mtime)


def files(path):
    return [path] + [Path(p) for p in Path(str(path) + ".units").read_text().splitlines()]


def clean_name(name):
    return re.sub(r"-(?:costedregs|compactframes|selfloops|retainedregs|framepairs)", "", name)


def table(root):
    result = {}
    for path in files(root):
        for name, seg, tail, cc in re.findall(
                r"^# wcet: (\S+) segmax=(\S+) exittail=(\S+) ccalls=(\d+)",
                path.read_text(), re.M):
            assert seg != "UNBOUNDED" and tail != "UNBOUNDED", (path, name)
            result[clean_name(name)] = tuple(map(int, (seg, tail, cc)))
    return result


evidence = {}
for directory in ("placement-combined-g66", "frame-pairs-final", "placement-pairs-combined"):
    programs = {}
    for name in ("fib", "sum", "pipeline", "byteloop", "helpers", "sha"):
        before, after = roots(directory, name)
        a, b = table(before), table(after)
        assert a.keys() == b.keys()
        increases = {k: [v, b[k]] for k, v in a.items() if any(y > x for x, y in zip(v, b[k]))}
        assert not increases, (directory, name, increases)
        programs[name] = {"functions": len(a),
                          "maximum_before": max(v[0] for v in a.values()),
                          "maximum_after": max(v[0] for v in b.values()),
                          "increases": increases,
                          "decreases": {k: [v, b[k]] for k, v in a.items() if b[k] != v}}
        if directory == "placement-pairs-combined" and name in ("fib", "sum", "helpers"):
            for label, path in (("off", before), ("on", after)):
                body = re.search(r"^# fn (?:\$worker.scalar.)?(?:fib|loop) \(arity \d+\).*?^# wcet: [^\n]*",
                                 path.read_text(), re.M | re.S)[0]
                (OUT / f"{name}-{label}.s").write_text(body + "\n")
    evidence[directory] = programs
(OUT / "wcet.json").write_text(json.dumps(evidence, indent=2) + "\n")

# All switches off: compare against the frozen revision-65 default.
def normalize(text):
    text = re.sub(r"g(?:65|66)(?=-|rt)", "gREV", text)
    text = re.sub(r"(a64macx28r)(?:14|15)(?=[_.-]|$)", r"\1REV", text)
    def data(match):
        values = bytes(int(x.strip()) for line in match[0].splitlines()
                       for x in line.strip().removeprefix(".byte").strip().split(","))
        values = values.replace(b"fpr-interface-1/g65/", b"fpr-interface-1/gREV/").replace(
            b"fpr-interface-1/g66/", b"fpr-interface-1/gREV/")
        values = values.replace(b"/a64macx28r14/", b"/a64macx28rREV/").replace(
            b"/a64macx28r15/", b"/a64macx28rREV/")
        return "    .bytes " + values.hex() + "\n"
    return re.sub(r"(?:^    \.byte [^\n]*\n)+", data, text, flags=re.M)


parity = {}
for name in ("fib", "sum", "pipeline", "byteloop", "helpers", "sha"):
    old = files(roots("retained-registers-combined", name)[0])
    new = files(roots("placement-pairs-combined", name)[0])
    assert len(old) == len(new)
    matches = []
    for a, b in zip(old, new):
        x, y = normalize(a.read_text()), normalize(b.read_text())
        assert x == y, (a, b)
        matches.append({"before": str(a), "after": str(b),
                        "normalized_sha256": hashlib.sha256(x.encode()).hexdigest()})
    parity[name] = matches
(OUT / "default-parity.json").write_text(json.dumps({
    "normalization": "Codegen/A64 cache revision and encoded interface revision; byte-line wrapping",
    "comparisons": parity}, indent=2) + "\n")
print("PASS: no per-function fuel-bound increases; default parity in", sum(map(len, parity.values())), "assembly files")
