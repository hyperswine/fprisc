#!/usr/bin/env python3
"""Checked C2 identity, effects, nested layouts and ownership on RV64/QEMU."""
import os
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, env=None, expected=0, timeout=180):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, env=env,
                            capture_output=True, text=True, timeout=timeout)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result


def main():
    run(['make', '-s', 'fpr'], timeout=300)
    with tempfile.TemporaryDirectory(prefix='fpr-typespec-') as directory:
        tmp = Path(directory)

        def build(name, code, env=None):
            source = tmp / f'{name}.fpr'
            source.write_text(code)
            image = tmp / f'{name}.elf'
            builddir = tmp / name
            run(['make', '-s', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1',
                 'BUILTIN_HEAP_BYTES=65536', f'PROG={source}', f'BUILD={builddir}', f'IMAGE={image}'], env=env)
            return image, (builddir / 'builtin.s').read_text()

        def boot(image, expected=0):
            result = run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic',
                          '-bios', 'none', '-kernel', image], expected=expected, timeout=30)
            return result.stdout, result.stderr

        header = 'identity x = _ = print 7; x.\n'
        first = 'print (identity 1)'
        second = 'print (Word.toInt (identity (Word.fromInt 2)))'
        names = []
        for label, actions, expected in [('forward', [first,second], ['7','1','7','2']),
                                         ('reverse', [second,first], ['7','2','7','1']),
                                         ('repeated', [second,first,second], ['7','2','7','1','7','2'])]:
            image, asm = build(label, header + 'main = ' + '; '.join('_ = ' + a for a in actions) + '; Unit.\n')
            assert boot(image)[0].splitlines() == expected
            entries = set(re.findall(r'^# fn (identity\S*) ', asm, re.M))
            assert len(entries) == 2 and all('$typespec$type$' in n for n in entries), entries
            names.append(entries)
        assert names[0] == names[1] == names[2], names
        print('Source call order, repeated instances and observable effects: PASS')

        # No Word-valued cell is constructed, and this helper is never called.
        # Its checked List Word input must still choose the raw print adapter.
        uncalled = tmp / 'uncalled-layout.fpr'
        uncalled.write_text('showWords : List Word -> Unit.\n'
                            'showWords xs = case xs of [] -> Unit | x :: _ -> print x.\n'
                            'main = Unit.\n')
        diagnostic = dict(os.environ, FPR_DUMP_CORE='showWords')
        compiled = run([ROOT / 'fpr', 'compile', '--system=bare-metal', '--profile=builtin', '--arc',
                        uncalled, tmp / 'uncalled-layout.s'], env=diagnostic)
        dump = '\n'.join(line for line in compiled.stderr.splitlines() if line.startswith('core showWords:'))
        assert '$arc.wordPrint' in dump and '"$arc.print"' not in dump, compiled.stderr[-3000:]
        print('Uncalled List Word projection uses checked field evidence without a constructed cell: PASS')

        nested = '''
check b = case b of True -> Unit | False -> error "typed C2 check".
copy xs = case xs of [] -> [] | x :: rest -> x :: copy rest.
len xs = case xs of [] -> 0 | _ :: rest -> 1 + len rest.
observe xs = len xs + len xs.
probe u =
  a = copy [[1], [2, 3]];
  b = copy [[Word.fromInt 4], [Word.fromInt 5, Word.fromInt 6]];
  _ = check (observe a == 4);
  _ = check (observe b == 4);
  _ = check (len (copy [1]) == 1);
  _ = check (len (copy [1, 2, 3]) == 3);
  Unit.
main =
  before = Mem.liveAllocations Unit;
  _ = probe Unit;
  _ = check (Mem.liveAllocations Unit == before);
  print "NESTED TYPED C2 HOLDS".
'''
        image, asm = build('nested', nested)
        assert 'NESTED TYPED C2 HOLDS' in boot(image)[0]
        entries = re.findall(r'^# fn (copy\S*) ', asm, re.M)
        assert len(entries) == 3 and all('$typespec$type$' in n for n in entries), entries
        print('Nested List Int/List Word, shared reads, length-independent instances and zero live allocation: PASS')

        ownership = '''
Box = Type (Box a b c).
check b = case b of True -> Unit | False -> error "immortal ownership check".
unitId u = u.
boolId b = b.
stringId s = s.
choose box = case box of Box flag u s ->
  _ = unitId u; _ = boolId flag; stringId s.
probe n =
  box = Box (n == 0) Unit (strcat "value" (str n));
  _ = check (choose box == strcat "value" (str n));
  _ = check (choose box == choose box);
  Unit.
loop n = case n == 0 of True -> Unit | False -> _ = probe n; loop (n - 1).
main =
  before = Mem.liveAllocations Unit;
  _ = loop 1000;
  _ = check (Mem.liveAllocations Unit == before);
  _ = unitId (print 1);
  _ = unitId (print 2);
  _ = check (boolId True);
  print "IMMORTAL OWNERSHIP HOLDS".
'''
        image, _ = build('immortal', ownership)
        assert boot(image)[0].splitlines() == ['1', '2', 'IMMORTAL OWNERSHIP HOLDS']
        print('Immortal Unit/Bool, shared heap fields, 1000 allocation cycles and effect order: PASS')

        aggregates = '''
Bundle a b = Type (Bundle a b).
Choice a = Type (No | Yes a).
check b = case b of True -> Unit | False -> error "checked aggregate check".
unbundle : Bundle Word String -> Word.
unbundle box = case box of Bundle w s -> _ = check (String.len s == 3); w.
choose : Choice Word -> Word.
choose c = case c of No -> Word.fromInt 0 | Yes w -> w.
tuple w = (w, strcat "a" "bc").
record w = { value = w, label = strcat "a" "bc" }.
probe n =
  w = Word.fromInt n;
  _ = check (Word.eq (unbundle (Bundle w (strcat "a" "bc"))) w);
  _ = check (Word.eq (choose (Yes w)) w);
  _ = check (Word.eq (choose No) (Word.fromInt 0));
  (x, s) = tuple w;
  _ = check (Word.eq x w);
  _ = check (String.len s == 3);
  r = record w;
  _ = check (Word.eq r.value w);
  _ = check (String.len r.label == 3);
  Unit.
loop n = case n == 0 of True -> Unit | False -> _ = probe n; loop (n - 1).
main =
  before = Mem.liveAllocations Unit;
  _ = loop 1000;
  _ = check (Mem.liveAllocations Unit == before);
  print "CHECKED AGGREGATES HOLD".
'''
        image, _ = build('aggregate-layouts', aggregates)
        assert boot(image)[0].splitlines() == ['CHECKED AGGREGATES HOLD']
        print('Parameterized nominal types, scalar variant payloads, tuples/records and 1000 leak-free cycles: PASS')

        rollback = dict(os.environ, FPR_NO_TYPE_SPEC='1')
        growing = '''
grow : Int -> a -> Int.
grow n x = _ = print n; if n == 0 then 42 else grow (n - 1) [x].
check b = if b then Unit else error "generic recursion leak".
main = before = Mem.liveAllocations Unit;
  _ = check (grow 6 (Word.fromInt 9) == 42);
  _ = check (Mem.liveAllocations Unit == before);
  Unit.
'''
        image, asm = build('growing', growing)
        original, _ = build('growing-off', growing, rollback)
        assert boot(image) == boot(original)
        assert boot(image)[0].splitlines() == ['6','5','4','3','2','1','0']
        entries = re.findall(r'^# fn (grow\S*) ', asm, re.M)
        assert len(entries) == 2 and sum('$typespec$type$' in n for n in entries) == 1, entries
        notes = run([ROOT/'fpr', 'compile', '--system=bare-metal', '--profile=builtin', '--arc',
                     '--remarks=all', tmp/'growing.fpr', tmp/'growing-notes.s'])
        assert 'expanding recursive type specialization; using tagged generic entry' in notes.stderr
        json_args = [ROOT/'fpr', 'compile', '--system=bare-metal', '--profile=builtin', '--arc',
                     '--remarks=json', tmp/'growing.fpr', tmp/'growing-json.s']
        cold = run(json_args)
        warm = run(json_args)
        assert cold.stderr == warm.stderr
        records = [json.loads(line) for line in cold.stderr.splitlines()]
        decisions = [r for r in records if r['kind'] == 'type-spec']
        fallbacks = [r for r in decisions if r['outcome'] == 'declined']
        applied = [r for r in decisions if r['outcome'] == 'applied']
        assert len(applied) == 1 and applied[0]['reason']['instance'].startswith('grow$typespec$type$'), decisions
        assert len(fallbacks) == 1 and fallbacks[0]['reason']['tag'] == 'TypeSpecializationFallback', records
        assert fallbacks[0]['owner'] == 'grow' and fallbacks[0]['outcome'] == 'declined'
        assert (tmp/'growing-notes.s').read_bytes() == (tmp/'growing-json.s').read_bytes()
        print('Expanding polymorphic recursion uses a bounded clone plus real tagged fallback, with remarks and zero leaks: PASS')

        floating = '''
show x = _ = print x; str x.
check b = if b then Unit else error "generic float check".
probe u =
  _ = check (show 1.5 == str 1.5);
  _ = check (show (F32.ofF64 2.5) == str (F32.ofF64 2.5));
  _ = check (show (Word.fromInt 7) == "7");
  Unit.
main = before = Mem.liveAllocations Unit;
  _ = probe Unit;
  _ = check (Mem.liveAllocations Unit == before);
  Unit.
'''
        image, _ = build('generic-floats', floating)
        original, _ = build('generic-floats-off', floating, rollback)
        assert boot(image) == boot(original)
        assert boot(image)[0].splitlines() == ['1.5','2.5','7']
        print('Generic and specialized F64/F32/Word print and str agree without leaks: PASS')

        branches = '''
identity x = _ = print 2; x.
pick : Bool -> Word -> Word.
pick flag x = case flag of True -> _ = print 1; x | False -> identity x.
check b = if b then Unit else error "generic branch leak".
probe u = _ = print (Word.toInt (pick True (Word.fromInt 7)));
          print (Word.toInt (pick False (Word.fromInt 8))).
main = before = Mem.liveAllocations Unit; _ = probe Unit;
       check (Mem.liveAllocations Unit == before).
'''
        image, _ = build('generic-branches', branches)
        original, _ = build('generic-branches-off', branches, rollback)
        assert boot(image) == boot(original)
        assert boot(image)[0].splitlines() == ['1','7','2','8']
        print('Raw/generic branch joins convert only the selected arm and preserve effects without leaks: PASS')

        for label, expression in [('overflow', 'intMax Unit + 1'), ('divide', '17 / 0')]:
            code = 'identity x = _ = print x; x.\n' + f'main = _ = identity (Word.fromInt 7); print ({expression}).\n'
            image, _ = build(label, code)
            previous, _ = build(label + '-off', code, rollback)
            assert boot(image, 1) == boot(previous, 1)
        print('Specialization on/off preserves printed prefixes and overflow/division failures: PASS')


if __name__ == '__main__':
    main()
