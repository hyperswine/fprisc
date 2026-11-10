#!/usr/bin/env python3
"""MutMap is linear: every misuse that would let a program see the table
change under it is refused at compile time, by native and by Sol.

std/mutmap writes in place (runtime/vec.c), which is sound only because
`MutMap 1 k v` (core/prelude.fpr) has one owner.  Each refusal below would,
if accepted, hand two parts of the program the same table: using the map
twice, dropping it, keeping the old map after an update, a closure that
captured it called twice or handed to something that calls it per element
(List.map, MutMap.fold), and storing it twice.  Each has a legal twin that
must build and print the same in native and Sol.  The behaviour of the table
itself is tests/std/mutmap.fpr (check_std.py); docs/2026-11-10-MUTMAP.md.

FixedMap (std/fixedmap) is the same table and as linear; it is also a
different TYPE, so MutMap's growing operations refuse one.

The compiler must already be built.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = '''MutMap = use "std/mutmap".
FixedMap = use "std/fixedmap".
Order = use "std/order".
Map = use "std/map".
'''

# (source, the diagnostic text both frontends must print)
REFUSALS = {
    'used-twice': ('''
main = m = MutMap.ints Unit; a = MutMap.insert 1 1 m; b = MutMap.insert 2 2 m;
  u = MutMap.free a; MutMap.free b.
''', "linear variable 'm' used 2 time(s)"),
    'dropped': ('''
main = m = MutMap.insert 1 1 (MutMap.ints Unit); print 0.
''', "linear variable 'm' used 0 time(s)"),
    'old-map-after-update': ('''
main = m = MutMap.ints Unit; m2 = MutMap.insert 1 1 m; (n, m3) = MutMap.size m;
  u = MutMap.free m2; v = MutMap.free m3; print n.
''', "linear variable 'm' used 2 time(s)"),
    'read-discards-map': ('''
main = m = MutMap.insert 1 1 (MutMap.ints Unit); (n, _) = MutMap.size m; print n.
''', "DISCARDED by `_`"),
    'closure-called-twice': ('''
main = m = MutMap.ints Unit; f = fn k -> MutMap.insert k 1 m;
  a = f 1; b = f 2; u = MutMap.free a; MutMap.free b.
''', "linear variable 'f' used 2 time(s)"),
    'closure-to-list-map': ('''
main = m = MutMap.ints Unit; ms = List.map (fn k -> MutMap.size (MutMap.insert k 1 m)) [1, 2]; print 0.
''', "may call its function argument #1"),
    'closure-to-fold': ('''
main = m = MutMap.ints Unit; other = MutMap.insert 1 1 (MutMap.ints Unit);
  (n, o2) = MutMap.fold (fn acc k v -> case MutMap.size m of (s, m2) -> (case MutMap.free m2 of _ -> acc + s)) 0 other;
  u = MutMap.free o2; print n.
''', "may call its function argument #1"),
    'stored-twice': ('''
main = m = MutMap.ints Unit; p = (m, m); (a, b) = p; u = MutMap.free a; MutMap.free b.
''', "linear variable 'm' used 2 time(s)"),
    # FixedMap (std/fixedmap) is the same table and as linear
    'fixed-used-twice': ('''
main = m = FixedMap.ints 4; (a, m1) = FixedMap.insert 1 1 m; (b, m2) = FixedMap.insert 2 2 m;
  u = FixedMap.free m1; FixedMap.free m2.
''', "linear variable 'm' used 2 time(s)"),
    'fixed-dropped-on-refusal': ('''
main = m = FixedMap.ints 0; (r, _) = FixedMap.insert 1 1 m; print r.
''', "DISCARDED by `_`"),
    'fixed-old-after-toMutMap': ('''
main = m = FixedMap.ints 4; g = FixedMap.toMutMap m; (n, m2) = FixedMap.size m;
  u = MutMap.free g; v = FixedMap.free m2; print n.
''', "linear variable 'm' used 2 time(s)"),
}

POSITIVES = {
    'threaded': ('''
main = m = MutMap.ints Unit; m = MutMap.insert 1 10 m; m = MutMap.insertWith (fn a b -> a + b) 1 5 m;
  (v, m) = MutMap.get 1 m; u = MutMap.free m; print v.
''', 'Some 15\n'),
    'closure-called-once': ('''
main = m = MutMap.ints Unit; f = fn k -> MutMap.insert k 1 m; (n, m2) = MutMap.size (f 4);
  u = MutMap.free m2; print n.
''', '1\n'),
    'fold-unrestricted-callback': ('''
main = k = 100; m = MutMap.insert 2 20 (MutMap.insert 1 10 (MutMap.ints Unit));
  (s, m2) = MutMap.fold (fn acc key v -> acc + key + v + k) 0 m; u = MutMap.free m2; print s.
''', '233\n'),
    'freeze': ('''
main = m = MutMap.insert "b" 2 (MutMap.insert "a" 1 (MutMap.strings Unit));
  print (Map.entries (MutMap.freeze Order.string m)).
''', '[(a, 1), (b, 2)]\n'),
    'fixed-full-refuses-and-keeps-map': ('''
main = m = FixedMap.ints 1; (a, m) = FixedMap.insert 1 10 m; (b, m) = FixedMap.insert 2 20 m;
  (c, m) = FixedMap.insert 1 11 m; (v, m) = FixedMap.get 1 m; u = FixedMap.free m; print (a, b, c, v).
''', '(Some (), None, Some (), Some 11)\n'),
}

# a FixedMap is not a MutMap: the growing operations do not accept one
TYPE_REFUSALS = {
    'fixed-not-growable': '''
main = m = FixedMap.ints 1; m2 = MutMap.insert 1 1 m; u = MutMap.free m2; print 0.
''',
}


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-mutmap-') as directory:
        tmp = Path(directory)
        env = os.environ | {
            'FPR_HOME': str(ROOT), 'SOL_CACHE_DIR': str(tmp / 'sol-cache'),
            'SOL_GPU': '0', 'SOL_JIT': '0', 'SOL_NOTYPES': '0',
            'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache')),
        }
        env.pop('FPR_FOREIGN', None)

        def invoke(command):
            return subprocess.run([str(a) for a in command], cwd=ROOT, env=env,
                                  capture_output=True, text=True, timeout=300)

        for name, (body, needle) in REFUSALS.items():
            source = tmp / (name + '.fpr')
            source.write_text(BASE + body)
            for mode, command in (
                ('native', [ROOT / 'fpr', 'build', source, '-o', tmp / name]),
                ('Sol', [ROOT / 'fpr', 'sol', source]),
            ):
                result = invoke(command)
                output = result.stdout + result.stderr
                assert result.returncode != 0 and 'LINEARITY' in output, (name, mode, result.returncode, output)
                assert needle in output, (name, mode, needle, output)
            print(name + ': refused by native and Sol', flush=True)

        for name, body in TYPE_REFUSALS.items():
            source = tmp / (name + '.fpr')
            source.write_text(BASE + body)
            for mode, command in (
                ('native', [ROOT / 'fpr', 'build', source, '-o', tmp / name]),
                ('Sol', [ROOT / 'fpr', 'sol', source]),
            ):
                result = invoke(command)
                output = result.stdout + result.stderr
                assert result.returncode != 0 and 'FixedMap' in output and 'MutMap' in output, (name, mode, result.returncode, output)
            print(name + ': refused by native and Sol (types)', flush=True)

        for name, (body, expected) in POSITIVES.items():
            source = tmp / (name + '.fpr')
            source.write_text(BASE + body)
            binary = tmp / name
            built = invoke([ROOT / 'fpr', 'build', source, '-o', binary])
            assert built.returncode == 0, (name, built.returncode, built.stdout + built.stderr)
            for mode, command in (('native', [binary]), ('Sol', [ROOT / 'fpr', 'sol', source])):
                result = invoke(command)
                got = ''.join(l + '\n' for l in result.stdout.splitlines() if not l.startswith(('[sol]', '[table]', '[jit]')))
                assert result.returncode == 0, (name, mode, result.returncode, result.stdout + result.stderr)
                assert got == expected, (name, mode, expected, result.stdout, result.stderr)
            print(name + ': agrees in native and Sol', flush=True)
    print(f'{len(REFUSALS) + len(TYPE_REFUSALS) + len(POSITIVES)} MutMap and FixedMap ownership cases PASS', flush=True)


if __name__ == '__main__':
    main()
