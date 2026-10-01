#!/usr/bin/env python3
"""index-sites.py -- every call site whose meaning depends on the index base
(docs/2026-10-01-INDEXING.md, docs/2026-10-02-ZERO-BASED.md).

    tools/index-sites.py [roots...]       list file:line: api  text
    tools/index-sites.py --count [roots]  per-file counts

The 0-based migration flips these names in place; this lists where they are
used so each site is reviewed, not guessed.  Comments are skipped.  The
default roots are this tree and ../qos.
"""
import os, re, sys

APIS = [
    ("charAt", r"\bcharAt\b"),
    ("substr", r"\bsubstr\b"),
    ("strIndexOf", r"\bstrIndexOf\b"),
    ("strIndexFrom", r"\bstrIndexFrom\b"),
    ("!", r"[\w)\]] ! [\w(]"),
    ("Vec.get", r"\bVec\.get\b"),
    ("Vec.set", r"\bVec\.set\b"),
    ("sstrAt", r"\bsstrAt\b"),
    ("sstrPut", r"\bsstrPut\b"),
    ("String.position", r"\bString\.(slice|indexOf|indexFrom)\b"),
    ("Str.position", r"\bStr\.(at|sub|slice|find|findFrom|indexOf|indexFrom)\b"),
]
SKIP_DIRS = {".git", ".fpr", "build", "dist-newstyle", "node_modules", ".cache"}
EXTS = (".fpr", ".sol")

def scan(roots):
    for root in roots:
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if d not in SKIP_DIRS]
            for fn in fns:
                if not fn.endswith(EXTS):
                    continue
                path = os.path.join(dp, fn)
                try:
                    lines = open(path, errors="replace").read().split("\n")
                except OSError:
                    continue
                for n, line in enumerate(lines, 1):
                    code = line.split("#")[0] if fn.endswith(".fpr") else line.split("--")[0]
                    for api, pat in APIS:
                        if re.search(pat, code):
                            yield path, n, api, line.strip()

def main():
    args = sys.argv[1:]
    count = "--count" in args
    roots = [a for a in args if a != "--count"]
    if not roots:
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        roots = [here, os.path.join(os.path.dirname(here), "qos")]
    if count:
        per = {}
        for path, _n, api, _t in scan(roots):
            per.setdefault(path, 0)
            per[path] += 1
        for p, c in sorted(per.items(), key=lambda kv: -kv[1]):
            print(f"{c:5d}  {p}")
        print(f"{sum(per.values()):5d}  sites in {len(per)} files")
    else:
        for path, n, api, text in scan(roots):
            print(f"{path}:{n}: {api}  {text}")

if __name__ == "__main__":
    main()
