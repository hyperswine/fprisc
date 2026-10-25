#!/usr/bin/env python3
"""Typed local clones: native object identity, generic code and strict effects."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'
SOURCE = ROOT / 'tests/typed_core/callbacks.fpr'
EXPECTED = ('prefix\nready\nfirst\npartial-body\ncapture\nsecond\npartial-body\n'
            'callbacks 7 True 9 True 8 True False 12 True 13 17 27 14 4 23\n')


def run(args, env, code=0):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=120)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p


with tempfile.TemporaryDirectory(prefix='fpr-typed-callbacks-') as directory:
    temp = Path(directory)
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
               XDG_CACHE_HOME=str(temp / 'cache'))
    env.pop('FPR_FOREIGN', None)
    # Warm mode changes use one cache. Native PAP equality is pointer identity;
    # the independent machine-IR evaluator alone cannot test this property.
    for harts, specialize, inline in ((1, 0, 0), (1, 1, 0), (1, 0, 1),
                                     (1, 1, 1), (4, 0, 0), (4, 1, 1)):
        mode = dict(env, FPR_NO_SPEC=str(specialize), FPR_NO_INLINE=str(inline))
        exe = temp / 'callbacks'
        run([FPR, 'build', SOURCE, '--harts', harts, '-o', exe], mode)
        normal = run([exe], mode)
        assert normal.stdout == EXPECTED and not normal.stderr, (harts, specialize, inline, normal.stdout, normal.stderr)
        trapped = run([exe, 'panic'], mode, code=1)
        expected = '[ERR] capture panic\n\n*** FPRISC PANIC [actor 0]: capture panic ***\n'
        assert trapped.stdout == expected and not trapped.stderr, (trapped.stdout, trapped.stderr)
    # Exercise owned imported units and root-dependent cache reuse. A new root
    # declaration changes inference IDs but must leave private code stable.
    module = temp / 'provider.fpr'
    module.write_text('unsafe base. value n = apply f x = f x; apply (fn x -> x + 1) n.\n')
    client = temp / 'client.fpr'
    for extra in ('', 'unrelated x = (x,True). '):
        client.write_text(f'unsafe base. M = use "{module}". {extra}main = print (M.value 8).\n')
        out = run([FPR, 'run', client], env)
        assert out.stdout == '9\n' and not out.stderr, (out.stdout, out.stderr)
    # A root clone and the original home entry must return the same static
    # function object for the same capture-free source lambda. Copying a
    # private helper/PAP into the root made this comparison False under Mono.
    provider = temp / 'identity-provider.fpr'
    provider.write_text('unsafe base. produce f x = _ = f x; fn y -> y.\n'
                        'capture f x = _ = f x; fn y -> x + y.\n'
                        'inc x = _ = print "home-callback"; x + 1.\n'
                        'home n = produce inc n. homeCapture n = capture inc n.\n')
    identity = temp / 'identity-client.fpr'
    identity_source = (f'unsafe base. M = use "{provider}".\n'
                       'mark s value = _ = print s; value.\n'
                       'inc x = _ = print "root-callback"; x + 1.\n'
                       'main = a = M.produce inc (mark "argument" 1); b = M.home 1; '
                       'c = M.capture inc 10; d = M.homeCapture 10; alias = c; '
                       'print "private-identity {a == b} {a 7} {b 9} {c == alias} {c == d} {c 7} {d 9}".\n')
    identity.write_text(identity_source)
    expected_identity = ('argument\nroot-callback\nhome-callback\nroot-callback\nhome-callback\n'
                         'private-identity True 7 9 True False 17 19\n')
    for harts, specialize, inline in ((1, 0, 1), (1, 1, 1), (1, 0, 0), (1, 1, 0), (4, 0, 1), (4, 1, 0)):
        mode = dict(env, FPR_NO_SPEC=str(specialize), FPR_NO_INLINE=str(inline))
        exe = temp / 'identity'
        run([FPR, 'build', identity, '--harts', harts, '-o', exe], mode)
        out = run([exe], mode)
        assert out.stdout == expected_identity and not out.stderr, (harts, specialize, inline, out.stdout, out.stderr)
    mode = dict(env, FPR_NO_SPEC='0', FPR_NO_INLINE='1')
    run([FPR, 'build', identity, '--harts', 1, '-o', temp / 'identity'], mode)
    unit_dir = temp / 'cache/fpr/build/units'
    keys = lambda: {p.name: p.stat().st_mtime_ns for p in unit_dir.glob('u-*.s')}
    previous = keys()
    assert previous, 'private import test did not populate its unit cache'
    identity.write_text(f'unsafe base. M = use "{provider}". unrelated x = (x,True). '
                        'main = f = M.home 1; print (f 7).\n')
    out = run([FPR, 'run', identity], mode)
    assert out.stdout == 'home-callback\n7\n' and not out.stderr, (out.stdout, out.stderr)
    assert keys() == previous, 'private home exports depend on which helpers the root imports'
    identity.write_text(identity_source)
    out = run([FPR, 'run', identity], mode)
    assert out.stdout == expected_identity and not out.stderr, (out.stdout, out.stderr)
    assert keys() == previous, 'returning to a private-import caller failed to reuse the home unit'
    # Each provider publishes its home code/PAP with hidden linkage; the root
    # only references them. Test actual object assemblers, not just text shape.
    triples = {'a64': 'aarch64-linux-gnu', 'a64mac': 'arm64-apple-macos11',
               'x64': 'x86_64-linux-gnu', 'x64mac': 'x86_64-apple-macos11',
               'rv32': 'riscv32-unknown-elf', 'rv64': 'riscv64-unknown-elf'}
    clang = shutil.which('clang')
    rv_assembler = shutil.which('riscv64-unknown-elf-as')
    for target, triple in triples.items():
        assembly = temp / f'identity-{target}.s'
        mode = dict(env, FPR_NO_SPEC='0', FPR_NO_INLINE='1')
        run([FPR, 'compile', f'--target={target}', identity, assembly], mode)
        root_text = assembly.read_text()
        home_path = next(Path(p) for p in Path(str(assembly) + '.units').read_text().splitlines()
                         if re.search(r'^# fn produce@', Path(p).read_text(), re.M))
        home_text = home_path.read_text()
        label = next(n for n in re.findall(r'^# fn (\$typed_lifted_\S+) ', home_text, re.M) if '.produce@' in n)
        encoded = ''.join(c if c.isascii() and c.isalnum() else f'_x{ord(c):02x}' for c in label)
        prefix = '_' if target.endswith('mac') else ''
        for kind in ('fn', 'obj'):
            symbol = f'{prefix}fpr_{kind}_{encoded}'
            assert f'{symbol}:' in home_text and f'{symbol}:' not in root_text, (target, kind)
            directive = '.private_extern' if target.endswith('mac') else '.hidden'
            assert f'    .globl {symbol}' in home_text and f'    {directive} {symbol}' in home_text, (target, kind)
        assert 'fpr_obj_' + encoded in root_text, target
        if target.startswith('rv') and rv_assembler:
            flags = ['-march=rv32imafdc', '-mabi=ilp32'] if target == 'rv32' else ['-march=rv64imafdc', '-mabi=lp64']
            for which, path in (('root', assembly), ('home', home_path)):
                run([rv_assembler, *flags, path, '-o', temp / f'{target}-{which}.o'], mode)
        elif not target.startswith('rv') and clang:
            for which, path in (('root', assembly), ('home', home_path)):
                run([clang, '-target', triple, '-c', path, '-o', temp / f'{target}-{which}.o'], mode)
    if not clang:
        print('Private import A64/x64 object assembly: SKIP (clang unavailable)')
    if not rv_assembler:
        print('Private import RV32/RV64 object assembly: SKIP (RISC-V assembler unavailable)')
    # Read-only imported bodies remain available to vector planning. Their
    # static PAPs still belong to the provider, while each kernel copy is local.
    vectors = temp / 'vector-provider.fpr'
    vectors.write_text('unsafe base. mapped before xs = _ = before 0; Vec.map (fn x -> x + 1) xs.\n'
                       'pipeline before xs = _ = before 0; '
                       'a = Vec.map (fn x -> x + 1) xs; b = Vec.filter (fn x -> x > 2) a; '
                       'Vec.fold (fn acc x -> acc + x) 0 b.\n')
    vector_client = temp / 'vector-client.fpr'
    vector_client.write_text(f'unsafe base. M = use "{vectors}". identity x = x. add a b = a + b. '
                             'main = v = M.mapped identity (Vec.fromList (1 :: 2 :: 3 :: [])); '
                             '(a,ra) = Vec.fold add 0 v; (b,rb) = M.pipeline identity (Vec.fromList (1 :: 2 :: 3 :: [])); '
                             '_ = Vec.free ra; _ = Vec.free rb; '
                             'print "private-vectors {a} {b}".\n')
    mode = dict(env, FPR_NO_SPEC='0', FPR_NO_INLINE='1')
    for harts in (1, 4):
        exe = temp / 'private-vectors'
        run([FPR, 'build', vector_client, '--harts', harts, '-o', exe], mode)
        out = run([exe], mode)
        assert out.stdout == 'private-vectors 9 7\n' and not out.stderr, (out.stdout, out.stderr)
    for target in ('a64', 'x64', 'rv32', 'rv64'):
        assembly = temp / f'private-vectors-{target}.s'
        run([FPR, 'compile', f'--target={target}', vector_client, assembly], mode)
        text = assembly.read_text()
        assert re.search(r'^# fn \$vkernel:fpr_vspec_map_', text, re.M), target
        assert re.search(r'^# fn \$vkernel:fpr_vspec_pipeline_', text, re.M), target
        # No kernel implementation has a public symbol contract. Multiple
        # artifacts can specialize a shared home callback without link clashes.
        assert not re.search(r'^\s+\.globl _?fpr_(?:vspec|tkfn)_', text, re.M), target
    # Assert the typed pass itself emitted clones. A legacy .mono label would
    # not prove that checking evidence survived the specialization boundary.
    for target in ('a64', 'x64', 'rv32', 'rv64'):
        assembly = temp / f'{target}.s'
        mode = dict(env, FPR_NO_SPEC='0', FPR_NO_INLINE='1')
        run([FPR, 'compile', f'--target={target}', SOURCE, assembly], mode)
        text = assembly.read_text()
        assert '$typed.mono.' in text or '_24typed_2emono_2e' in text, target
        assert re.search(r'^# fn localPoly .*typed-ir ' + target + r' ', text, re.M), target
print('Typed callbacks: native identity/effects in all optimizer modes, one/four harts, imports and A64/x64/RV32/RV64 emission passed')
print('Private imports: home code/PAP identity, captures/effects, warm cache independence, read-only map/pipeline plans, native visibility and available object assemblers passed')
