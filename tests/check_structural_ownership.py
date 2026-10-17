#!/usr/bin/env python3
"""Records and control flow preserve owners in native and HostedBytecode.

The compiler must already be built. Tokens are immutable integers with no
external resource or destructor, so even a rejected-check regression is safe
to execute while developing the checker.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BASE = '''profile base.
Token 1 = Type (Token Int).
consume : Token -> Int.
consume owner = Token n = owner; u = print "consume {n}"; n.
'''

REFUSALS = {
    'record-duplicate-owned-field': '''
main = record = {owner = Token 7, owner = Token 8};
  print (consume record.owner).
''',
    'record-literal-double': '''
main = record = {owner = Token 7, tag = 0};
  print (consume record.owner, consume record.owner).
''',
    'record-projection-double': '''
unpack : {owner : Token, tag : Int} -> (Int, Int).
unpack record = owner = record.owner; (consume owner, consume owner).
main = print (unpack {owner = Token 7, tag = 0}).
''',
    'record-pattern-double': '''
unpack : {owner : Token, tag : Int} -> (Int, Int).
unpack record = {owner} = record; (consume owner, consume owner).
main = print (unpack {owner = Token 7, tag = 0}).
''',
    'record-update-stale': '''
main = old = {owner = Token 7, tag = 0}; fresh = {old | tag = 1};
  print (consume old.owner, consume fresh.owner).
''',
    'record-alias-double': '''
main = old = {owner = Token 7, tag = 0}; alias = old;
  print (consume old.owner, consume alias.owner).
''',
    'record-projection-residual': '''
main = record = {first = Token 7, second = Token 8};
  owner = record.first; print (consume owner).
''',
    'record-nested-projection-residual': '''
main = record = {inner = {first = Token 7, second = Token 8}, tag = 0};
  print (consume record.inner.first).
''',
    'record-pattern-residual': '''
main = record = {first = Token 7, second = Token 8};
  {first} = record; print (consume first).
''',
    'record-update-overwrite-owner': '''
main = old = {owner = Token 7, tag = 0};
  fresh = {old | owner = Token 8}; print (consume fresh.owner).
''',
    'record-nested-update-overwrite-owner': '''
main = old = {inner = {owner = Token 7, tag = 0}, flag = True};
  fresh = {old | inner.owner = Token 8}; print (consume fresh.inner.owner).
''',
    'record-metadata-loses-owner': '''
main = record = {owner = Token 7, tag = 0}; print record.tag.
''',
    'record-open-row-residual': '''
unpack : {owner : Token | r} -> Int.
unpack record = consume record.owner.
main = print (unpack {owner = Token 7, hidden = Token 8}).
''',
    'record-inferred-return-double': '''
makeRecord u = {owner = Token 7, tag = 0}.
main = record = makeRecord 0;
  print (consume record.owner, consume record.owner).
''',
    'case-result-closure-double': '''
main = owner = Token 7;
  callback = (case False of
      True -> u = consume owner; fn n -> n
    | False -> fn n -> consume owner + n);
  print (callback 0, callback 1).
''',
    'guard-created-owner-double': '''
guardedToken u | owner <- Token 7 = (consume owner, consume owner).
guardedToken _ = (0, 0).
main = print (guardedToken 0).
''',
    'guard-created-owner-lost': '''
guardedToken u | owner <- Token 7 = 0.
guardedToken _ = 0.
main = print (guardedToken 0).
''',
    'guard-created-owner-fallthrough': '''
guardedToken u | owner <- Token 7, False = consume owner.
guardedToken _ = 0.
main = print (guardedToken 0).
''',
}

POSITIVES = {
    'record-one-owner-projection': ('''
unpack : {owner : Token, tag : Int} -> Int.
unpack record = consume record.owner.
main = print (unpack {owner = Token 7, tag = 0}).
''', 'consume 7\n7\n'),
    'record-complete-two-owner-pattern': ('''
main = record = {first = Token 7, second = Token 8, tag = 0};
  {first, second} = record; print (consume first, consume second).
''', 'consume 7\nconsume 8\n(7, 8)\n'),
    'record-metadata-update-transfer': ('''
main = old = {owner = Token 7, tag = 0}; fresh = {old | tag = 1};
  print (consume fresh.owner).
''', 'consume 7\n7\n'),
    'record-alias-once': ('''
main = old = {owner = Token 7, tag = 0}; alias = old;
  print (consume alias.owner).
''', 'consume 7\n7\n'),
    'record-pattern-ignores-metadata': ('''
main = record = {owner = Token 7, tag = 0}; {owner} = record;
  print (consume owner).
''', 'consume 7\n7\n'),
    'record-nested-single-owner': ('''
main = record = {inner = {owner = Token 7, tag = 0}, flag = True};
  inner = record.inner; print (consume inner.owner).
''', 'consume 7\n7\n'),
    'record-nested-projection-path': ('''
main = record = {inner = {owner = Token 7, tag = 0}, flag = True};
  print (consume record.inner.owner).
''', 'consume 7\n7\n'),
    'record-nested-metadata-update': ('''
main = old = {inner = {owner = Token 7, tag = 0}, flag = True};
  fresh = {old | inner.tag = 1}; print (consume fresh.inner.owner).
''', 'consume 7\n7\n'),
    'record-inferred-return-once': ('''
makeRecord u = {owner = Token 7, tag = 0}.
main = record = makeRecord 0; print (consume record.owner).
''', 'consume 7\n7\n'),
    'guard-created-owner-once': ('''
guardedToken u | owner <- Token 7 = consume owner.
guardedToken _ = 0.
main = print (guardedToken 0).
''', 'consume 7\n7\n'),
    'case-result-linear-closure-once': ('''
main = owner = Token 7;
  callback = (case False of
      True -> u = consume owner; fn n -> n
    | False -> fn n -> consume owner + n);
  print (callback 0).
''', 'consume 7\n7\n'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', action='append', help='run only the named case; repeatable')
    args = parser.parse_args()
    selected = set(args.case or REFUSALS.keys() | POSITIVES.keys())
    unknown = selected - REFUSALS.keys() - POSITIVES.keys()
    if unknown:
        parser.error('unknown case(s): ' + ', '.join(sorted(unknown)))
    with tempfile.TemporaryDirectory(prefix='fpr-structural-ownership-') as directory:
        tmp = Path(directory)
        env = os.environ | {
            'FPR_HOME': str(ROOT), 'SOL_CACHE_DIR': str(tmp / 'sol-cache'),
            'SOL_GPU': '0', 'SOL_JIT': '0', 'SOL_NOTYPES': '0',
            'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache')),
        }
        env.pop('FPR_FOREIGN', None)

        def invoke(command):
            return subprocess.run([str(a) for a in command], cwd=ROOT, env=env,
                                  capture_output=True, text=True, timeout=120)

        for name, body in REFUSALS.items():
            if name not in selected:
                continue
            source = tmp / (name + '.fpr')
            source.write_text(BASE + body)
            for mode, command in (
                ('native', [ROOT / 'fprc', '--system=posix', '--check-only', source, '/dev/null']),
                ('Sol', [ROOT / 'fpr', 'sol', source]),
            ):
                result = invoke(command)
                output = result.stdout + result.stderr
                assert result.returncode != 0 and 'LINEARITY: ERRORS' in output, (name, mode, result.returncode, output)
            print(name + ': refused by native and Sol', flush=True)

        for name, (body, expected) in POSITIVES.items():
            if name not in selected:
                continue
            source = tmp / (name + '.fpr')
            source.write_text(BASE + body)
            binary = tmp / name
            built = invoke([ROOT / 'fpr', 'build', source, '-o', binary])
            assert built.returncode == 0, (name, built.returncode, built.stdout + built.stderr)
            for mode, command in (
                ('native', [binary]),
                ('Sol', [ROOT / 'fpr', 'sol', source]),
            ):
                result = invoke(command)
                assert result.returncode == 0, (name, mode, result.returncode, result.stdout + result.stderr)
                assert result.stdout == expected, (name, mode, expected, result.stdout, result.stderr)
            print(name + ': single-use result agrees in native and Sol', flush=True)
    print(str(len(selected)) + ' structural/control-flow ownership cases PASS', flush=True)


if __name__ == '__main__':
    main()
