#!/usr/bin/env python3
"""x64 is typed-only: every target/unit, rollback refusals and warm run caches."""
import os
import platform
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENV = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
ENV.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))


def run(args, env, code=0):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=300)
    assert p.returncode == code, (args, p.returncode, p.stdout[-2000:], p.stderr[-3000:])
    return p


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-x64-retirement-') as d:
        tmp = Path(d)
        env = dict(ENV, XDG_CACHE_HOME=str(tmp / 'cache'))
        src = tmp / 'probe.fpr'
        src.write_text('inc n = n + 1.\nmain = print (inc 41).\n')
        targets = ('x64', 'qx64')
        interface_targets = {'x64': 'x64r10', 'qx64': 'qx64r10'}
        for target in targets:
            seen = {}
            for backend in (None, '1', 'mixed', None):
                mode = dict(env)
                if backend is not None:
                    mode['FPR_TYPED_IR_BACKEND'] = backend
                asm = tmp / (target + '.s')
                run([ROOT / 'fprc', '--target=' + target, src, asm], mode)
                units = [Path(p) for p in Path(str(asm) + '.units').read_text().splitlines()]
                assert units and all('-native1' in p.name for p in units), units
                for path in [asm, *units]:
                    text = path.read_text()
                    assert text.startswith('# typed IR: no translation\n'), path
                    headers = re.findall(r'^# fn (.*)', text, re.M)
                    assert all(' typed-ir x64 ' in h for h in headers), (path, headers)
                    if target == 'qx64':
                        assert '@tpoff' not in text and 'fpr_posix_hart' not in text
                        if headers:
                            assert 'fpr_g_tlsoff(%rip)' in text and '%fs:0(' in text
                    assert '# wcet:' not in text and 'segmax=UNBOUNDED' not in text, path
                paths = frozenset(units)
                key = backend or 'mixed'
                if key in seen:
                    assert paths == seen[key], (target, backend)
                seen[key] = paths
            assert seen['mixed'].isdisjoint(seen['1']), target
            for backend in ('legacy', '0', 'off'):
                # Even an existing output and populated unit cache cannot
                # make a retired rollback request succeed or rewrite it.
                before = asm.read_bytes()
                p = run([ROOT / 'fprc', '--target=' + target, src, asm],
                        dict(env, FPR_TYPED_IR_BACKEND=backend), 1)
                assert 'legacy backend has been retired on every target' in p.stderr, p.stderr
                assert asm.read_bytes() == before
            # Cache policy changes do not change compatible module contracts.
            run([ROOT / 'fprc', '--target=' + target, '--plugin', src, asm], env)
            text = asm.read_text()
            data = b''.join(bytes(map(int, row.split(','))) for row in
                            re.findall(r'^\s*\.byte ([0-9, ]+)$', text, re.M))
            stamps = [s for s in data.decode('utf-8', errors='ignore').split('\0')
                      if 'fpr-interface-1/' in s]
            assert stamps and all('/' + interface_targets[target] + '/hardfloat=False/' in s
                                  for s in stamps), (target, stamps)
        # A 65-argument foreign call has no native ABI lowering. It used to
        # select the legacy path: default mode must now refuse it before
        # writing assembly, even when strict mode names some other function.
        bad = tmp / 'unsupported.fpr'
        bad.write_text('Wide.call : ' + ' -> '.join(['Int'] * 66) +
                       ' .\nmain = Wide.call ' + ' '.join(['1'] * 65) + '.\n')
        for target in targets:
            for flags in ({}, {'FPR_TYPED_IR_BACKEND': '1'},
                          {'FPR_TYPED_IR_STRICT': 'someOtherFunction'}):
                asm = tmp / 'unsupported.s'
                p = run([ROOT / 'fprc', '--target=' + target, bad, asm],
                        dict(env, **flags), 1)
                assert 'typed-ir strict: root:' in p.stderr and '\n  main: ' in p.stderr, p.stderr
                assert 'Wide.call' in p.stderr and not asm.exists()
        print('x64 retirement: unsupported foreign calls refused by name in default/whole/named-strict modes on both targets PASS', flush=True)
        print('x64 retirement: two targets, native-only root/imports, whole/mixed warm caches, all rollback aliases refused; all targets typed-only PASS', flush=True)
        if platform.machine() in ('x86_64', 'AMD64'):
            # Exercise the executable cache too, before the compiler is called.
            assert run([ROOT / 'fpr', 'run', src], env).stdout == '42\n'
            for backend in ('legacy', '0', 'off'):
                p = run([ROOT / 'fpr', 'run', src],
                        dict(env, FPR_TYPED_IR_BACKEND=backend), 1)
                assert 'legacy backend has been retired on every target' in p.stdout + p.stderr
            assert run([ROOT / 'fpr', 'run', src], env).stdout == '42\n'
            print('x64 retirement: populated executable cache cannot bypass rollback refusal PASS', flush=True)


if __name__ == '__main__':
    main()
