#!/usr/bin/env python3
"""Every std module is on the safety allow-list (compiler/Safety.hs approvedLibraries).

The list is the trust boundary of the safe/unsafe line: a module not on it has
its public functions refused in every safe program that uses it
(docs/2026-10-15-SAFETY-ALLOW-LIST-REVIEW.md).  36 modules shipped off the list
before this check existed.  A new module is added to the list WITH a line in
that review page saying what its unsafe helpers are."""
import re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
listed = set(re.findall(r'"(std/[a-z0-9_]+\.fpr)"', (ROOT / 'compiler' / 'Safety.hs').read_text()))
modules = sorted('std/' + p.name for p in (ROOT / 'std').glob('*.fpr'))
missing = [m for m in modules if m not in listed]
stale = sorted(m for m in listed if not (ROOT / m).exists())
if missing or stale:
    for m in missing: print(f'{m}: not on the safety allow-list (compiler/Safety.hs approvedLibraries)')
    for m in stale: print(f'{m}: on the allow-list but no such file')
    sys.exit(1)
print(f'Safety allow-list: all {len(modules)} std modules listed, none stale: PASS')
