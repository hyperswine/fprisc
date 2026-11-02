#!/usr/bin/env python3
"""Two-register pair returns (FPR_NO_PAIR_RETURNS=1 rolls back).

A function whose every result is a same-shape pair, called by a caller that
only tests the pair's shape and reads its fields, answers in two registers
(x0/x1, rax/rdx, a0/a1) through a $worker.ret2 twin: no heap cell per call.
Checks: identical output with the pass on and off on the pair_ret benchmark and
on a mix of non-tail, mutually tail-calling, self-looping and escaping pairs;
the same under four harts with actors preempted inside the twin; and the
emitted A64, X64 and RV64 code calls the twin and reads the second result
register after the call and before the next one."""
import os, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def run(args, env, timeout=300):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True, capture_output=True, timeout=timeout)

MIX = '''sumcount : unsafe Int -> (Int, Int) .
sumcount n = if n == 0 then (0, 0) else (case sumcount (n - 1) of (s, c) -> (s + n, c + 1)).
evenpair : unsafe Int -> (Int, Int) .
evenpair n = if n == 0 then (1, 0) else oddpair (n - 1).
oddpair : unsafe Int -> (Int, Int) .
oddpair n = if n == 0 then (0, 1) else evenpair (n - 1).
acc : unsafe Int -> Int -> Int -> (Int, Int) .
acc n s c = if n == 0 then (s, c) else acc (n - 1) (s + n) (c + 1).
twice : unsafe Int -> Int .
twice n = p = sumcount n; (case p of (a, b) -> a + b) + (case p of (a, b) -> a - b).
rep : unsafe Int -> Int -> Int .
rep k a = if k == 0 then a else rep (k - 1) (a + (case sumcount 100 of (s, c) -> s - c) + (case evenpair 7 of (x, y) -> x * 10 + y) + (case acc 50 0 0 of (s, c) -> s + c)).
main = print "{sumcount 10} {rep 300 0} {twice 20} {(case evenpair 10 of (x, y) -> x - y)}".
'''
ACTORS = '''unsafe base.
sumcount : unsafe Int -> (Int, Int) .
sumcount n = if n == 0 then (0, 0) else (case sumcount (n - 1) of (s, c) -> (s + n, c + 1)).
rep : unsafe Int -> Int -> Int .
rep k a = if k == 0 then a else rep (k - 1) (a + (case sumcount 2000 of (s, c) -> s - c)).
work parent self = send parent (rep 20000 0).
main = me = myself 0; a = spawn (work me); b = spawn (work me); c = spawn (work me); x = receiveFrom me a; y = receiveFrom me b; z = receiveFrom me c; print "{keep x} {keep y} {keep z}".
'''
SECOND = {'a64mac': ('x1', 'bl '), 'x64': ('rdx', 'call '), 'rv64': ('a1', 'call ')}

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-ret2-') as d:
        tmp = Path(d)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
        def env(on, harts='1'):
            e = dict(base, FPR_HARTS=harts, XDG_CACHE_HOME=str(tmp / f'c-{on}-{harts}'))
            if not on: e['FPR_NO_PAIR_RETURNS'] = '1'
            return e
        mix = tmp / 'mix.fpr'; mix.write_text(MIX)
        actors = tmp / 'actors.fpr'; actors.write_text(ACTORS)
        for name, src, harts in [('pair_ret', ROOT / 'tests/bench/unbox/pair_ret.fpr', '1'), ('mix', mix, '1'),
                                 ('actors1', actors, '1'), ('actors4', actors, '4')]:
            seen = []
            for on in (True, False):
                exe = tmp / f'{name}.{on}'
                b = run([ROOT / 'fpr', 'build', src, '--harts', harts, '-o', exe], env(on, harts))
                assert b.returncode == 0, b.stderr[-3000:]
                r = run([exe], env(on, harts))
                seen.append((r.returncode, r.stdout))
            assert seen[0] == seen[1] and seen[0][0] == 0 and seen[0][1].strip(), (name, seen)
        print('Pair returns: output identical on and off (bench, mix, actors on 1 and 4 harts) PASS', flush=True)

        for target, (second, call) in SECOND.items():
            outs = {}
            for on in (True, False):
                out = tmp / f'mix-{target}-{on}.s'
                c = run([ROOT / 'fpr', 'compile', '--system=posix', f'--target={target}', mix, out], env(on))
                assert c.returncode == 0, c.stderr[-3000:]
                outs[on] = (out.read_text(), c.stdout + c.stderr)
            text, err = outs[True]
            assert re.search(r'# pair returns: functions=\d+ twins=[1-9]\d* sites=[1-9]', text + err), (target, 'pass did not fire')
            assert 'ret2' not in outs[False][0], (target, 'rollback still creates twins')
            sites = 0
            lines = text.splitlines()
            for i, line in enumerate(lines):
                if line.lstrip().startswith(call) and 'x2eret2' in line:
                    follow = []
                    for nxt in lines[i + 1:]:
                        if nxt.lstrip().startswith(call): break
                        follow.append(nxt)
                    assert any(re.search(r'\b' + second + r'\b', x) for x in follow), (target, 'second word unread', line)
                    sites += 1
            assert sites >= 2, (target, sites)
            ret = re.search(r'^_?fpr_fn__x24worker_x2eret2_x2esumcount:\n(.*?)# native-insns-v1', text, re.S | re.M)
            assert ret and re.search(r'\b' + second + r'\b', ret.group(1)), (target, 'twin does not return the second word')
            print(f'Pair returns: {target} calls the twin and reads {second} ({sites} sites) PASS', flush=True)

if __name__ == '__main__':
    main()
