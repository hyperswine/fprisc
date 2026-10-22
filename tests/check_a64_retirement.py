#!/usr/bin/env python3
"""A64 is typed-only: every target/unit, rollback refusals and warm run caches."""
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
    with tempfile.TemporaryDirectory(prefix='fpr-a64-retirement-') as d:
        tmp = Path(d)
        env = dict(ENV, XDG_CACHE_HOME=str(tmp / 'cache'))
        src = tmp / 'probe.fpr'
        src.write_text('inc n = n + 1.\nmain = print (inc 41).\n')
        targets = ('a64', 'a64mac', 'qa64', 'qa64single', 'qa64mac')
        interface_targets = dict(zip(targets, ('a64x28r15', 'a64macx28r15',
                                              'qa64r15', 'qa64singler15', 'qa64macr15')))
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
                    assert all(' typed-ir a64 ' in h for h in headers), (path, headers)
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
                assert 'AArch64 legacy backend has been retired' in p.stderr, p.stderr
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
        # The other translators/generators still own their rollback path.
        for target in ('rv64', 'rv32', 'x64'):
            asm = tmp / (target + '.s')
            run([ROOT / 'fprc', '--target=' + target, src, asm],
                dict(env, FPR_TYPED_IR_BACKEND='legacy'))
            assert '# wcet:' in asm.read_text() and 'typed-ir ' not in asm.read_text()
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
        print('A64 retirement: unsupported foreign calls refused by name in default/whole/named-strict modes on all five targets PASS', flush=True)
        print('A64 retirement: five targets, native-only root/imports, whole/mixed warm caches, all rollback aliases refused; RV/x64 rollback retained PASS', flush=True)
        if platform.machine() in ('arm64', 'aarch64'):
            # Exercise the executable cache too, before the compiler is called.
            assert run([ROOT / 'fpr', 'run', src], env).stdout == '42\n'
            for backend in ('legacy', '0', 'off'):
                p = run([ROOT / 'fpr', 'run', src],
                        dict(env, FPR_TYPED_IR_BACKEND=backend), 1)
                assert 'AArch64 legacy backend has been retired' in p.stdout + p.stderr
            assert run([ROOT / 'fpr', 'run', src], env).stdout == '42\n'
            print('A64 retirement: populated executable cache cannot bypass rollback refusal PASS', flush=True)
        # Imported polymorphic layout evidence introduces hidden runtime
        # names after declaration collection. Both aliases must lower natively
        # while preserving actual Int/F64/boxed column representations.
        lib = tmp / 'layouts.fpr'
        lib.write_text('''create : (n : Int | n > 0) -> a -> Vector a.
create n value = Vec.fromList [value].
mapDyn : (a -> b) -> Vector a -> Vector b.
mapDyn f v = Vec.map f v.
''')
        host = tmp / 'layout-host.fpr'
        host.write_text('''unsafe base.
M = use "layouts.fpr".
main =
  v = M.create 1 41; u = M.mapDyn (fn x -> x + 1) v;
  (n, u2) = Vec.get 0 u; _ = Vec.free u2; _ = print n;
  v = M.create 1 1.5; u = M.mapDyn (fn x -> x + 2.0) v;
  (n, u2) = Vec.get 0 u; _ = Vec.free u2; _ = print n;
  v = M.create 1 "ok"; u = M.mapDyn (fn x -> x + "!") v;
  (n, u2) = Vec.get 0 u; _ = Vec.free u2; print n.
''')
        exe = tmp / 'layouts'
        mode = dict(env, FPR_TYPED_IR_BACKEND='mixed', FPR_TYPED_IR_STRICT='all')
        run([ROOT / 'fpr', 'build', host, '-o', exe], mode)
        for harts in ('1', '4'):
            assert run([exe], dict(mode, FPR_HARTS=harts)).stdout == '42\n3.5\nok!\n'
        print('Typed inference runtime entries: imported polymorphic fromList/map, Int/F64/boxed columns, strict native emission, one/four harts PASS', flush=True)
        # A source arity hint can differ from the actual runtime PAP arity.
        # The C side intentionally exports only _call2 for both objects.
        bridge = tmp / 'hal-apply.c'
        bridge.write_text('''#include "fpr.h"
static V add(V a, V b) { return a + b - 1; }
FPR_FN(fpr_g_HalApply_x2eadd, add, 2);
FPR_FN(fpr_g_HalApply_x2eopaque, add, 2);
''')
        host.write_text('''unsafe base.
HalApply.add : Int -> Int -> Int.
HalApply.opaque : a -> b.
partial n = f = HalApply.add n; f (n + 1).
opaque n = HalApply.opaque n (n + 2).
main = _ = print (partial 20); print (opaque 20).
''')
        run([ROOT / 'fpr', 'build', host, '--with', bridge, '-o', exe], mode)
        for harts in ('1', '4'):
            assert run([exe], dict(mode, FPR_HARTS=harts)).stdout == '41\n42\n'
        print('Typed HAL application: actual C PAP arity, partial and opaque calls, strict native emission, one/four harts PASS', flush=True)


if __name__ == '__main__':
    main()
