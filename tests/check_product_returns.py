#!/usr/bin/env python3
"""Private unary payload / 2..8-word returns: allocation and boundary behavior.

These are hosted Base call-site workers. They do not authorize builtin/raw
aggregate storage or foreign C aggregate returns. FPR_NO_PAIR_RETURNS rolls the
whole pass back, including wider products.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, env, timeout=180):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=timeout)


def fixture(width, count=1000):
    if width == 1:
        return (f'unsafe base.\nCell = Type (Cell Int).\n'
                'make : unsafe Int -> Cell .\n'
                'make n = if n < 0 then make (0 - n) else Cell n.\n'
                'loop : unsafe Int -> Int -> Int .\n'
                'loop n acc = if n == 0 then acc else (case make n of Cell x -> loop (n - 1) (acc + x)).\n'
                f'main = print (loop {count} 0).\n')
    fields = ', '.join(f'n + {i}' for i in range(width))
    names = ', '.join(f'x{i}' for i in range(width))
    total = ' + '.join(f'x{i} * {i+1}' for i in range(width))
    return (f'unsafe base.\nmake : unsafe Int -> ({", ".join(["Int"]*width)}) .\n'
            f'make n = if n < 0 then make (0 - n) else ({fields}).\n'
            'loop : unsafe Int -> Int -> Int .\n'
            f'loop n acc = if n == 0 then acc else (case make n of ({names}) -> loop (n - 1) (acc + {total})).\n'
            f'main = print (loop {count} 0).\n')


def expected(width, count):
    return sum((count*(count+1)//2 + i*count)*(i+1) for i in range(width))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['macos-x86_64'])
    parser.add_argument('--record', type=Path)
    parser.add_argument('--compiler', type=Path, default=ROOT/'fpr')
    parser.add_argument('--expect-unary-boxed', action='store_true', help='saved compiler before unary return workers')
    args = parser.parse_args()
    rows = []
    with tempfile.TemporaryDirectory(prefix='fpr-product-return-') as directory:
        tmp = Path(directory)
        base = {k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'),
                    FPR_NO_INLINE='1', FPR_NO_CALL_REGIONS='1', FPR_NO_FIELD_WORKERS='1', FPR_NO_SCALAR_WORKERS='1')

        def environment(on, cost=False):
            env = dict(base)
            if not on:
                env['FPR_NO_PAIR_RETURNS'] = '1'
            if cost:
                # Isolate constructor cells from the separate per-slab region adapter.
                env.update(FPR_COST_PROBE='1', FPR_COST_REPORT='1', FPR_NO_LOOP_REGIONS='1')
            return env

        def build(name, source, on, cost=False, normal=False):
            src = tmp/(name+'.fpr'); src.write_text(source)
            exe = tmp/name
            env = environment(on, cost)
            if normal:
                for flag in ('FPR_NO_INLINE','FPR_NO_CALL_REGIONS','FPR_NO_FIELD_WORKERS','FPR_NO_SCALAR_WORKERS'):
                    env.pop(flag,None)
            p = run([args.compiler, 'build', *(['--target='+args.target] if args.target else []), src, '--harts', '4', '-o', exe], env)
            assert p.returncode == 0, (name, p.stdout[-2000:], p.stderr[-5000:])
            return exe, env

        host_width = 8
        for width in range(1, 10):
            costs = []
            for on in (False, True):
                exe, env = build(f'width{width}-{on}', fixture(width), on, cost=True)
                for harts in ('1', '4'):
                    p = run([exe], dict(env, FPR_HARTS=harts))
                    assert p.returncode == 0 and p.stdout == str(expected(width, 1000))+'\n', (width, on, harts, p)
                    ledger = json.loads(re.search(r'\[fpr cost\] (\{.*\})', p.stderr)[1])
                    rows.append(dict(width=width, enabled=on, harts=int(harts), allocations=ledger['alloc_requests'], stdout=p.stdout))
                    if harts == '1':
                        costs.append(ledger['alloc_requests'])
            assert costs[0]-costs[1] == (1000 if width <= host_width and not (width==1 and args.expect_unary_boxed) else 0), (width, costs)
            print(f'Product returns: {width} fields, allocations {costs[0]} -> {costs[1]}, 1/4 harts PASS', flush=True)

        # Unary payloads use the ordinary value ABI. Shared heap references,
        # a function-valued field, nested constructors and tagged escapes must
        # survive region exit and calls that allocate or trigger fuel resets.
        unary_values = '''unsafe base.
Cell a = Type (Cell a).
make n = if n < 0 then make (0 - n) else Cell n.
wrap x = Cell x.
inc x = x + 1.
hold n = case make n of Cell x -> _ = print (wrap "escape"); x.
unpack x = case wrap x of Cell y -> y.
main = _ = print (hold 7); s = unpack "held";
  _ = print (unpack [1,2,3]); _ = print (s,s);
  _ = print ((unpack inc) 9); _ = print (unpack (Cell 11));
  _ = print (wrap 13); _ = print (unpack True); print (unpack Unit).
'''
        expected_unary='Cell escape\n7\n[1, 2, 3]\n(held, held)\n10\nCell 11\nCell 13\nTrue\n()\n'
        for normal in (False,True):
            for on in (False,True):
                exe,env=build(f'unary-values-{normal}-{on}',unary_values,on,normal=normal)
                for harts in ('1','4'):
                    p=run([exe],dict(env,FPR_HARTS=harts))
                    assert p.returncode==0 and p.stdout==expected_unary and not p.stderr,(normal,on,harts,p)
        print('Unary returns: heap/function payloads, sharing, nested values and escapes PASS',flush=True)

        unary_effects={
            'ordered':('print "payload" >> n','7','payload\nafter\n7\n',None),
            'overflow':('print "payload" >> (n + 1)','4611686018427387903','payload\n','overflow'),
            'underflow':('print "payload" >> (n - 1)','(0 - 4611686018427387903 - 1)','payload\n','overflow'),
            'division':('print "payload" >> (1 / n)','0','payload\n','division by zero'),
            'max':('n','4611686018427387903','after\n4611686018427387903\n',None),
            'min':('n','(0 - 4611686018427387903 - 1)','after\n-4611686018427387904\n',None),
            'unused-division':('print "payload" >> (1 / n)','0','payload\n','division by zero'),
        }
        for name,(payload,arg,expected_out,error) in unary_effects.items():
            result='42' if name=='unused-division' else 'x'
            source=('unsafe base.\nCell = Type (Cell Int).\nmake n = Cell ('+payload+').\n'
                    'main = v = make '+arg+'; _ = print "after"; print (case v of Cell x -> '+result+').\n')
            outcomes=[]
            for normal in (False,True):
                for on in (False,True):
                    exe,env=build(f'unary-{name}-{normal}-{on}',source,on,normal=normal)
                    p=run([exe],env)
                    assert p.stdout==expected_out,(name,normal,on,p)
                    assert (p.returncode!=0 and error in p.stderr) if error else (p.returncode==0 and not p.stderr),(name,normal,on,p)
                    outcomes.append((p.returncode,p.stdout,p.stderr))
            assert len(set(outcomes))==1,(name,outcomes)
        print('Unary returns: seven exact effect/trap/endpoint differentials PASS',flush=True)

        prefix_effects={
          'success':('n','(print "argument" >> 7)','argument\npayload\nconsumer\nafter\n7\n',None),
          'division':('n','(print "argument" >> (1 / 0))','argument\n','division by zero'),
          'overflow':('n + 1','(print "argument" >> 4611686018427387903)','argument\npayload\n','overflow'),
        }
        for name,(value,arg,expected_out,error) in prefix_effects.items():
            source=('unsafe base.\nCell = Type (Cell Int).\nmake n = Cell (print "payload" >> ('+value+')).\n'
                    'main = result = case make '+arg+' of Cell x -> print "consumer" >> x; '
                    '_ = print "after"; print result.\n')
            outcomes=[]
            for normal in (False,True):
                for on in (False,True):
                    exe,env=build(f'unary-prefix-{name}-{normal}-{on}',source,on,normal=normal)
                    p=run([exe],env)
                    assert p.stdout==expected_out,(name,normal,on,p)
                    assert (p.returncode!=0 and error in p.stderr) if error else (p.returncode==0 and not p.stderr),(name,normal,on,p)
                    outcomes.append((p.returncode,p.stdout,p.stderr))
            assert len(set(outcomes))==1,(name,outcomes)
        print('Unary returns: strict argument-prefix effects and failures PASS',flush=True)

        (tmp/'unary-module.fpr').write_text('unsafe base.\nCell = Type (Cell Int).\n'
            'make n = Cell n.\nget c = case c of Cell n -> n.\n'
            'local n = case make n of Cell x -> x.\n')
        public_source='unsafe base.\nM = use "./unary-module".\nmain = print (M.get (M.make 7)) >> print (M.local 9).\n'
        public_costs=[]
        for on in (False,True):
            exe,env=build('unary-module-'+str(on),public_source,on,cost=True)
            p=run([exe],env)
            assert p.returncode==0 and p.stdout=='7\n9\n',p
            ledger=json.loads(re.search(r'\[fpr cost\] (\{.*\})',p.stderr)[1])
            public_costs.append(ledger['alloc_requests'])
        assert public_costs==([2,2] if args.expect_unary_boxed else [2,1]),public_costs
        print('Unary returns: imported tagged entry and owner-local allocation',public_costs,'PASS',flush=True)

        boundaries={
          'actor':('unsafe base.\nCell a = Type (Cell a).\nwrap x = Cell x.\n'
            'receiver parent self = v = receive self; case v of Cell x -> send parent (wrap x).\n'
            'main = me = myself 0; a = spawnOn 0 (receiver me); _ = send a (wrap "retained"); '
            'v = receiveFrom me a; print v >> (case v of Cell x -> print (x,x)).\n',
            'Cell retained\n(retained, retained)\n'),
          'dynamic':('unsafe base.\nChoice = Type (Cell Int | Other Int).\n'
            'cell x = Cell x.\nother x = Other x.\n'
            'pick flag = if flag then cell else other.\n'
            'mixed flag x = if flag then Cell x else Other x.\n'
            'readChoice c = case c of Cell x -> x | Other x -> x + 100.\n'
            'go flag x = readChoice ((pick flag) x).\n'
            'main = print (go True 7) >> print (go False 9) >> print (readChoice (mixed False 11)).\n',
            '7\n109\n111\n'),
        }
        for name,(source,expected_out) in boundaries.items():
            for normal in (False,True):
                for on in (False,True):
                    exe,env=build(f'unary-{name}-{normal}-{on}',source,on,normal=normal)
                    for harts in ('1','4'):
                        p=run([exe],dict(env,FPR_HARTS=harts))
                        assert p.returncode==0 and p.stdout==expected_out and not p.stderr,(name,normal,on,harts,p)
        print('Unary returns: actor transport, unknown callbacks and mixed constructors PASS',flush=True)

        # Hold 96 returned fields across further product calls and an effect.
        width = 8
        source = fixture(width).split('loop :')[0]
        names = [[f'v{j}_{i}' for i in range(width)] for j in range(12)]
        source += 'pressure n = ' + ''.join(
            f'case make (n + {j}) of ({", ".join(fields)}) -> '
            for j, fields in enumerate(names))
        source += 'print "held" >> (' + ' + '.join(x for fields in names for x in fields) + ').\n'
        source += 'main = print (pressure 10).\n'
        for on in (False, True):
            exe, env = build('pressure'+str(on), source, on)
            p = run([exe], env)
            assert p.returncode == 0 and p.stdout == 'held\n1824\n', p
        print('Product returns: 96 held fields across calls/effects PASS', flush=True)

        effects = {
            'ordered': ('(print "first" >> n, print "second" >> (n + 1), print "third" >> (n + 2))', 4,
                        'first\nsecond\nthird\n15\n', None),
            'overflow': ('(print "first" >> n, n + 1, print "third" >> n)', 4611686018427387903,
                         'first\n', 'overflow'),
            'division': ('(print "first" >> n, 1 / n, print "third" >> n)', 0,
                         'first\n', 'division by zero'),
            'division-unused': ('(print "first" >> n, 1 / n, print "third" >> n)', 0,
                                'first\n', 'division by zero'),
            'min-success': ('(n, n + 1, n + 2)', '(0 - 4611686018427387903 - 1)',
                            '-4611686018427387904\n', None),
        }
        for name, (fields, arg, stdout, error) in effects.items():
            # Read only the first field in the boundary case; unused fields
            # still execute in order, including their traps and effects.
            result = 'a' if name in ('min-success', 'division-unused') else 'a + b + c'
            source = (f'unsafe base.\nmake : unsafe Int -> (Int, Int, Int) .\nmake n = {fields}.\n'
                      f'main = print (case make {arg} of (a, b, c) -> {result}).\n')
            outcomes = []
            for on in (False, True):
                exe, env = build(name+str(on), source, on)
                p = run([exe], env)
                assert p.stdout == stdout, (name, on, p)
                assert (p.returncode == 0 and not p.stderr) if error is None else (p.returncode != 0 and error in p.stderr), (name, on, p)
                outcomes.append((p.returncode, p.stdout, p.stderr))
            assert outcomes[0] == outcomes[1], (name, outcomes)
            print('Product returns:', name, 'exact effect/trap differential PASS', flush=True)

        fields = ', '.join(str(i) for i in range(1, 9))
        names = ', '.join('x'+str(i) for i in range(8))
        total = ' + '.join('x'+str(i) for i in range(8))
        source = ('unsafe base.\n'
                  f'even n = if n == 0 then ({fields}) else odd (n - 1).\n'
                  f'odd n = if n == 0 then ({fields}) else even (n - 1).\n'
                  f'main = print (case even 1001 of ({names}) -> {total}).\n')
        for on in (False, True):
            exe, env = build('mutual'+str(on), source, on)
            p = run([exe], env)
            assert p.returncode == 0 and p.stdout == '36\n', p
        print('Product returns: eight-field mutual tail calls PASS', flush=True)

        # Escapes and multiple uses of heap fields must retain their values.
        source = '''unsafe base.
make : unsafe Int -> (String, List Int, Int) .
make n = ("kept", [n, n + 1], n).
consumeFields n = case make n of (s, xs, x) -> print (s, xs, x).
main = print (make 7) >> consumeFields 9.
'''
        for on in (False, True):
            exe, env = build('escape'+str(on), source, on)
            p = run([exe], env)
            assert p.returncode == 0 and p.stdout == '(kept, [7, 8], 7)\n(kept, [9, 10], 9)\n', p
        print('Product returns: tagged escape and heap-valued fields PASS', flush=True)

        for target, capacity, register in [('a64mac',8,'x7'),('rv64',8,'a7'),('x64',8,'r10')]:
            for width in (1, 2, 3, 8, 9):
                src = tmp/f'emission{width}.fpr'; src.write_text(fixture(width))
                out = tmp/f'{target}-{width}.s'
                p = run([args.compiler, 'compile', '--system=posix', f'--target={target}', src, out], environment(True))
                assert p.returncode == 0, (target, width, p.stderr[-5000:])
                text = out.read_text()
                twin = f'x2eret{width}_x2emake'
                assert (twin in text) == (width <= capacity and not (width==1 and args.expect_unary_boxed)), (target, width, 'incorrect target fallback')
                if width == capacity:
                    match = re.search(r'^_?fpr_fn__x24worker_'+twin+r':\n(.*?)# native-insns-v1', text, re.M|re.S)
                    assert match and re.search(r'\b'+register+r'\b', match[1]), (target, width, 'last return field missing')
            print(f'Product returns: {target} width admission and register emission PASS', flush=True)

    if args.record:
        args.record.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256(args.compiler.read_bytes()).hexdigest(),
            test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),target=args.target or platform.machine(),
            allocations=rows, pressure_fields=96, effect_and_boundary_checks='PASS'),indent=2)+'\n')


if __name__ == '__main__':
    main()
