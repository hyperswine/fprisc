#!/usr/bin/env python3
"""std work/alloc contracts stay in sync with the costs the compiler derives.

Every std module that declares `| work f <= ...` or `| alloc f <= ...` is
imported into one generated program and built with `fpr build --cost`
(compiler/Cost.hs). Any declared bound that is not PROVEN fails the check,
naming the function, declared and derived values. Declarations looser than
the derived constant are counted as slack (informational).

  --fix   rewrite a failing *constant* declaration in std/ to the derived
          value (symbolic bounds are reported, never rewritten)."""
import os, re, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
LINE = re.compile(r'^\s+([A-Za-z0-9_\']+)@[0-9a-f]+: declared (work|alloc) <= (.+?)\s+derived (.+?)\s+([A-Z]+)\b')

def main():
    fix = '--fix' in sys.argv
    mods = sorted(p for p in (ROOT / 'std').glob('*.fpr') if re.search(r'\|\s*(work|alloc) ', p.read_text()))
    with tempfile.TemporaryDirectory(prefix='fpr-contracts-') as d:
        tmp = Path(d)
        src = tmp / 'contracts.fpr'
        src.write_text(''.join(f'M{i} = use "std/{m.stem}".\n' for i, m in enumerate(mods)) + 'main = print 0.\n')
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / 'cache'))
        p = subprocess.run([str(ROOT / 'fpr'), 'build', '--cost', str(src), '-o', str(tmp / 'contracts')],
                           cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
    out = p.stdout + p.stderr
    seen, bad, slack = set(), [], 0
    for line in out.splitlines():
        m = LINE.match(line)
        if not m: continue
        name, kind, declared, derived, status = (g.strip() for g in m.groups())
        if (name, kind) in seen: continue
        seen.add((name, kind))
        if status != 'PROVEN': bad.append((name, kind, declared, derived, status))
        elif declared.isdigit() and derived.isdigit() and int(declared) > int(derived): slack += 1
    if not seen:
        print(out[-3000:]); sys.exit('std contracts: no declared bounds found in the --cost report')
    for name, kind, declared, derived, status in bad:
        print(f'DRIFT {kind} {name}: declared <= {declared}, derived {derived} ({status})')
        if fix and declared.isdigit() and derived.isdigit():
            pat = re.compile(rf'(\|\s*{kind} {re.escape(name)} <= ){declared}\b')
            for m in mods:
                t = m.read_text()
                if pat.search(t):
                    m.write_text(pat.sub(rf'\g<1>{derived}', t)); print(f'  fixed in {m.relative_to(ROOT)}')
    print(f'std contracts: {len(seen)} declared bounds in {len(mods)} modules, {len(bad)} drifted, {slack} with slack')
    if bad and not fix: sys.exit(1)
    if not bad and p.returncode != 0:
        print(out[-3000:]); sys.exit(f'std contracts: build failed (exit {p.returncode}) without a contract drift')

main()
