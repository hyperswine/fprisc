#!/usr/bin/env python3
"""Early self loops: ABI rotations, exact fuel, fairness, cache and selectors."""
import os
import tempfile
from pathlib import Path
from check_self_loops import ROOT, fixture, run


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-early-loops-') as directory:
        tmp = Path(directory)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / 'cache'), FPR_NO_INLINE='1',
                   FPR_NO_SCALAR_WORKERS='1', FPR_NO_FIELD_WORKERS='1')
        env.pop('FPR_FOREIGN', None)
        source = tmp / 'loops.fpr'
        text, expected = fixture()
        source.write_text(text)
        for early, motion in [('0', '0'), ('1', '0'), ('1', '1'), ('0', '0')]:
            mode = dict(env, FPR_TYPED_IR_EARLY_LOOPS=early,
                        FPR_TYPED_IR_LOOP_MOTION=motion, FPR_TYPED_IR_SELF_LOOPS='1')
            exe = tmp / 'loops'
            run([ROOT / 'fpr', 'build', source, '--harts', '4', '--with',
                 ROOT / 'tests/base/selfloops_probe.c', '-o', exe], mode)
            for harts in ('1', '4'):
                for case, want in expected.items():
                    got = run([exe, case], dict(mode, FPR_HARTS=harts))
                    assert got == want, (early, motion, harts, case, got, want)
            for target in ('a64', 'x64', 'rv32', 'rv64'):
                asm = tmp / f'{target}.s'
                run([ROOT / 'fpr', 'compile', '--target=' + target, source, asm], mode)
                assembly = asm.read_text()
                # These supported self branches use ordinary CFG back edges;
                # the late allocator conversion is no longer needed.
                assert ('_m3loop:' in assembly) == (early == '0'), (early, target)
                assert 'segmax=UNBOUNDED' not in assembly, (early, target)
            print(f'Early loops={early}, motion={motion}: 2/7/8/63 argument rotations, '
                  'effects, exact fuel, stack growth, fairness, 1/4 harts and four selectors PASS', flush=True)


if __name__ == '__main__':
    main()
