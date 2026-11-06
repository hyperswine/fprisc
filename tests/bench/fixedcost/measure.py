#!/usr/bin/env python3
"""Fixed-cost ceilings (docs/2026-11-06-FIXED-COSTS-PROPOSAL.md).

What would the emitted code cost if one fixed cost at a time were gone?
This builds tests/bench/fib.fpr and tests/bench/byteloop.fpr with `fpr build
--keep`, replaces the body of ONE hot function in the kept assembly by
hand-written variants, relinks each with the build's own link line (taken
from a logging --cc wrapper), checks the output and times them interleaved
beside C references.  It also times the default build against the existing
opt-in typed-IR modes on a few benchmarks.

The variants are hand edits of AArch64 Mach-O text, so this runs on arm64
macOS only.  Every pattern a variant relies on is asserted in the emitted
text first: when code generation changes, this fails rather than measuring
something else.  Two shortcuts make the variants experiments, not candidates:
the register-fuel forms reseed x27 instead of yielding (valid for one actor),
and trap paths are a `brk` (never reached by these inputs).

usage: tests/bench/fixedcost/measure.py [RUNS] > out.json     (default 11)
"""
from pathlib import Path
import json, os, platform, re, statistics, subprocess, sys, tempfile, time

ROOT = Path(__file__).resolve().parents[3]
BENCH = ROOT / 'tests/bench'
RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 11
OPTIN = ['SHALLOW_STACK', 'SHRINK_WRAP', 'ENTRY_ARGS', 'SPLIT_ENTRY', 'LOOP_MOTION', 'STRING_SCAN', 'EARLY_LOOPS']
OPTIN_BENCHES = ['fib', 'byteloop', 'unbox/option_loop', 'unbox/tree_sum', 'unbox/string_scan']

if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
    sys.exit('fixedcost/measure.py: the variants are arm64 macOS assembly; run it there')

def sh(args, env=None):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True, capture_output=True, timeout=900)
    assert p.returncode == 0, (args, p.stdout[-2000:], p.stderr[-2000:])
    return p

def need(text, pattern, what):
    m = re.search(pattern, text)
    assert m, f'emitted code changed: no {what} ({pattern!r})'
    return m

tmp = Path(tempfile.mkdtemp(prefix='fpr-fixedcost-'))
log = tmp / 'cc.log'
wrap = tmp / 'cc-log.sh'
wrap.write_text(f'#!/bin/sh\nprintf \'%s\\n\' "$*" >> "{log}"\nexec cc "$@"\n')
wrap.chmod(0o755)
BASE = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1')

def kept_build(name):
    """fpr build --keep through the logging wrapper: (assembly text, link argv, asm index, out index)."""
    env = dict(BASE, XDG_CACHE_HOME=str(tmp / 'cache'))
    out = sh([ROOT / 'fpr', 'build', '--keep', '--cc', wrap, BENCH / f'{name}.fpr', '--harts', '1', '-o', tmp / name.split('/')[-1]], env)
    kept = need(out.stdout + out.stderr, r'kept (\S+\.s)', 'kept assembly path').group(1)
    link = [l for l in log.read_text().strip().split('\n') if kept in l][-1].split()
    return Path(kept).read_text(), link, link.index(kept), link.index('-o') + 1

def relink(tag, text, link, asm_i, out_i):
    s = tmp / f'{tag}.s'; s.write_text(text)
    cmd = ['cc'] + link; cmd[asm_i + 1] = str(s); cmd[out_i + 1] = str(tmp / tag)
    sh(cmd)
    return tmp / tag

def splice(src, start, end, body):
    a = src.index(start); b = src.index(end)
    return src[:a] + body + src[b:]

# ---- fib: one call-heavy function --------------------------------------
fib_src, fib_link, fib_ai, fib_oi = kept_build('fib')
W = '_fpr_fn__x24worker_x2escalar_x2efib'
need(fib_src, re.escape(W) + ':', 'scalar fib worker')
need(fib_src, r'mov x9, #35\n', 'the literal 35 in main')
fib_src = fib_src.replace('mov x9, #35\n', 'mov x9, #40\n')          # fib 40: startup stops mattering
lo, room = re.findall(r'ldr x11, \[x9, #(\d+)\]', fib_src[fib_src.index(W + ':'):])[:2]
need(fib_src, r'ldur x10, \[x9, #0\]\n    sub x10, x10, #1\n    stur x10, \[x9, #0\]', 'memory fuel tick at hart cell 0')
CALL_IN = f'    asr x0, x19, #1\n    bl {W}\n    lsl x9, x0, #1\n    orr x0, x9, #1'
need(fib_src, re.escape(CALL_IN), 'general entry calling the worker')

STACK = f'''    mov x10, sp
    ldr x11, [x28, #{lo}]
    sub x10, x10, x11
    ldr x11, [x28, #{room}]
    cmp x10, x11
    b.lo 1f
    brk #2
1:
'''
FUEL = {'mem': '''    ldur x10, [x28, #0]
    sub x10, x10, #1
    stur x10, [x28, #0]
    cmp x10, #0
    b.gt 2f
    bl fpr_fuel_save_local
2:
''', 'reg': '''    subs x27, x27, #1
    b.le Lfuelreseed
''', 'poll': '''    ldur x10, [x28, #0]
    cmp x10, #0
    b.le Lfuelreseed
''', 'none': ''}

def fib_body(stack, fuel, shifted, shrink):
    k = 2 if shifted else 1  # shifted: the worker's Int is 2n, so a 64-bit overflow is the 63-bit one
    ovf = '    adds x0, x20, x0\n    b.vs Lovf\n' if shifted else \
          '    add x0, x20, x0\n    sbfx x10, x0, #0, #63\n    cmp x10, x0\n    b.ne Lovf\n'
    pro = '    stp x29, x30, [sp, #-32]!\n    stp x20, x19, [sp, #16]\n    mov x29, sp\n'
    epi = '    ldp x20, x19, [sp, #16]\n    ldp x29, x30, [sp], #32\n    ret\n'
    chk = (STACK if stack else '') + FUEL[fuel]
    if shrink:   # the n < 2 answer needs no frame
        head = f'{W}:\n{chk}Lgo:\n    cmp x0, #{2*k}\n    b.ge Lrec\n    ret\nLrec:\n{pro}    mov x19, x0\n'
    else:
        head = f'{W}:\n{pro}{chk}Lgo:\n    mov x19, x0\n    cmp x0, #{2*k}\n    b.ge Lrec\n{epi}Lrec:\n'
    return head + f'''    sub x0, x19, #{k}
    bl {W}
    mov x20, x0
    sub x0, x19, #{2*k}
    bl {W}
{ovf}{epi}Lfuelreseed:
    mov x27, #2000
    b Lgo
Lovf:
    brk #1
'''

FIB = [  # name, (stack check, fuel, shifted ints, shrink-wrapped leaf)
    ('clean selection and frame', (True, 'mem', False, False)),
    ('+ no stack check', (False, 'mem', False, False)),
    ('+ fuel counter in x27', (False, 'reg', False, False)),
    ('  (fuel as a polled flag instead)', (False, 'poll', False, False)),
    ('+ overflow on flags (shifted Int)', (False, 'reg', True, False)),
    ('+ frameless leaf path', (False, 'reg', True, True)),
    ('  (no fuel at all)', (False, 'none', True, True))]
jobs = {'fib': [('as emitted', relink('fib-emitted', fib_src, fib_link, fib_ai, fib_oi))]}
for i, (name, (stack, fuel, shifted, shrink)) in enumerate(FIB):
    text = splice(fib_src, W + ':', '# native-insns-v1: $worker.scalar.fib', fib_body(stack, fuel, shifted, shrink))
    if shifted:
        text = text.replace(CALL_IN, f'    sub x0, x19, #1\n    bl {W}\n    add x0, x0, #1')
    jobs['fib'].append((name, relink(f'fib-v{i}', text, fib_link, fib_ai, fib_oi)))
(tmp / 'fib.c').write_text('#include <stdio.h>\nstatic long fib(long n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }\n'
                           'int main(void) { printf("fib 35 = %ld\\n", fib(40)); return 0; }\n')
(tmp / 'fibchk.c').write_text('#include <stdio.h>\n__attribute__((noinline)) long fib(long n) { long r; if (n < 2) return n;\n'
                              '  if (__builtin_add_overflow(fib(n - 1), fib(n - 2), &r)) __builtin_trap(); return r; }\n'
                              'int main(void) { printf("fib 35 = %ld\\n", fib(40)); return 0; }\n')
sh(['cc', '-O2', '-o', tmp / 'fib-c', tmp / 'fib.c'])
sh(['cc', '-O1', '-o', tmp / 'fib-cchk', tmp / 'fibchk.c'])
jobs['fib'] += [('C -O2', tmp / 'fib-c'), ('C -O1, checked add, not inlined', tmp / 'fib-cchk')]

# ---- byteloop: one loop over a String ----------------------------------
by_src, by_link, by_ai, by_oi = kept_build('byteloop')
need(by_src, r'_fpr_fn_sumB:', 'sumB')
body0 = by_src[by_src.index('_fpr_fn_sumB:'):by_src.index('# native-insns-v1: sumB')]
tid = need(body0, r'ldursw x10, \[x19, #0\]\n    mov x11, #(\d+)', 'String type-id test in the loop').group(1)
need(body0, r'ldur x11, \[x10, #8\]', 'length at +8'); need(body0, r'ldrb w9, \[x9, #16\]', 'bytes at +16')
HEAD = f'''_fpr_fn_sumB:
    asr x1, x1, #1
    asr x2, x2, #1
    sub x3, x3, #1
    and x9, x0, #1
    cbnz x9, Lbad
    ldursw x9, [x0, #0]
    mov x11, #{tid}
    cmp x9, x11
    b.ne Lbad
    ldur x9, [x0, #8]
    cmp x1, #0
    b.lt Lbad
    cmp x2, x9
    b.gt Lbad
    add x10, x0, #16
'''
STEP = '''    ldrb w9, [x10, x1]
    adds x3, x3, x9, lsl #1
    b.vs Lbad
    add x1, x1, #1
'''
TAIL = '''Ldone:
    add x0, x3, #1
    ret
Lreseed:
    RESEED
    b Lgo
Lbad:
    brk #1
'''
CHUNK = '''Lloop:
    cmp x1, x2
    b.ge Ldone
    sub x12, x2, x1
    mov x13, #1024
    cmp x12, x13
    csel x12, x12, x13, lt
    subs x27, x27, x12
    b.le Lreseed
Lgo:
    add x12, x1, x12
'''
MEMTICK = 'Lloop:\n    ldur x11, [x28, #0]\n    sub x11, x11, #1\n    stur x11, [x28, #0]\n    cmp x11, #0\n    b.le Lreseed\n'
MEMSEED = 'mov x11, #2000\n    stur x11, [x28, #0]'
RAWSTEP = '''    ldrb w9, [x10, x1]
    add x3, x3, x9
    sbfx x11, x3, #0, #63
    cmp x11, x3
    b.ne Lbad
    add x1, x1, #1
'''
BYTE = [
    ('type test and bounds hoisted',     # the accumulator untagged, the emitted 63-bit fit check kept
     HEAD.replace('sub x3, x3, #1', 'asr x3, x3, #1') + MEMTICK + 'Lgo:\n    cmp x1, x2\n    b.ge Ldone\n' + RAWSTEP + '    b Lloop\n'
     + TAIL.replace('add x0, x3, #1', 'lsl x3, x3, #1\n    orr x0, x3, #1').replace('RESEED', MEMSEED)),
    ('+ overflow on flags (shifted Int)',
     HEAD + MEMTICK + 'Lgo:\n    cmp x1, x2\n    b.ge Ldone\n' + STEP + '    b Lloop\n' + TAIL.replace('RESEED', MEMSEED)),
    ('+ fuel counter in x27',
     HEAD + 'Lloop:\n    subs x27, x27, #1\n    b.le Lreseed\nLgo:\n    cmp x1, x2\n    b.ge Ldone\n' + STEP + '    b Lloop\n'
     + TAIL.replace('RESEED', 'mov x27, #2000')),
    ('+ fuel charged per 1,024-iteration chunk',
     HEAD + CHUNK + 'Linner:\n' + STEP + '    cmp x1, x12\n    b.lt Linner\n    b Lloop\n' + TAIL.replace('RESEED', 'mov x27, #2000')),
    ('+ overflow checked per chunk',
     HEAD + CHUNK + '    mov x14, #0\nLinner:\n    ldrb w9, [x10, x1]\n    add x14, x14, x9\n    add x1, x1, #1\n    cmp x1, x12\n'
     '    b.lt Linner\n    adds x3, x3, x14, lsl #1\n    b.vs Lbad\n    b Lloop\n' + TAIL.replace('RESEED', 'mov x27, #2000'))]
jobs['byteloop'] = [('as emitted', relink('byte-emitted', by_src, by_link, by_ai, by_oi))]
for i, (name, body) in enumerate(BYTE):
    jobs['byteloop'].append((name, relink(f'byte-v{i}', splice(by_src, '_fpr_fn_sumB:', '# native-insns-v1: sumB', body), by_link, by_ai, by_oi)))
sh(['cc', '-O2', '-fno-vectorize', '-fno-slp-vectorize', '-fno-unroll-loops', '-o', tmp / 'byte-cs', BENCH / 'c/byteloop.c'])
sh(['cc', '-O2', '-o', tmp / 'byte-c', BENCH / 'c/byteloop.c'])
jobs['byteloop'] += [('C -O2, scalar', tmp / 'byte-cs'), ('C -O2, vectorized', tmp / 'byte-c')]

# ---- tree_sum: the walk over a recursive type --------------------------
tr_src, tr_link, tr_ai, tr_oi = kept_build('unbox/tree_sum')
tot0 = tr_src[tr_src.index('_fpr_fn_total:'):tr_src.index('# native-insns-v1: total')]
hlo, hhi = need(tot0, r'ldur x9, \[x19, #0\]\n    movz x10, #(\d+)\n    movk x10, #(\d+), lsl #16', 'Leaf header test in total').groups()
leaf = need(tr_src, r'adrp x0, (Lnul_\d+_0)@PAGE', 'the static Leaf object').group(1)
slo, sroom = re.findall(r'ldr x11, \[x9, #(\d+)\]', tot0)[:2]
TSTACK = STACK.replace(f'#{lo}]', f'#{slo}]').replace(f'#{room}]', f'#{sroom}]')
TEST = {'checked': f'''    tbnz x0, #0, Lnode
    ldur x9, [x0, #0]
    movz x10, #{hlo}
    movk x10, #{hhi}, lsl #16
    cmp x9, x10
    b.ne Lnode
''', 'trusted': f'''    adrp x9, {leaf}@PAGE
    add x9, x9, {leaf}@PAGEOFF
    cmp x0, x9
    b.ne Lnode
'''}

def total_body(stack, fuel, test):
    fit = '    sbfx x10, {0}, #0, #63\n    cmp x10, {0}\n    b.ne Lovf\n'
    epi = '    ldp x20, x19, [sp, #16]\n    ldp x29, x30, [sp], #32\n    ret\n'
    return f'''_fpr_fn_total:
    stp x29, x30, [sp, #-32]!
    stp x20, x19, [sp, #16]
    mov x29, sp
{TSTACK if stack else ''}{FUEL[fuel]}Lgo:
{TEST[test]}    mov x0, #1
{epi}Lnode:
    mov x19, x0
    ldur x0, [x19, #8]
    bl _fpr_fn_total
    ldur x9, [x19, #16]
    asr x20, x0, #1
    add x20, x20, x9, asr #1
{fit.format('x20')}    ldur x0, [x19, #24]
    bl _fpr_fn_total
    add x0, x20, x0, asr #1
{fit.format('x0')}    lsl x0, x0, #1
    orr x0, x0, #1
{epi}Lfuelreseed:
    mov x27, #2000
    b Lgo
Lovf:
    brk #1
'''

TREE = [('walk: clean selection and frame', (True, 'mem', 'checked')),
        ('walk: + Leaf test trusts the static type', (True, 'mem', 'trusted')),
        ('walk: + no stack check, fuel counter in x27', (False, 'reg', 'trusted'))]
jobs['tree_sum'] = [('as emitted', relink('tree-emitted', tr_src, tr_link, tr_ai, tr_oi))]
for i, (name, (stack, fuel, test)) in enumerate(TREE):
    text = splice(tr_src, '_fpr_fn_total:', '# native-insns-v1: total', total_body(stack, fuel, test))
    jobs['tree_sum'].append((name, relink(f'tree-v{i}', text, tr_link, tr_ai, tr_oi)))
# the builder: the same allocation sequence, copied verbatim from the emitted text
bld0 = tr_src[tr_src.index('_fpr_fn_build:'):tr_src.index('# native-insns-v1: build')]
alloc = need(bld0, r'(?s).*bl _fpr_fn_build\n(    ldr x16, \[x28.*?    mov x0, x9\n)    ldp x20, x19', 'inline allocation of Node in build').group(1)
need(alloc, r'stur x22, \[x9, #8\]\n    stur x20, \[x9, #16\]\n    stur x0, \[x9, #24\]', 'Node fields from x22, x20, x0')
BUILD = f'''_fpr_fn_build:
    stp x29, x30, [sp, #-48]!
    stp x20, x19, [sp, #16]
    stp x22, x21, [sp, #32]
    mov x29, sp
{TSTACK}{FUEL['mem']}    cmp x0, #1
    b.ne Lbnode
    adrp x0, {leaf}@PAGE
    add x0, x0, {leaf}@PAGEOFF
    b Lbret
Lbnode:
    mov x20, x1
    subs x19, x0, #2
    b.vs Lbovf
    adds x21, x20, x20
    b.vs Lbovf
    sub x21, x21, #1
    mov x0, x19
    mov x1, x21
    bl _fpr_fn_build
    mov x22, x0
    adds x1, x21, #2
    b.vs Lbovf
    mov x0, x19
    bl _fpr_fn_build
{alloc}Lbret:
    ldp x22, x21, [sp, #32]
    ldp x20, x19, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lbovf:
    brk #1
'''
text = splice(tr_src, '_fpr_fn_total:', '# native-insns-v1: total', total_body(False, 'reg', 'trusted'))
text = splice(text, '_fpr_fn_build:', '# native-insns-v1: build', BUILD)
jobs['tree_sum'].append(('+ build: checks folded and shared, clean selection', relink('tree-build', text, tr_link, tr_ai, tr_oi)))
(tmp / 'tree.c').write_text('''#include <stdio.h>
#include <stdlib.h>
typedef struct T { struct T *l; long k; struct T *r; } T;
static char *hp;
static T *build(long d, long k) { if (d == 0) return 0; T *t = (T *)hp; hp += sizeof(T);
  t->l = build(d - 1, 2 * k); t->k = k; t->r = build(d - 1, 2 * k + 1); return t; }
static long total(T *t) { return t ? total(t->l) + t->k + total(t->r) : 0; }
int main(void) { char *heap = malloc((size_t)32 << 20); long acc = 0;
  for (int r = 0; r < 10; r++) { hp = heap; acc += total(build(20, 1)); }
  printf("tree_sum %ld\\n", acc); return 0; }
''')
sh(['cc', '-O2', '-o', tmp / 'tree-c', tmp / 'tree.c'])
jobs['tree_sum'].append(('C -O2, bump allocator reset per round', tmp / 'tree-c'))

# ---- default build against the existing opt-in typed-IR modes ----------
for b in OPTIN_BENCHES:
    n = b.split('/')[-1]; rows = []
    for tag, extra in [('default', {}), ('all opt-in modes', {f'FPR_TYPED_IR_{f}': '1' for f in OPTIN})]:
        exe = tmp / f'opt-{n}-{len(extra)}'
        sh([ROOT / 'fpr', 'build', BENCH / f'{b}.fpr', '--harts', '1', '-o', exe], dict(BASE, XDG_CACHE_HOME=str(tmp / f'cache-{len(extra)}'), **extra))
        rows.append((tag, exe))
    jobs['optin:' + n] = rows
(tmp / 'empty.fpr').write_text('main = print "empty".\n')
sh([ROOT / 'fpr', 'build', tmp / 'empty.fpr', '--harts', '1', '-o', tmp / 'empty'], dict(BASE, XDG_CACHE_HOME=str(tmp / 'cache')))
(tmp / 'empty.c').write_text('#include <stdio.h>\nint main(void) { puts("empty"); return 0; }\n')
sh(['cc', '-O2', '-o', tmp / 'empty-c', tmp / 'empty.c'])
jobs['startup'] = [('fpr', tmp / 'empty'), ('C', tmp / 'empty-c')]

# ---- run interleaved; every row of a group must print the same thing ---
samples = {g: {n: [] for n, _ in rows} for g, rows in jobs.items()}
for _ in range(RUNS):
    for g, rows in jobs.items():
        want = None
        for n, exe in rows:
            t0 = time.perf_counter(); p = subprocess.run([str(exe)], capture_output=True, text=True, env=BASE, timeout=600)
            samples[g][n].append(time.perf_counter() - t0)
            want = want or p.stdout
            assert p.returncode == 0 and p.stdout == want, (g, n, p.returncode, p.stdout, p.stderr[-400:])
commit = sh(['git', 'rev-parse', '--short', 'HEAD']).stdout.strip()
print(json.dumps({'platform': platform.platform(), 'runs': RUNS, 'commit': commit,
                  'cc': sh(['cc', '--version']).stdout.split('\n')[0],
                  'ms': {g: [{'variant': n, 'min': round(min(v) * 1000, 1), 'median': round(statistics.median(v) * 1000, 1)}
                             for n, v in rows.items()] for g, rows in samples.items()}}, indent=1))
