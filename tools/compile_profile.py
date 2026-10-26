#!/usr/bin/env python3
"""Where a compile spends its time and allocation, by compiler stage.

Runs build/fpr-prof (make fpr-prof: the -O1 compiler with GHC's late cost
centres) on a program with a fresh cache and prints the profile's call tree
with inherited time and allocation, keeping the branches over a threshold.
Inherited costs are exact for each stage's functions, unlike wall-clock
timers between lazy stages, which charge work to whoever forces it first.

  tools/compile_profile.py examples/pos1.fpr
  tools/compile_profile.py prog.fpr --min 1 --depth 14 --system posix
  tools/compile_profile.py --flat prog.fpr      the top cost centres by self time

The profiled compiler runs about 1.5x slower than ./fpr; the shares, not the
seconds, are the result. The .prof file is kept with --keep DIR.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROF = ROOT / "build" / "fpr-prof"


def tree(prof_text):
    """(indent, name, module, entries, inherited time %, inherited alloc %) rows."""
    lines = prof_text.split("\n")
    heads = [i for i, l in enumerate(lines) if l.startswith("COST CENTRE")]
    rows = []
    for line in lines[heads[-1] + 2:]:
        if not line.strip():
            continue
        parts = line.split()
        try:
            entries = int(parts[-5])
            inh_time, inh_alloc = float(parts[-2]), float(parts[-1])
        except (ValueError, IndexError):
            continue
        rows.append((len(line) - len(line.lstrip(" ")), parts[0], parts[1], entries, inh_time, inh_alloc))
    return rows


def flat(prof_text, count):
    lines = prof_text.split("\n")
    head = [i for i, l in enumerate(lines) if l.startswith("COST CENTRE")][0]
    out = []
    for line in lines[head + 2:]:
        if not line.strip():
            break
        out.append(line)
    return out[:count]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("program")
    ap.add_argument("--system", default="posix")
    ap.add_argument("--min", type=float, default=2.0, help="smallest inherited time %% to show")
    ap.add_argument("--depth", type=int, default=12, help="deepest tree level to show")
    ap.add_argument("--flat", action="store_true", help="the top cost centres by self time instead")
    ap.add_argument("--keep", help="copy the .prof file into this directory")
    args = ap.parse_args()
    if not PROF.is_file():
        raise SystemExit(f"{PROF.relative_to(ROOT)} is missing: make fpr-prof")

    with tempfile.TemporaryDirectory(prefix="fpr-compile-profile-") as d:
        tmp = Path(d)
        env = {**os.environ, "XDG_CACHE_HOME": str(tmp / "cache"),
               "FPR_HOME": os.environ.get("FPR_HOME", str(ROOT))}
        env.pop("GHCRTS", None)
        p = subprocess.run([PROF, "compile", f"--system={args.system}", Path(args.program).resolve(),
                            tmp / "out.s", "+RTS", "-p", f"-po{tmp / 'fpr'}", "-RTS"],
                           cwd=tmp, env=env, capture_output=True, text=True)
        if p.returncode != 0:
            sys.stderr.write(p.stdout[-3000:] + p.stderr[-3000:])
            raise SystemExit(f"compile failed: exit {p.returncode}")
        text = (tmp / "fpr.prof").read_text()
        if args.keep:
            Path(args.keep).mkdir(parents=True, exist_ok=True)
            shutil.copy(tmp / "fpr.prof", Path(args.keep) / (Path(args.program).stem + ".prof"))

    for line in text.split("\n")[:6]:
        if "total" in line:
            print(line.strip())
    if args.flat:
        print("\n".join(flat(text, 30)))
        return
    rows = tree(text)
    base = min(r[0] for r in rows)
    print(f"{'inh time':>9} {'inh alloc':>9} {'entries':>9}  stage")
    for indent, name, module, entries, inh_time, inh_alloc in rows:
        level = indent - base
        if inh_time >= args.min and level <= args.depth:
            print(f"{inh_time:8.1f}% {inh_alloc:8.1f}% {entries:9d}  {'  ' * level}{name} [{module}]")


if __name__ == "__main__":
    main()
