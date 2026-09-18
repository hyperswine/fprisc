#!/usr/bin/env python3

# unsafe-fixup: run fprc with FPR_UNSAFE_SUGGEST=1, take the paste-ready
# `name : unsafe TYPE .` suggestions, and insert each above the first
# clause of the defining function.  Mechanical adoption of the line.

import re, subprocess, sys, glob, os

prog = sys.argv[1]
profile = sys.argv[2] if len(sys.argv) > 2 else "bare-metal"
sol_mode = prog.endswith(".sol")
search = [prog] + sorted(glob.glob("sol/lib/*.sol")) + ["core/prelude.fpr"] + sorted(glob.glob("std/*.fpr")) + sorted(glob.glob("programs/mods/*.fpr")) + sorted(glob.glob("programs/*.fpr")) + sorted(glob.glob("apps/*.fpr")) + sorted(glob.glob("tests/*.fpr"))

def defining_file(name):
    base = name.split(".")[-1].split("@")[0]
    pat = re.compile(r"^" + re.escape(base) + r"[ (]")
    sig = re.compile(r"^" + re.escape(base) + r" : unsafe")
    hits = []
    for f in search:
        if not os.path.exists(f): continue
        lines = open(f).read().split("\n")
        if any(pat.match(l) for l in lines) and not any(sig.match(l) for l in lines):
            hits.append(f)
    # placement: @hash names come from use-spliced modules -> prefer
    # module/std files; plain names belong to the entry program first
    if "@" in name:
        for f in hits:
            if f.startswith("programs/mods/") or f.startswith("std/"):
                return f, base
    for f in hits:
        if f == prog:
            return f, base
    return (hits[0] if hits else None), base

for it in range(12):
    env = dict(os.environ, FPR_UNSAFE_SUGGEST="1", LC_ALL="C.UTF-8")
    if sol_mode:
        # --target=bytecode parses + runs the safety line, executes nothing
        r = subprocess.run(["./fpr", "--target=bytecode", prog],
                           capture_output=True, text=True, env=env)
    else:
        r = subprocess.run(["./fprc", f"--profile={profile}", "--prelude=core/prelude.fpr", prog, "/tmp/fx.s"],
                           capture_output=True, text=True, env=env)
    # auto-repin: annotating a module changes its AST hash
    mm = re.search(r"hash mismatch for ([^:]+):.*?pinned  (#[0-9a-f]+).*?on disk (#[0-9a-f]+)", r.stdout, re.S)
    if mm:
        mod, old, new = mm.groups()
        n = 0
        for f in glob.glob("programs/**/*.fpr", recursive=True) + glob.glob("apps/*.fpr") + glob.glob("tests/*.fpr"):
            s = open(f).read()
            if mod + old in s:
                open(f, "w").write(s.replace(mod + old, mod + new)); n += 1
        print(f"pass {it}: repinned {mod} {old}->{new} in {n} file(s)")
        continue
    sugg = [l[len("SUGGEST "):] for l in r.stdout.splitlines() if l.startswith("SUGGEST ")]
    if not sugg:
        print(("clean" if r.returncode == 0 else "errors-but-no-suggestions") + f" after {it} pass(es)")
        if r.returncode != 0:
            print(r.stdout[-1200:])
        sys.exit(0 if r.returncode == 0 else 1)
    placed = 0
    for line in sugg:
        name = line.split(" : ")[0]
        f, base = defining_file(name)
        if f is None:
            print("?? no defining file for", name); continue
        sig = base + re.sub(r"@[0-9a-f]{16}", "", line[len(name):])
        src = open(f).read().split("\n")
        pat = re.compile(r"^" + re.escape(base) + r"[ (]")
        for i, ln in enumerate(src):
            if pat.match(ln) and " : unsafe" not in ln:
                src.insert(i, sig)
                open(f, "w").write("\n".join(src))
                placed += 1
                break
    print(f"pass {it}: placed {placed} signature(s)")
print("iteration cap reached"); sys.exit(1)
