#!/usr/bin/env python3
"""Checked List fusion: differential behavior, safety, allocation and rollback."""
from pathlib import Path
import json, os, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, env, timeout=180):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=timeout)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-list-fusion-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1',
                    XDG_CACHE_HOME=str(tmp / 'cache'))

        def source(name, text):
            path = tmp / (name + '.fpr')
            path.write_text(text)
            return path

        def build(path, name, disabled=False, probe=False):
            env = dict(base)
            if disabled:
                env['FPR_NO_LIST_FUSE'] = '1'
            if probe:
                env.update(FPR_COST_PROBE='1', FPR_NO_LOOP_REGIONS='1',
                           FPR_NO_CALL_REGIONS='1')
            exe = tmp / name
            made = run([ROOT / 'fpr', 'build', path, '--harts', '1', '-o', exe], env)
            assert made.returncode == 0, (name, made.stdout[-2000:], made.stderr[-6000:])
            return exe, env

        def execute(exe, env, report=False):
            return run([exe], dict(env, FPR_COST_REPORT='1') if report else env, timeout=60)

        # All admitted rules, including capture composition and transformer-only
        # map/map and filter/filter chains, agree with the disabled pipeline.
        differential = source('differential', '''List = use "std/list".
main =
  a = List.sum (List.range 1 20);
  b = List.product (List.range 1 5);
  c = List.fold (fn z x -> z * 2 + x) 0 (List.range 1 5);
  k = 3;
  d = List.sum (List.map (fn x -> x + k) (List.range 1 4));
  e = List.sum (List.filter (fn x -> x < 4) (List.range 1 6));
  f = List.map (fn x -> x * 2) (List.map (fn x -> x + 1) (List.range 1 4));
  g = List.filter (fn x -> x > 2) (List.filter (fn x -> x < 5) (List.range 1 6));
  h = List.fold (fn z x -> z + x) 0 (List.map (fn x -> x * 3) [1, 2, 3]);
  print (a, b, c, d, e, f, g, h).
''')
        expected = '(210, 120, 57, 22, 6, [4, 6, 8, 10], [3, 4], 18)\n'
        for disabled in (False, True):
            exe, env = build(differential, 'differential-' + str(disabled), disabled)
            observed = execute(exe, env)
            assert observed.returncode == 0 and observed.stdout == expected and not observed.stderr, (
                disabled, observed.returncode, observed.stdout, observed.stderr)
        print('List fusion: fold/sum/product/range, captures, map/map, filter/filter and list-input composition PASS', flush=True)

        # Pin the whole pipeline's allocator requests; callback application can
        # allocate as well as cons construction. Fused pipelines allocate none.
        cases = {
            'sum': ('main = print (List.sum (List.range 1 1000)).\n', '500500\n', 1000),
            'map': ('main = print (List.sum (List.map (fn x -> x + 1) (List.range 1 1000))).\n',
                    '501500\n', 3000),
            'filter': ('main = print (List.sum (List.filter (fn x -> x <= 500) (List.range 1 1000))).\n',
                       '125250\n', 2000),
        }
        for name, (body, expected_output, unfused_requests) in cases.items():
            path = source(name, 'List = use "std/list".\n' + body)
            for disabled in (False, True):
                exe, env = build(path, f'{name}-{disabled}', disabled, probe=True)
                observed = execute(exe, env, report=True)
                assert observed.returncode == 0 and observed.stdout == expected_output, (
                    name, disabled, observed.stdout, observed.stderr)
                match = re.search(r'\[fpr cost\] (\{.*\})', observed.stderr)
                assert match, (name, disabled, observed.stderr)
                ledger = json.loads(match.group(1))
                wanted = unfused_requests if disabled else 0
                assert ledger['alloc_requests'] == wanted, (name, disabled, ledger)
                if not disabled:
                    assert ledger['alloc_bytes'] == 0, (name, ledger)
            print(f'List fusion allocation: {name} {unfused_requests} -> 0 requests PASS', flush=True)

        # Let-bound producers: the single-use binding is part of the peeled
        # safe prefix, so the producer's evaluation moves to the source
        # position only across safe work and safe consumer arguments.
        letbound = source('letbound', '''List = use "std/list".
main =
  r = List.range 1 20;
  m = List.map (fn x -> x * 2) (List.range 1 4);
  f = List.filter (fn x -> x < 4) (List.range 1 6);
  mm = List.map (fn x -> x * 2) (List.map (fn x -> x + 1) (List.range 1 4));
  m2 = List.map (fn x -> x + 1) (List.range 1 4);
  chained = List.map (fn x -> x * 3) m2;
  a = List.sum r;
  b = List.sum m;
  c = List.sum f;
  d = List.sum mm;
  e = List.sum chained;
  r2 = List.range 1 8;
  s1 = List.sum r2;
  s2 = List.fold (fn z x -> z * 10 + x) 0 r2;
  k = 2;
  r3 = List.range 1 10;
  u = List.fold (fn z x -> z + x) (100 / k) r3;
  print (a, b, c, d, e, s1, s2, u).
''')
        let_expected = '(210, 20, 6, 28, 42, 36, 12345678, 105)\n'
        for disabled in (False, True):
            exe, env = build(letbound, 'letbound-' + str(disabled), disabled)
            observed = execute(exe, env)
            assert observed.returncode == 0 and observed.stdout == let_expected and not observed.stderr, (
                disabled, observed.returncode, observed.stdout, observed.stderr)
        print('List fusion: let-bound producers fuse; multi-use and unsafe-seed bindings stay untouched PASS', flush=True)

        # Fused let-bound pipelines allocate nothing; declined ones keep the
        # unfused allocation exactly in both modes.
        let_cases = {
            'let-sum': ('main =\n  r = List.range 1 1000;\n  print (List.sum r).\n', '500500\n', 1000),
            'let-fold': ('main =\n  r = List.range 1 1000;\n  print (List.fold (fn z x -> z + x) 0 r).\n',
                         '500500\n', 1000),
            'let-map': ('main =\n  m = List.map (fn x -> x + 1) (List.range 1 1000);\n  print (List.sum m).\n',
                        '501500\n', 3000),
            'let-filter': ('main =\n  f = List.filter (fn x -> x <= 500) (List.range 1 1000);\n  print (List.sum f).\n',
                           '125250\n', 2000),
            'let-chain': ('main =\n  m2 = List.map (fn x -> x + 1) (List.range 1 1000);\n'
                          '  m3 = List.map (fn x -> x * 2) m2;\n  print (List.sum m3).\n',
                          '1003000\n', 5000),
        }
        for name, (body, expected_output, unfused_requests) in let_cases.items():
            path = source(name, 'List = use "std/list".\n' + body)
            for disabled in (False, True):
                exe, env = build(path, f'{name}-{disabled}', disabled, probe=True)
                observed = execute(exe, env, report=True)
                assert observed.returncode == 0 and observed.stdout == expected_output, (
                    name, disabled, observed.stdout, observed.stderr)
                ledger = json.loads(re.search(r'\[fpr cost\] (\{.*\})', observed.stderr).group(1))
                wanted = unfused_requests if disabled else 0
                assert ledger['alloc_requests'] == wanted, (name, disabled, ledger)
            print(f'List fusion allocation: {name} {unfused_requests} -> 0 requests PASS', flush=True)
        declines = {
            'let-multi-use': ('main =\n  r2 = List.range 1 1000;\n  s1 = List.sum r2;\n'
                              '  s2 = List.sum r2;\n  print (s1 + s2).\n', '1001000\n'),
            'let-unsafe-seed': ('main =\n  k = 2;\n  r3 = List.range 1 1000;\n'
                                '  print (List.fold (fn z x -> z + x) (100 / k) r3).\n', '500550\n'),
        }
        for name, (body, expected_output) in declines.items():
            path = source(name, 'List = use "std/list".\n' + body)
            seen = []
            for disabled in (False, True):
                exe, env = build(path, f'{name}-{disabled}', disabled, probe=True)
                observed = execute(exe, env, report=True)
                assert observed.returncode == 0 and observed.stdout == expected_output, (
                    name, disabled, observed.stdout, observed.stderr)
                ledger = json.loads(re.search(r'\[fpr cost\] (\{.*\})', observed.stderr).group(1))
                seen.append(ledger['alloc_requests'])
            assert seen[0] == seen[1] and seen[0] > 0, (name, seen)
            print(f'List fusion declined allocation: {name} unchanged at {seen[0]} requests PASS', flush=True)

        # Name coincidence is not identity: the local wrappers do not have the
        # std catalog shapes and must remain untouched.
        lookalike = source('lookalike', '''range a b = [1, 2].
sum xs = 99.
main = print (sum (range 0 1)).
''')
        for disabled in (False, True):
            exe, env = build(lookalike, 'lookalike-' + str(disabled), disabled)
            observed = execute(exe, env)
            assert observed.returncode == 0 and observed.stdout == '99\n', observed.stdout + observed.stderr
        assembly = tmp / 'lookalike.s'
        compiled = run([ROOT / 'fpr', 'compile', lookalike, assembly], base)
        assert compiled.returncode == 0 and '$typed.listfusion.' not in assembly.read_text(), compiled.stderr
        print('List fusion: same-named user combinators remain untouched PASS', flush=True)

        # Division is outside FusionPolicy: effect/trap order is not relaxed.
        trapping = source('trapping', '''List = use "std/list".
main = print (List.sum (List.map (fn x -> 100 / x) (List.range 0 2))).
''')
        declined = tmp / 'trapping.s'
        remarks = run([ROOT / 'fpr', 'compile', '--remarks=all', trapping, declined], base)
        assert remarks.returncode == 0, remarks.stdout + remarks.stderr
        assert 'remark[not-fused]' in remarks.stderr and 'primitive `/`' in remarks.stderr, remarks.stderr
        trap_results = []
        for disabled in (False, True):
            exe, env = build(trapping, 'trapping-' + str(disabled), disabled)
            observed = execute(exe, env)
            assert observed.returncode != 0, (disabled, observed.stdout, observed.stderr)
            trap_results.append((observed.returncode, observed.stdout, observed.stderr))
        assert trap_results[0] == trap_results[1], trap_results
        print('List fusion: trapping callback declines with a remark; output/trap behavior matches PASS', flush=True)

        # Pin the consciously documented Int-overflow relaxation. The original
        # descending range returns here; the ascending fused loop ticks a + 1
        # after the last element and traps at maxInt.
        edge = source('edge', '''List = use "std/list".
main = print (List.fold (fn z x -> z) 0 (List.range 4611686018427387903 4611686018427387903)).
''')
        enabled_exe, enabled_env = build(edge, 'edge-enabled')
        disabled_exe, disabled_env = build(edge, 'edge-disabled', disabled=True)
        fused_edge = execute(enabled_exe, enabled_env)
        plain_edge = execute(disabled_exe, disabled_env)
        assert plain_edge.returncode == 0 and plain_edge.stdout == '0\n', plain_edge.stdout + plain_edge.stderr
        assert fused_edge.returncode != 0 and 'overflow' in (fused_edge.stdout + fused_edge.stderr).lower(), (
            fused_edge.returncode, fused_edge.stdout, fused_edge.stderr)
        print('List fusion: documented maxInt foldRange overflow edge pinned PASS', flush=True)


if __name__ == '__main__':
    main()
