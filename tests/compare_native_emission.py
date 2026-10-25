#!/usr/bin/env python3
"""Compare native assembly and dependent-unit cache keys with a saved compiler.

Use for architecture-only refactors that promise unchanged output. This is an
explicit two-compiler oracle, not another job in the normal Base sweep.
"""
import argparse
import difflib
import os
from pathlib import Path
import subprocess
import tempfile

from check_x64_scalar import fixture
from check_typed_ir_rv_startup import RVV

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--against', type=Path, required=True)
    parser.add_argument('--compiler', type=Path, default=ROOT / 'fpr')
    args = parser.parse_args()
    compilers = [('before', args.against.resolve()), ('after', args.compiler.resolve())]
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    targets = ('x64', 'qx64', 'x64mac', 'a64', 'a64mac', 'qa64mac', 'rv64', 'rv32')
    with tempfile.TemporaryDirectory(prefix='fpr-emission-compare-') as directory:
        tmp = Path(directory)
        scalar = tmp / 'scalar.fpr'
        scalar.write_text(fixture())
        cases = [('scalar', scalar, {}), ('scalar-no-loops', scalar, {'FPR_TYPED_IR_SELF_LOOPS': '0'}),
                 ('scalar-entry', scalar, {'FPR_TYPED_IR_SHALLOW_STACK': '1', 'FPR_TYPED_IR_FORWARD_PARAMS': '1'})]
        cases += [(name, ROOT / 'tests/typed_ir' / (name + '.fpr'), {}) for name in
                  ('float_trees', 'kernels', 'record_kernels', 'record_float_kernels', 'f32_kernels', 'pairsum_kernels')]
        cases += [('widearity-prelude', ROOT / 'tests/widearity.fpr', {})]
        rvv = tmp / 'rvv.fpr'
        rvv.write_text(RVV)
        raw = tmp / 'raw-library.fpr'
        raw.write_text('profile builtin.\nroundTrip : Addr -> Int -> Int.\n'
                       'roundTrip p x = _ = Mem.write8 p x; Mem.read8 p.\n')
        compared = 0
        for target in targets:
            target_cases = [(name, source, settings, []) for name, source, settings in cases]
            if target in ('rv64', 'rv32'):
                target_cases.append(('rvv-plugin', rvv, {}, ['--system=bare-metal', '--plugin', '--rvv']))
            if target == 'rv64':
                target_cases += [('builtin-arc', ROOT / 'tests/builtin_arc.fpr', {}, ['--profile=bare-metal-builtin', '--arc']),
                                 ('builtin-mixed-raw', ROOT / 'tests/builtin_raw.fpr', {}, ['--profile=bare-metal-builtin', '--arc']),
                                 ('raw-library', raw, {}, ['--profile=bare-metal-builtin', '--arc', '--raw', '--lib', '--export=roundTrip:raw_round_trip'])]
            for name, source, settings, flags in target_cases:
                outputs = []
                for label, compiler in compilers:
                    out = tmp / label / target / name / 'output.s'
                    out.parent.mkdir(parents=True)
                    mode = dict(env, **settings, XDG_CACHE_HOME=str(tmp / label / 'cache'))
                    command = [compiler, 'compile', '--target=' + target, *flags, source, out]
                    if name.endswith('-prelude'):
                        command.insert(3, '--prelude=' + str(ROOT / 'core/prelude.fpr'))
                    result = subprocess.run(list(map(str, command)), cwd=ROOT, env=mode,
                                            capture_output=True, text=True, timeout=180)
                    if result.returncode:
                        raise AssertionError((label, target, name, result.returncode, result.stderr[-5000:]))
                    unit_list = Path(str(out) + '.units')
                    units = [Path(p) for p in unit_list.read_text().splitlines()] if unit_list.exists() else []
                    files = {'root': out.read_text(), **{p.name: p.read_text() for p in units}}
                    if len(files) != 1 + len(units):
                        raise AssertionError('dependent units have ambiguous cache keys')
                    outputs.append(files)
                before, after = outputs
                assert before.keys() == after.keys(), (target, name, 'unit/cache identity changed',
                                                       before.keys() ^ after.keys())
                for key in before:
                    if before[key] != after[key]:
                        diff = ''.join(difflib.unified_diff(before[key].splitlines(True), after[key].splitlines(True),
                                                           fromfile='before/' + key, tofile='after/' + key))
                        raise AssertionError((target, name, diff[:10000]))
                compared += len(before)
            print(f'{target}: {len(target_cases)} root configurations and all dependent units byte-identical', flush=True)
        print(f'Native emission comparison: {compared} root/unit outputs and cache identities unchanged', flush=True)


if __name__ == '__main__':
    main()
