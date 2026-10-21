#!/usr/bin/env python3
"""M2 of the typed IR (docs/2026-10-21-TYPED-IR-M2-A64.md): the direct
native backends behind FPR_TYPED_IR_BACKEND.  The selected-instruction
vocabulary, placement, layout, bound analysis and the A64 pipeline are
checked in tests/SelectedIR.hs; then the real pipeline on the matching native host:

- the module fixture tests/typed_ir/scalarlib.fpr goes through the new
  backend as a whole unit (strict mode proves it) under a legacy root, and
  every call answers what the legacy binary answers AND what independent
  arithmetic says, traps included, word for word;
- the C harness tests/typed_ir/tir_probe.c calls native functions through
  their function values and is called back by them;
- a deep non-tail recursion crosses stack-segment boundaries;
- one and four harts; off/on/off/on/off cache transitions with distinct
  unit identities; a strict-mode failure names the function;
- mixed (per-function) mode on the M1 root fixture;
- the ELF (a64) and the Mach-O TLV (a64mac without --base) variants
  assemble with clang where it has the target;
- the backend off leaves no trace in the emission; on, every native
  function carries a finite native-insns-v1 bound and no legacy label.
No performance claim is made or measured here."""
import argparse, os, platform, re, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, 'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT)}
for k in ('FPR_FOREIGN', 'FPR_TYPED_IR', 'FPR_TYPED_IR_BACKEND', 'FPR_TYPED_IR_STRICT'):
    ENV.pop(k, None)
for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig', '/usr/local/opt/libarchive/lib/pkgconfig'):
    if Path(keg).is_dir():
        ENV['PKG_CONFIG_PATH'] = keg + ':' + ENV.get('PKG_CONFIG_PATH', '')
        break

def run(args, env=ENV, expected=0, timeout=600):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    assert p.returncode == expected, (args, p.returncode, p.stdout[-3000:], p.stderr[-3000:])
    return p.stdout + p.stderr

def outcome(exe, fn, args):
    p = subprocess.run([str(exe), fn, *map(str, args)], capture_output=True, text=True, timeout=120)
    out = p.stdout + p.stderr
    if p.returncode == 0:
        return ('value', out.strip())
    m = re.search(r'PANIC \[actor 0\]: (.*) \*\*\*', out)
    assert m, (fn, args, out)
    return ('trap', m.group(1))

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--backend', choices=('a64', 'x64'), required=True)
parser.add_argument('--portable-only', action='store_true',
                    help='run shared selected-IR checks without native AArch64 execution')
parser.add_argument('--require-execution', action='store_true',
                    help='fail if native runtime execution is unavailable instead of accepting a host skip')
args = parser.parse_args()
BACKEND = args.backend
NATIVE_HOST = (platform.machine() in ('arm64', 'aarch64') if BACKEND == 'a64' else
               platform.machine() in ('x86_64', 'AMD64') and platform.system() == 'Linux')
run(['make', 'fpr'])
ghc = ['cabal', 'exec', '--', 'runghc'] if shutil.which('cabal') else ['runghc']
print(run([*ghc, '-w', '-icompiler', 'tests/SelectedIR.hs']), end='', flush=True)
if args.portable_only or not NATIVE_HOST:
    if args.require_execution:
        raise SystemExit(f'Typed IR M2 {BACKEND}: required native execution unavailable or disabled')
    print(f'Typed IR M2 {BACKEND} execution: SKIP (portable-only requested or nonmatching native host); shared selected-IR checks passed')
    raise SystemExit(0)

MOD, LIB, PROBE = 'tests/typed_ir/scalar_mod.fpr', 'tests/typed_ir/scalarlib.fpr', 'tests/typed_ir/tir_probe.c'
LIB_FNS = ['fib', 'sum', 'addovf', 'mulovf', 'divz', 'even', 'odd', 'clamp', 'boolEq', 'boolNe', 'boolResult', 'cbSum', 'cbTail', 'deep', 'swapLoop',
           'shl', 'shr', 'bits', 'mix', 'rot9', 'callWide', 'tailWide', 'rot64', 'call64',
           'answer', 'useCaf', 'pos', 'tick', 'viaFun', 'viaHal']
INT_MIN, INT_MAX = -(1 << 62), (1 << 62) - 1
def overflow(a, op, b):
    return ('trap', f'Int overflow: {a} {op} {b} does not fit an Int ({INT_MIN}..{INT_MAX}); I64 is the type that wraps')
# the shifts as runtime/bits.c states them: the 64-bit shift of the untagged
# value (logical to the right), then the low 63 bits sign-extended
def wrap63(v):
    m = v % (1 << 63)
    return m - (1 << 63) if m > INT_MAX else m
def shl(a, n):
    return ('trap', 'BITSHIFTL: shift must be 0..63') if not 0 <= n <= 63 else ('value', str(wrap63(a << n)))
def shr(a, n):
    return ('trap', 'BITSHIFTR: shift must be 0..63') if not 0 <= n <= 63 else ('value', str(wrap63((a % (1 << 64)) >> n)))
# the wide rotations: n turns of the argument list, then the weighted sum
def rot(n, args):
    args = list(args)
    for _ in range(n):
        args = args[1:] + args[:1]
    return sum((i + 1) * a for i, a in enumerate(args))
def mix(n, acc):
    while n:
        acc = wrap63(acc << 5) ^ wrap63((acc % (1 << 64)) >> 2)
        acc += n
        assert INT_MIN <= acc <= INT_MAX
        n -= 1
    return ('value', str(acc))
# independent expected values: arithmetic, not a compiler (the most negative
# Int by -1 is covered by tests/SelectedIR.hs's fit check and the worker suite;
# the fixture's parseInt does not read INT_MIN)
EXPECTED = {
    ('fib', (20,)): ('value', '6765'),
    ('sum', (1000, 0)): ('value', '500500'),
    ('sum', (3000000, 0)): ('value', str(3000000 * 3000001 // 2)),
    ('addovf', (INT_MAX, 1)): overflow(INT_MAX, '+', 1),
    ('addovf', (-5, 7)): ('value', '2'),
    ('mulovf', (3037000500, 3037000500)): overflow(3037000500, '*', 3037000500),
    ('mulovf', (1 << 31, 1 << 31)): overflow(1 << 31, '*', 1 << 31),
    ('mulovf', (123456789, -1000)): ('value', '-123456789000'),
    ('mulovf', (65536, 65536)): ('value', '4294967296'),
    ('mulovf', (2147483647, 3)): ('value', '6442450941'),
    ('mulovf', (-2147483649, 2147483647)): ('value', str(-2147483649 * 2147483647)),
    ('mulovf', (7, 0)): ('value', '0'),
    ('divz', (7, 0)): ('trap', 'division by zero'),
    ('divz', (7, 2)): ('value', '3'),
    ('divz', (-7, 2)): ('value', '-3'),
    ('even', (11,)): ('value', '0'),
    ('even', (10,)): ('value', '1'),
    ('clamp', (50, 0, 10)): ('value', '20'),
    ('clamp', (-5, 0, 10)): ('value', '0'),
    ('clamp', (5, 0, 10)): ('value', '10'),
    ('boolResult', (3, 1)): ('value', '10'),
    ('boolResult', (3, 0)): ('value', '1'),
    ('boolResult', (0, -1)): ('value', '1'),
    ('cbSum', (10,)): ('value', str((2 * 10 + 1) + (2 * 11 + 1))),
    ('cbTail', (7,)): ('value', str(2 * 21 + 1)),
    ('swapLoop', (7, 1, 2)): ('value', '2001'),
    ('swapLoop', (8, 1, 2)): ('value', '1002'),
    ('shl', (1, 3)): shl(1, 3),
    ('shl', (1, 62)): shl(1, 62),
    ('shl', (3, 63)): shl(3, 63),
    ('shl', (-1, 1)): shl(-1, 1),
    ('shl', (1, 64)): shl(1, 64),
    ('shl', (1, -1)): shl(1, -1),
    ('shr', (-1, 1)): shr(-1, 1),
    ('shr', (-8, 1)): shr(-8, 1),
    ('shr', (1024, 3)): shr(1024, 3),
    ('shr', (5, 63)): shr(5, 63),
    ('shr', (5, 0)): shr(5, 0),
    ('shr', (5, 64)): shr(5, 64),
    ('shr', (5, -7)): shr(5, -7),
    ('bits', (12, 10)): ('value', str((12 & 10) * 1000000 + (12 | 10) * 1000 + (12 ^ 10))),
    ('bits', (-1, 77)): ('value', str((-1 & 77) * 1000000 + (-1 | 77) * 1000 + (-1 ^ 77))),
    ('mix', (1000, 7)): mix(1000, 7),
    ('rot9', (0,)): ('value', str(rot(0, range(1, 10)))),
    ('rot9', (4,)): ('value', str(rot(4, range(1, 10)))),
    ('rot9', (100000,)): ('value', str(rot(100000, range(1, 10)))),
    ('callWide', (3,)): ('value', str(rot(3, range(1, 10)) + rot(4, range(1, 10)))),
    ('tailWide', (5,)): ('value', str(rot(5, range(9, 0, -1)))),
    ('call64', (0,)): ('value', str(rot(0, range(1, 64)) + 1)),
    ('call64', (7,)): ('value', str(rot(7, range(1, 64)) + 1)),
    ('call64', (200000,)): ('value', str(rot(200000, range(1, 64)) + 1)),
    ('useCaf', (8,)): ('value', '50'),
    ('pos', (3,)): ('value', '1'),
    ('pos', (-3,)): ('value', '1' if False else '0'),
    ('tick', ()): ('value', '7'),
    ('viaFun', (20,)): ('value', '6765'),
    ('viaHal', (20,)): ('value', '41'),
    ('cfib', (22,)): ('value', '17711'),
    ('csum', (100, 5)): ('value', '5055'),
    ('caddovf', (INT_MAX, 1)): overflow(INT_MAX, '+', 1),
    ('ccbSum', (4,)): ('value', str((2 * 4 + 1) + (2 * 5 + 1))),
}
CALLS = list(EXPECTED)

def notes_of(text):
    return [l for l in text.splitlines() if l.startswith('typed-ir-backend: ')]

with tempfile.TemporaryDirectory(prefix=f'fpr-typed-ir-{BACKEND}-') as d:
    tmp = Path(d)
    # a private build cache: the backend's notes are printed only for units
    # compiled in this invocation, and the cache transitions below start empty
    ENV['XDG_CACHE_HOME'] = str(tmp / 'cache')
    legacy_exe, native_exe = tmp / 'mod-legacy', tmp / 'mod-native'
    run(['./fpr', 'build', MOD, '--with', PROBE, '-o', legacy_exe])
    legacy = {k: outcome(legacy_exe, *k) for k in CALLS}
    for k, want in EXPECTED.items():
        assert legacy[k] == want, ('legacy', k, legacy[k], want)
    # whole-unit selection of the module under strict mode: every function
    # of scalarlib must take the native backend
    strict = {**ENV, 'FPR_TYPED_IR_BACKEND': '1', 'FPR_TYPED_IR_STRICT': ','.join(LIB_FNS)}
    log = run(['./fpr', 'build', MOD, '--with', PROBE, '-o', native_exe, '-v'], strict)
    notes = notes_of(log)
    unit_lines = [l for l in notes if re.match(r'typed-ir-backend: native (\d+)/(\d+) functions \(whole unit\)', l)]
    assert unit_lines, (notes[:5], log[-1500:])
    m = re.match(r'typed-ir-backend: native (\d+)/(\d+)', unit_lines[0])
    assert m.group(1) == m.group(2), unit_lines
    native_names = {l.split()[1] for l in notes if ' native (frame ' in l}
    for fn in LIB_FNS:
        assert any(n.startswith(fn + '@') for n in native_names), (fn, sorted(native_names))
    assert all(' native-insns-v1 segmax=' in l and 'UNBOUNDED' not in l for l in notes if ' native (frame ' in l), notes
    assert any('whole-unit fallback' in l for l in notes), 'the root with main should fall back as a unit'
    for k, want in EXPECTED.items():
        got = outcome(native_exe, *k)
        assert got == want == legacy[k], (k, got, want, legacy[k])
    # the string object of the dead arm's reason is in the unit, once
    unit_s = next(Path(ENV['XDG_CACHE_HOME']).glob('fpr/build/units/u-*tirbe*.s'))
    unit_t = unit_s.read_text()
    assert unit_t.count('Ltirstr_') >= 2 and unit_t.count('.long 9000') >= 1, unit_s
    # the dead arm reached (C hands tick an Int): the native trap is the
    # legacy trap, text for text
    dead_legacy, dead_native = outcome(legacy_exe, 'tickBad', [5]), outcome(native_exe, 'tickBad', [5])
    assert dead_legacy == ('trap', 'case: no matching pattern; arms were [PCon "Unit" []]'), dead_legacy
    assert dead_native == dead_legacy, (dead_native, dead_legacy)
    # deep recursion across stack segments: the same answer, and the
    # harness saw the native frames in more than one segment
    for depth in (100, 100000):
        want = str(depth + 1)
        lv, nv = outcome(legacy_exe, 'deep', [depth]), outcome(native_exe, 'deep', [depth])
        assert lv[0] == nv[0] == 'value' and lv[1].split()[0] == nv[1].split()[0] == want, (depth, lv, nv)
        segs = int(nv[1].split()[1])
        assert (segs >= 2) == (depth == 100000), (depth, nv)
    print(f'whole unit: scalarlib {m.group(1)}/{m.group(2)} native under strict mode; {len(CALLS)} calls equal the legacy binary and independent arithmetic; C calls native code and is called back; deep recursion crossed {segs} segments')
    # one and four harts
    for harts in ('1', '4'):
        exe = tmp / f'mod-h{harts}'
        run(['./fpr', 'build', MOD, '--with', PROBE, '--harts', harts, '-o', exe], strict)
        for k in (('fib', (22,)), ('sum', (3000000, 0)), ('divz', (7, 0)), ('cfib', (22,)), ('cbSum', (10,))):
            got = outcome(exe, *k)
            want = EXPECTED.get(k, ('value', '17711'))
            assert got == want, (harts, k, got)
    print('one and four harts: PASS')
    # cache transitions: off/on/off/mixed/off, each with its own unit identity
    seen = []
    for mode in ('', '1', '', 'mixed', ''):
        env = {**ENV, 'FPR_TYPED_IR_BACKEND': mode} if mode else dict(ENV)
        exe = tmp / 'mod-t'
        log = run(['./fpr', 'build', MOD, '--with', PROBE, '-o', exe, '-v'], env)
        tags = {re.search(r'-(g\d+[^/ ]*)\.s', l).group(1) for l in log.splitlines() if re.search(r'units/u-[0-9a-f]+-[^ ]*\.s', l)}
        assert len(tags) == 1, (mode, tags)
        tag = tags.pop()
        assert ('tirbe' in tag) == bool(mode) and ('mixed' in tag) == (mode == 'mixed'), (mode, tag)
        seen.append(tag)
        for k in (('fib', (20,)), ('cbSum', (10,)), ('divz', (7, 0))):
            assert outcome(exe, *k) == EXPECTED[k], (mode, k)
    assert seen[0] == seen[2] == seen[4] and len({seen[1], seen[3], seen[0]}) == 3, seen
    print('cache transitions off/on/off/mixed/off: PASS')
    # strict mode names the function that fell back
    p = subprocess.run(['./fpr', 'build', 'tests/typed_ir/scalar.fpr', '-o', tmp / 'x'], cwd=ROOT, env={**ENV, 'FPR_TYPED_IR_BACKEND': 'mixed', 'FPR_TYPED_IR_STRICT': 'fib,main'}, capture_output=True, text=True, timeout=600)
    assert p.returncode != 0 and 'typed-ir strict' in p.stderr and '\n  main: ' in p.stderr, (p.returncode, p.stderr[-800:])
    # mixed mode on the M1 root fixture: main legacy, the scalar functions native
    mixed = {**ENV, 'FPR_TYPED_IR_BACKEND': 'mixed', 'FPR_TYPED_IR_STRICT': 'fib,sum,addovf,divz,even,odd,clamp,boolEq,boolNe,boolResult'}
    mexe = tmp / 'scalar-mixed'
    log = run(['./fpr', 'build', 'tests/typed_ir/scalar.fpr', '-o', mexe, '-v'], mixed)
    assert any(re.match(r'typed-ir-backend: native \d+/22 functions \(per-function\)', l) for l in notes_of(log)), notes_of(log)[:3]
    for k, want in [(('fib', (20,)), ('value', '6765')), (('sum', (1000, 0)), ('value', '500500')), (('addovf', (INT_MAX, 1)), overflow(INT_MAX, '+', 1)),
                    (('divz', (7, 0)), ('trap', 'division by zero')), (('even', (11,)), ('value', '0')), (('clamp', (50, 0, 10)), ('value', '20')),
                    (('boolResult', (3, 1)), ('value', '10')), (('boolResult', (3, 0)), ('value', '1'))]:
        assert outcome(mexe, *k) == want, (k, outcome(mexe, *k))
    print('mixed mode on the M1 fixture: PASS')
    # the emission: off leaves no trace; on carries the native metric and never the legacy label
    off_s, on_s = tmp / 'off.s', tmp / 'on.s'
    run(['./fpr', f'--target={"a64mac" if BACKEND == "a64" else "x64"}', f'--prelude={ROOT}/core/prelude.fpr', 'tests/typed_ir/scalar.fpr', off_s])
    run(['./fpr', f'--target={"a64mac" if BACKEND == "a64" else "x64"}', f'--prelude={ROOT}/core/prelude.fpr', 'tests/typed_ir/scalar.fpr', on_s], {**ENV, 'FPR_TYPED_IR_BACKEND': 'mixed'})
    off_t, on_t = off_s.read_text(), on_s.read_text()
    assert f'typed-ir {BACKEND}' not in off_t and 'native-insns-v1' not in off_t
    native_fns = re.findall(rf'^# fn (\S+) \(arity \d+\) typed-ir {BACKEND}', on_t, re.M)
    assert len(native_fns) == 14, native_fns
    for fn in native_fns:
        body = on_t[on_t.index(f'# fn {fn} (arity'):]
        body = body[:body.index('\n\n')]
        assert f'# native-insns-v1: {fn} segmax=' in body and 'UNBOUNDED' not in body and '# wcet:' not in body, fn
    assert on_t.count('# wcet: ') == len(re.findall(r'^# fn ', on_t, re.M)) - 14, 'legacy functions keep their legacy bound'
    # FPRC_WCET reports the two metrics apart
    wlog = run(['./fpr', f'--target={"a64mac" if BACKEND == "a64" else "x64"}', f'--prelude={ROOT}/core/prelude.fpr', 'tests/typed_ir/scalar.fpr', tmp / 'w.s'], {**ENV, 'FPR_TYPED_IR_BACKEND': 'mixed', 'FPRC_WCET': '1'})
    assert '[native-insns-v1] root: 14 function(s)' in wlog and 'not in this bound' in wlog, wlog[-1500:]
    # the Mach-O TLV variant (a64mac without --base) and the ELF variant assemble
    clang = shutil.which('clang')
    if clang and BACKEND == 'a64':
        run([clang, '-target', 'arm64-apple-macos', '-c', on_s, '-o', tmp / 'on.o'])
        assert '_fpr_posix_hart@TLVPPAGE' in on_t
        elf_s = tmp / 'elf.s'
        run(['./fpr', '--target=a64', f'--prelude={ROOT}/core/prelude.fpr', 'tests/typed_ir/scalar.fpr', elf_s], {**ENV, 'FPR_TYPED_IR_BACKEND': 'mixed'})
        elf_t = elf_s.read_text()
        assert 'tprel_hi12:fpr_posix_hart' in elf_t and len(re.findall(r'^# fn \S+ \(arity \d+\) typed-ir a64', elf_t, re.M)) == 14
        p = subprocess.run([clang, '-target', 'aarch64-unknown-linux-gnu', '-c', elf_s, '-o', tmp / 'elf.o'], capture_output=True, text=True)
        if p.returncode == 0:
            print('Mach-O TLV and ELF variants assemble with clang: PASS')
        else:
            assert 'error: unable to create target' in p.stderr or 'no such target' in p.stderr, p.stderr[-800:]
            print('Mach-O TLV variant assembles; ELF: SKIP (clang has no AArch64 ELF target here)')
    elif clang:
        run([clang, '-target', 'x86_64-unknown-linux-gnu', '-c', on_s, '-o', tmp / 'on.o'])
        assert '%fs:fpr_posix_hart@tpoff' in on_t
        print('x86-64 ELF with real TLS relocations assembles: PASS')
    else:
        print('assembly variants: SKIP (no clang)')
print(f'Typed IR M2 ({BACKEND}): selected vocabulary, whole-unit and mixed native emission with exact results and traps, C interoperability, segment growth, harts, cache transitions, strict mode, bounds: PASS')
