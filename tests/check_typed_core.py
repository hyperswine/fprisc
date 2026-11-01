#!/usr/bin/env python3
"""Typed source-to-Core lowering, scope/type/ownership lint and exact erasure."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
env = dict(os.environ)
for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig', '/usr/local/opt/libarchive/lib/pkgconfig'):
    if Path(keg).is_dir():
        env['PKG_CONFIG_PATH'] = keg + ':' + env.get('PKG_CONFIG_PATH', '')
        break
subprocess.run(['make', 'fpr'], cwd=ROOT, env=env, check=True,
               capture_output=True, timeout=300)
sys.path.insert(0, str(ROOT / 'tests'))
from haskell_units import run_units
run_units(['TypedCore', 'TypedLayouts', 'TypedTraps', 'TypedUnits', 'TypedStructs', 'TypedCalls', 'TypedStaging', 'TypedCallbacks', 'TypedProgram', 'RegionInterfaces'], env)
subprocess.run([sys.executable, str(ROOT / 'tests/check_typed_callbacks.py')], cwd=ROOT,
               env=env, check=True, timeout=240)
subprocess.run([sys.executable, str(ROOT / 'tests/check_typed_staging.py')], cwd=ROOT,
               env=env, check=True, timeout=240)
subprocess.run([sys.executable, str(ROOT / 'tests/check_typed_units.py')], cwd=ROOT,
               env=env, check=True, timeout=180)

# An independent native answer catches source/typed-IR agreement on a wrong
# binding, and exercises the real native driver rather than only its helpers.
with tempfile.TemporaryDirectory(prefix='fpr-typed-core-') as directory:
    native = dict(env, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    native.pop('FPR_FOREIGN', None)
    cases = [('calls', 'prefix\nready\nbody\nbody\nfirst\nsecond\nover-first\nentered\nover-second\nover-body\ncomputed\nfactory\nargument\ntyped-calls 7 True 9 True 8 True 10 12 13 15 4 True 15 9 103 12 15 106\n'),
             ('contracts', 'typed-core 14 5 10 9 42 60 19\n'),
             ('closure_layout', 'closure-layout False False True 7 8 9\n'),
             ('recursive_locals', 'recursive-locals 21 7 23 29 21 31 37 41 3 43 47 53\n'),
             ('vector_layouts', 'typed-layouts 2.5 8 3.5 9 4.5 ok 5.5 6.5 0 7.5 11 9 8.5 1 8.5 True\n'),
             ('vector_reads', 'wide\nnarrow\npair\nrecord\nvector-reads 7.5 2.25 17 True 23 False 1 29\n'),
             ('normalization', 'caf\nnormalization 9 10 7 4 True 18\n'),
             ('fusion', 'fusion 16 30 28 5\n'),
             ('structs', 'typed-structs 6 24 7 4 True 5 99 15 9 6 8 False True 7 8 True 102 10 11 True 12 13 6 True 1 3 1\n')]
    for case, expected in cases:
        for harts in (1, 4):
            output = Path(directory) / f'{case}-{harts}'
            built = subprocess.run([str(ROOT / 'fpr'), 'build',
                                    str(ROOT / f'tests/typed_core/{case}.fpr'),
                                    '--harts', str(harts), '-o', str(output)],
                                   cwd=ROOT, env=native, capture_output=True, text=True, timeout=120)
            assert built.returncode == 0, built.stdout + built.stderr
            ran = subprocess.run([str(output)], cwd=ROOT, env=native,
                                 capture_output=True, text=True, timeout=30)
            assert ran.returncode == 0, ran.stdout + ran.stderr
            assert ran.stdout == expected, ran.stdout
            if case == 'fusion':
                staged = subprocess.run([str(output), 'staged'], cwd=ROOT, env=native,
                                        capture_output=True, text=True, timeout=30)
                assert staged.returncode == 0 and staged.stdout == 'capture\nstaged 24\n', (harts, staged.stdout, staged.stderr)
            if case == 'normalization':
                for failure, prefix in [('dead', 'before\n'), ('order', '')]:
                    trapped = subprocess.run([str(output), failure], cwd=ROOT, env=native,
                                             capture_output=True, text=True, timeout=30)
                    assert trapped.returncode == 1 and 'division by zero' in trapped.stdout + trapped.stderr, (harts, failure, trapped.stdout, trapped.stderr)
                    assert trapped.stdout.startswith(prefix) and 'unreachable' not in trapped.stdout and 'second' not in trapped.stdout, (harts, failure, trapped.stdout)
            if case == 'vector_reads':
                for failure, prefix, message in [('at', 'before-at\n', 'Vec.get: index out of range'),
                                                  ('get', 'before-get\n', 'Vec.get: index out of range'),
                                                  ('pattern', 'before-pattern\n', 'let pattern: no match'),
                                                  ('index', '', 'division by zero'),
                                                  ('discard', 'before-discard\n', 'Vec.get: index out of range')]:
                    trapped = subprocess.run([str(output), failure], cwd=ROOT, env=native,
                                             capture_output=True, text=True, timeout=30)
                    assert trapped.returncode == 1 and message in trapped.stdout + trapped.stderr, (harts, failure, trapped.stdout, trapped.stderr)
                    assert trapped.stdout.startswith(prefix) and 'unreachable' not in trapped.stdout, (harts, failure, trapped.stdout)
                    if failure == 'index':
                        assert 'before-index' not in trapped.stdout, trapped.stdout
    # One executable exercises independent failure paths, keeping native
    # builds bounded while checking effects before/after each trap.
    trap_cases = [('scalar', 'before\n', 'typed hole ?? (unimplemented)'),
                  ('piped', 'argument\n', 'typed hole ?? (unimplemented)'),
                  ('function', 'before\nfirst\n', 'typed hole ?? (unimplemented)'),
                  ('partial', 'first\npartial\n', None),
                  ('constructor', 'first\npartial\nsecond\n', 'typed hole ?? in constructor Bad (unimplemented)'),
                  ('saturated', 'first\nsecond\n', 'typed hole ?? in constructor Bad (unimplemented)'),
                  ('shadow', '', 'typed hole ?? (unimplemented)'),
                  ('constructor-shadow', '', 'typed hole ?? in constructor Bad (unimplemented)')]
    for harts in (1, 4):
        output = Path(directory) / f'traps-{harts}'
        built = subprocess.run([str(ROOT / 'fpr'), 'build',
                                str(ROOT / 'tests/typed_core/traps.fpr'),
                                '--harts', str(harts), '-o', str(output)],
                               cwd=ROOT, env=native, capture_output=True, text=True, timeout=120)
        assert built.returncode == 0, built.stdout + built.stderr
        for case, prefix, message in trap_cases:
            ran = subprocess.run([str(output), case], cwd=ROOT, env=native,
                                 capture_output=True, text=True, timeout=30)
            diag = '' if message is None else f'[ERR] {message}\n\n*** FPRISC PANIC [actor 0]: {message} ***\n'
            assert ran.returncode == (0 if message is None else 1), (case, ran.returncode, ran.stdout, ran.stderr)
            assert ran.stdout == prefix and ran.stderr == diag, (case, ran.stdout, ran.stderr)
    named = Path(directory) / 'named.fpr'
    named.write_text('unsafe base. main = print (1 + ?todo).\n')
    refused = subprocess.run([str(ROOT / 'fpr'), 'compile', str(named), str(Path(directory) / 'named.s')],
                             cwd=ROOT, env=native, capture_output=True, text=True, timeout=120)
    assert refused.returncode != 0 and 'typed hole, ?todo : Int' in refused.stdout, refused.stdout + refused.stderr
    shadow = Path(directory) / 'struct-shadow.fpr'
    shadow.write_text('unsafe base. ProbeStructScope = Sig { seed : Int -> t, (+) }. '
                      'ScopeOps = Struct ProbeStructScope { seed = fn n -> n, (+) = fn x y -> x + y }. '
                      'pick (s : ProbeStructScope) n = x = s.seed n; x + x. '
                      'main = pick = fn s n -> n + 100; print (pick ScopeOps 2).\n')
    sol_env = dict(native, SOL_GPU='0', SOL_CACHE_DIR=str(Path(directory) / 'sol-cache'))
    sol = subprocess.run([str(ROOT / 'fpr'), 'sol', str(shadow)], cwd=ROOT, env=sol_env,
                         capture_output=True, text=True, timeout=120)
    assert sol.returncode == 0 and sol.stdout == '102\n', sol.stdout + sol.stderr
    # The new code/capture contracts must reach every ISA's native selector.
    # Execution above is host-native; these are portable emission checks.
    for target in ('x64', 'rv32', 'rv64'):
        output = Path(directory) / f'recursive-{target}.s'
        compiled = subprocess.run([str(ROOT / 'fpr'), 'compile', f'--target={target}',
                                   str(ROOT / 'tests/typed_core/recursive_locals.fpr'), str(output)],
                                  cwd=ROOT, env=native, capture_output=True, text=True, timeout=120)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        code = output.read_text()
        headers = re.findall(r'^# fn (\$typed_recursive_\S+).* typed-ir (\w+) ', code, re.M)
        assert headers and all(isa == target for _, isa in headers), headers
        trap_output = Path(directory) / f'traps-{target}.s'
        compiled = subprocess.run([str(ROOT / 'fpr'), 'compile', f'--target={target}',
                                   str(ROOT / 'tests/typed_core/traps.fpr'), str(trap_output)],
                                  cwd=ROOT, env=native, capture_output=True, text=True, timeout=120)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        trap_code = trap_output.read_text()
        # Native String objects are length-delimited and split into byte
        # directives, rather than printed as quoted assembler strings.
        pools = re.findall(r'^\.Ltirstr_\w+:\n(.*?)(?=^\S[^\n]*:|\Z)', trap_code, re.M | re.S)
        literals = {bytes(int(n.strip()) for line in pool.splitlines()
                          if (match := re.fullmatch(r'\s*\.byte\s+(\d+(?:\s*,\s*\d+)*)\s*', line))
                          for n in match.group(1).split(',')) for pool in pools}
        for message in ('typed hole ?? (unimplemented)', 'typed hole ?? in constructor Bad (unimplemented)'):
            assert message.encode() in literals, (target, message)
        struct_output = Path(directory) / f'structs-{target}.s'
        compiled = subprocess.run([str(ROOT / 'fpr'), 'compile', f'--target={target}',
                                   str(ROOT / 'tests/typed_core/structs.fpr'), str(struct_output)],
                                  cwd=ROOT, env=native, capture_output=True, text=True, timeout=120)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        assert re.search(r'^# fn twice#TypedInts .*typed-ir ' + target + r' ', struct_output.read_text(), re.M), target
        call_output = Path(directory) / f'calls-{target}.s'
        compiled = subprocess.run([str(ROOT / 'fpr'), 'compile', f'--target={target}',
                                   str(ROOT / 'tests/typed_core/calls.fpr'), str(call_output)],
                                  cwd=ROOT, env=native, capture_output=True, text=True, timeout=120)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        assert re.search(r'^# fn .*typed-ir ' + target + r' ', call_output.read_text(), re.M), target
print('Typed Core native contracts: dictionaries, captures, recursive locals, record updates and layout-dependent closure identity on one/four harts passed')
print('Typed recursive locals: x64/RV32/RV64 native emission passed (execution is host-native only)')
print('Typed traps: exact native effects/delays and named-hole refusal on one/four harts; x64/RV32/RV64 emission passed')
print('Typed structures: native one/four-hart answers and closure identity; x64/RV32/RV64 emission passed')
print('Typed calls: native one/four-hart effects, stored partials, polymorphic calls and code identity; x64/RV32/RV64 emission passed')
