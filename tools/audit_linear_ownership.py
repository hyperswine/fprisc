#!/usr/bin/env python3
"""Audit known ownership gaps using safe nominal tokens, never real resources.

Diagnostic tool, intentionally outside check_base while gaps remain. Exit 1
means at least one invalid program was accepted; 0 means all non-escape probes
were refused. --native-run also executes accepted probes using harmless tokens.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = 'profile base.\nToken 1 = Type (Token Int).\nconsume : Token -> Int.\nconsume owner = Token n = owner; u = print "consume {n}"; n.\n'

CASES = {
    'direct_control': 'main = t = Token 7; print (consume t, consume t).',
    'lambda_control': 'main = t = Token 7; f = fn u -> consume t; print (f 0, f 1).',
    'tuple_control': 'main = t = Token 7; pair = (t, 0); (owned, n) = pair; print (consume owned, consume owned).',
    'direct_pap_control': 'at : Token -> Int -> Int.\nat t n = consume t + n.\nmain = t = Token 7; f = at t; print (f 0, f 1).',
    'generic_duplicate': 'duplicate : a -> (a, a).\nduplicate x = (x, x).\nmain = t = Token 7; (a, b) = duplicate t; print (consume a, consume b).',
    'generic_identity': 'identity : a -> a.\nidentity x = x.\nmain = t = Token 7; moved = identity t; print (consume moved, consume moved).',
    'box_pattern': 'Box a = Type (Box a).\nuseBox : Box Token -> (Int, Int).\nuseBox box = case box of Box x -> (consume x, consume x).\nmain = print (useBox (Box (Token 7))).',
    'box_wildcard': 'Box a = Type (Box a).\nforget : Box Token -> Unit.\nforget box = case box of Box _ -> Unit.\nmain = u = forget (Box (Token 7)); print "owner lost".',
    'record_literal': 'main = record = {owner = Token 7, tag = 0}; print (consume record.owner, consume record.owner).',
    'record_projection': 'unpack : {owner : Token, tag : Int} -> (Int, Int).\nunpack record = owner = record.owner; (consume owner, consume owner).\nmain = print (unpack {owner = Token 7, tag = 0}).',
    'record_update': 'main = t = Token 7; old = {owner = t, tag = 0}; fresh = {old | tag = 1}; print (consume old.owner, consume fresh.owner).',
    'higher_order_twice': 'twice : (Int -> Int) -> (Int, Int).\ntwice f = (f 0, f 1).\nmain = t = Token 7; f = fn n -> consume t + n; print (twice f).',
    'closure_return': 'make : Token -> (Int -> Int).\nmake t = fn n -> consume t + n.\nmain = f = make (Token 7); print (f 0, f 1).',
    'closure_identity': 'identity : a -> a.\nidentity x = x.\nmain = t = Token 7; f = fn n -> consume t + n; g = identity f; print (g 0, g 1).',
    'aliased_pap': 'at : Token -> Int -> Int.\nat t n = consume t + n.\nalias = at.\nmain = t = Token 7; f = alias t; print (f 0, f 1).',
    'dynamic_pap': 'at : Token -> Int -> Int.\nat t n = consume t + n.\nmain = t = Token 7; f = (case True of True -> at | False -> at) t; print (f 0, f 1).',
    'case_join': 'main = t = Token 7; f = (case False of True -> u = consume t; fn n -> n | False -> fn n -> consume t + n); print (f 0, f 1).',
    'guard_binding': 'guardedToken u | t <- Token 7 = (consume t, consume t).\nguardedToken _ = (0, 0).\nmain = print (guardedToken 0).',
    'keep_escape': 'main = t = Token 7; moved = keep t; print (consume moved, consume moved).',
    'result_pattern': 'takeResult : Result Token String -> (Int, Int).\ntakeResult result = case result of Ok owner -> (consume owner, consume owner) | Err _ -> (0, 0).\nmain = print (takeResult (Ok (Token 7))).',
    'list_pattern': 'takeTokens : List Token -> (Int, Int).\ntakeTokens tokens = case tokens of Nil -> (0, 0) | owner :: rest -> (consume owner, consume owner).\nmain = print (takeTokens [Token 7]).',
    'record_pattern': 'takeRecord : {owner : Token, tag : Int} -> (Int, Int).\ntakeRecord record = {owner} = record; (consume owner, consume owner).\nmain = print (takeRecord {owner = Token 7, tag = 0}).',
    'inferred_return': 'makeUnannotated u = Token 7.\nmain = t = makeUnannotated 0; print (consume t, consume t).',
    'inferred_parameter': 'handleUnannotated t = (consume t, consume t).\nmain = print (handleUnannotated (Token 7)).',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', type=Path, help='save source/diagnostics and results')
    parser.add_argument('--native-run', action='store_true', help='execute accepted native token probes too')
    args = parser.parse_args()
    rows = []
    with tempfile.TemporaryDirectory(prefix='fpr-ownership-audit-') as name:
        tmp = Path(name)
        env = {**os.environ, 'FPR_HOME': str(ROOT), 'SOL_CACHE_DIR': str(tmp / 'sol-cache'),
               'SOL_GPU': '0', 'SOL_JIT': '0',
               'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache'))}
        for case, body in CASES.items():
            source = tmp / (case + '.fpr')
            source.write_text(BASE + body + '\n')
            row = {'case': case, 'intentional_escape': case == 'keep_escape',
                   'source': source.read_text()}
            for mode, command in [('native', [ROOT / 'fprc', '--system=posix', '--check-only', source, '/dev/null']),
                                  ('sol', [ROOT / 'fpr', 'sol', source])]:
                p = subprocess.run(list(map(str, command)), cwd=ROOT, env=env,
                                   capture_output=True, text=True, timeout=120)
                output = (p.stdout + p.stderr).replace(str(tmp), '$TMP')
                row[mode] = {'accepted': p.returncode == 0, 'exit': p.returncode,
                             'linearity_refused': 'LINEARITY: ERRORS' in output,
                             'consumptions': p.stdout.count('consume 7\n'), 'output': output}
            if args.native_run and row['native']['accepted']:
                binary = tmp / case
                p = subprocess.run([str(ROOT / 'fpr'), 'build', str(source), '-o', str(binary)],
                                   cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
                if p.returncode:
                    raise RuntimeError(p.stdout + p.stderr)
                p = subprocess.run([str(binary)], cwd=tmp, env=env,
                                   capture_output=True, text=True, timeout=10)
                if p.returncode:
                    raise RuntimeError(p.stdout + p.stderr)
                row['native_execution'] = {'consumptions': p.stdout.count('consume 7\n'),
                                           'output': p.stdout + p.stderr}
            rows.append(row)
            print(case + ': native=' + ('ACCEPTED' if row['native']['accepted'] else 'refused')
                  + ', Sol=' + ('ACCEPTED' if row['sol']['accepted'] else 'refused'), flush=True)
    findings = [r['case'] for r in rows if not r['intentional_escape']
                and (r['native']['accepted'] or r['sol']['accepted'])]
    print(str(len(findings)) + ' invalid ownership probes accepted by at least one frontend; '
          'keep is recorded separately as an explicit escape', flush=True)
    if args.json:
        args.json.write_text(json.dumps({'findings': findings, 'cases': rows}, indent=2) + '\n')
    return int(bool(findings))


if __name__ == '__main__':
    raise SystemExit(main())
