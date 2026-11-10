#!/usr/bin/env python3
"""Link-tier experiment: RawWord fields on one non-escaping type (Pair).

The same observations are made on a Pair of Int (managed fields) and on a
Pair of Word (RawWord fields, the representation a type specialiser would pick
for `Pair Int Int`), each in its own builtin ARC program on QEMU RV64. Checks:
identical output and no live allocation afterwards for both; the raw program
retains and releases less; one program that mixes both pairs through a
shared List keeps raw Word fields, with C2 clones by default and with none
under FPR_NO_TYPE_SPEC=1; and the same program with its fields left as
variables of non-parametric types boxes each Word (uniform slots)."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)

# Pair is declared parametric. `Pair = Type (Pair a b)` leaves a and b as type
# variables of a non-parametric type, which are uniform slots since the generic
# tagged fallback (docs/2026-11-04-ZERO-OVERHEAD-COMPLETION.md): a Word stored
# there is boxed, two extra cells a pair, and 50 pairs no longer fit the heap.
TEMPLATE = '''# Pair experiment ({name}): identical observations on {desc}.
Pair a b = Type (Pair a b).
check b = case b of True -> Unit | False -> error "pair observation failed".
leaks = Mem.liveAllocations Unit.
mk a b = {mk}.
swap p = case p of Pair a b -> Pair b a.
total p = case p of Pair a b -> {total}.
shared p = total p + total (swap p).
build n = case n == 0 of True -> [] | False -> Pair {a} {b} :: build (n - 1).
tot xs = case xs of [] -> 0 | p :: r -> total p + tot r.
step p = case p of Pair a b -> Pair b {step}.
loop i p = case i == 0 of True -> total p | False -> loop (i - 1) (step p).
main =
  base = leaks;
  _ = print (str (total (mk 3 4)));
  _ = print (str (shared (mk 5 6)));
  _ = print (str (tot (build 50)));
  _ = print (str (mk 1 2 == mk 1 2));
  _ = print (str (mk 1 2 == mk 2 1));
  _ = print (str (loop 1000 (mk 0 1)));
  _ = check (leaks == base);
  print "PAIR HOLDS".
'''

INT = dict(name='Int fields', desc='managed fields', mk='Pair a b', total='a + b',
           a='n', b='(n * 2)', step='((a + b) - ((a + b) / 1000003) * 1000003)')
WORD = dict(name='RawWord fields', desc='RawWord fields',
            mk='Pair (Word.fromInt a) (Word.fromInt b)', total='Word.toInt (Word.add a b)',
            a='(Word.fromInt n)', b='(Word.fromInt (n * 2))',
            step='(Word.fromInt (Word.toInt (Word.add a b) - (Word.toInt (Word.add a b) / 1000003) * 1000003))')

MIXED = '''IPair a b = Type (IPair a b).
WPair a b = Type (WPair a b).
build n = case n == 0 of True -> [] | False -> IPair n n :: build (n - 1).
buildW n = case n == 0 of True -> [] | False -> WPair (Word.fromInt n) (Word.fromInt n) :: buildW (n - 1).
main = _ = build 3; _ = buildW 3; Unit.
'''

# The same program with the fields left as variables of non-parametric types:
# uniform slots, so each Word is boxed on the way in.
UNIFORM = MIXED.replace('IPair a b = Type', 'IPair = Type').replace('WPair a b = Type', 'WPair = Type')


def run(args, expected=0, timeout=120):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if p.returncode != expected:
        raise AssertionError(f'{args}: exit {p.returncode}\n{p.stdout[-2000:]}\n{p.stderr[-2000:]}')
    return p


def fn_bodies(asm, name):
    """Every emitted body of a source function: its own symbol, or a worker
    the compiler split from it (`$worker.ret2.$product.swap`). A function
    inlined into its callers has no body of its own and is counted there."""
    return re.findall(r'^# fn (?:\S*\.)?' + re.escape(name) + r' .*?(?=^# native-insns-v1)', asm, re.M | re.S)


def ownership_calls(asm):
    total = 0
    for name in ('total', 'swap', 'build', 'tot', 'step', 'loop'):
        bodies = fn_bodies(asm, name)
        # the recursive functions cannot be inlined away
        assert bodies or name not in ('build', 'tot', 'loop'), name
        total += sum(len(re.findall(r'call fpr_fn__x24arc_x2e(?:retain|release)\b', body)) for body in bodies)
    return total


def main():
    run(['make', 'fpr'], timeout=300)
    with tempfile.TemporaryDirectory(prefix='fpr-pair-raw-') as temp:
        tmp = Path(temp)
        seen = {}
        calls = {}
        for label, params in (('int', INT), ('word', WORD)):
            source = tmp / f'{label}.fpr'
            source.write_text(TEMPLATE.format(**params))
            build = tmp / label
            image = tmp / f'{label}.elf'
            run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', 'BUILTIN_HEAP_BYTES=16384',
                 f'PROG={source}', f'BUILD={build}', f'IMAGE={image}'], timeout=300)
            out = run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic',
                       '-bios', 'none', '-kernel', image], timeout=60).stdout
            assert out.rstrip().endswith('PAIR HOLDS'), (label, out)
            seen[label] = out
            calls[label] = ownership_calls((build / 'builtin.s').read_text())
        assert seen['int'] == seen['word'], seen
        print('RawWord Pair: output identical to the Int Pair; no live allocation left: PASS')

        assert calls['word'] < calls['int'], calls
        print(f"RawWord Pair: {calls['word']} retain/release sites against {calls['int']} for Int fields: PASS")

        def image(name, source, env=None):
            path = tmp / f'{name}.fpr'
            path.write_text(source)
            p = subprocess.run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', 'BUILTIN_HEAP_BYTES=16384',
                                f'PROG={path}', f'BUILD={tmp / name}', f'IMAGE={tmp / (name + ".elf")}'],
                               capture_output=True, text=True, env=env, timeout=300)
            assert p.returncode == 0, (name, (p.stdout + p.stderr)[-1500:])
            run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic',
                 '-bios', 'none', '-kernel', tmp / f'{name}.elf'], timeout=60)
            asm = (tmp / name / 'builtin.s').read_text()
            return asm.count('uniformBoxWord'), len(re.findall(r'^# fn \S*\$typespec\$', asm, re.M))

        boxes, clones = image('mixed', MIXED)
        assert boxes == 0 and clones > 0, (boxes, clones)
        # Without cloning the generic ABI is kept (it used to be refused as
        # incompatible representations): the two pair types are distinct data
        # instances, so their fields still do not meet.
        boxes, clones = image('mixed-nospec', MIXED, dict(os.environ, FPR_NO_TYPE_SPEC='1'))
        assert boxes == 0 and clones == 0, (boxes, clones)
        print('Int and Word pairs through List: raw Word fields with C2 clones, and under FPR_NO_TYPE_SPEC=1 with none: PASS')
        boxes, _ = image('uniform', UNIFORM)
        assert boxes > 0, boxes
        print(f'Fields left as variables of a non-parametric type are uniform slots: {boxes} Word box sites: PASS')


if __name__ == '__main__':
    main()
