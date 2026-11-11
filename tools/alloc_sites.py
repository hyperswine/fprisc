#!/usr/bin/env python3
"""Resolve an FPR_ALLOC_SITES table (a probe build run with
FPR_ALLOC_SITES=<file>) into allocation counts by FP-RISC function.

  python3 tools/alloc_sites.py EXE SITES [--top 30] [--chains]

Each allocation is charged to the first frame of its chain that is not the
runtime (fpr_*, alloc_*, site_note and other C helpers in runtime/ and
machine/), so a std/list cell built by List.map shows as List.map's worker."""
import argparse, collections, re, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument('exe'); ap.add_argument('sites')
ap.add_argument('--top', type=int, default=30)
ap.add_argument('--chains', action='store_true', help='show whole chains, not first FP-RISC frames')
a = ap.parse_args()

lines = open(a.sites).read().split('\n')
head = lines[0].split()
main_rt = int(head[1], 16)
nm = subprocess.run(['nm', a.exe], capture_output=True, text=True).stdout
main_st = next(int(l.split()[0], 16) for l in nm.split('\n') if l.endswith(' _main'))
slide = main_rt - main_st
rows = []
addrs = set()
for l in lines[1:]:
    if not l.strip(): continue
    f = l.split()
    chain = [int(x, 16) for x in f[2:]]
    rows.append((int(f[0]), int(f[1]), chain))
    addrs.update(x for x in chain if x)
addrs = sorted(addrs)
names = {}
for i in range(0, len(addrs), 500):
    part = addrs[i:i + 500]
    out = subprocess.run(['atos', '-o', a.exe, '-l', hex(0x100000000 + slide)] + [hex(x) for x in part],
                         capture_output=True, text=True).stdout.split('\n')
    for x, n in zip(part, out):
        names[x] = re.sub(r' \(in [^)]*\)', '', n).split(' + ')[0].strip()
RT = re.compile(r'^_?(fpr_(?!fn_)|alloc|site_note|bucket_|region_|dc_|deep_|copy_|str_|vec_|hal_|bump_|0x)')
def demangle(n):
    if n.startswith('fpr_fn_'):
        n = re.sub(r'_x([0-9a-f]{2})', lambda m: chr(int(m[1], 16)), n[7:])
    return re.sub(r'@[0-9a-f]{16}', '', n)
def charged(chain):
    for x in chain:
        n = names.get(x, hex(x))
        if x and not RT.match(n): return demangle(n)
    return names.get(chain[-1], '?') if chain else '?'
tot = collections.Counter(); byt = collections.Counter()
for c, b, chain in rows:
    k = ' <- '.join(demangle(names.get(x, hex(x))) for x in chain if x) if a.chains else charged(chain)
    tot[k] += c; byt[k] += b
allc = sum(tot.values())
print(f'{allc} allocations, dropped {head[3]}')
for k, c in tot.most_common(a.top):
    print(f'{c:>11} {100 * c / allc:5.1f}% {byt[k] / 1e6:9.1f} MB  {k}')
