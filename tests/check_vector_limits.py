#!/usr/bin/env python3
"""Vector layout evidence, recursive float products, direct maps and folds."""
from pathlib import Path
import os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
def run(args, expected=0, env=None):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
    assert p.returncode == expected, (args,p.returncode,p.stdout,p.stderr)
    return p
with tempfile.TemporaryDirectory(prefix='fpr-vector-limits-') as directory:
    tmp = Path(directory)
    expected = ('generic: 2.5 7 yes 2.5 3.5 4.5\n'
                'nested: 2 4 4 2 second=2 one=2.5 sum=2.5\n'
                'fold: 100020007 9999 45 9\n'
                'record fold: 193\nmapAs: 0 9\n')
    exe = tmp/'limits'
    p = run(['./fpr','build','-v','tests/base/veclimits.fpr','-o',exe])
    assert 'Vec.fold over `step`' not in p.stdout and 'Vec.fold over `rstep`' not in p.stdout, p.stdout
    for harts in ('1','4'):
        for no_inline, no_spec in (('0','0'), ('1','0'), ('0','1')):
            env = {**os.environ,'FPR_HARTS':harts,'FPR_NO_INLINE':no_inline,'FPR_NO_SPEC':no_spec}
            run(['./fpr','build','tests/base/veclimits.fpr','-o',exe],env=env)
            p = run([exe],env=env)
            assert p.stdout == expected, (p.stdout,p.stderr)
    local=tmp/'local.fpr'
    local.write_text('unsafe base.\nmain = build x = Vec.push x (Vec.new Unit); '
                     '(a,v) = Vec.at 0 (build 2.5); _ = Vec.free v; '
                     '(b,w) = Vec.at 0 (build 8); _ = Vec.free w; '
                     'lam = fn x -> Vec.push x (Vec.new Unit); '
                     '(c,u) = Vec.at 0 (lam 3.5); _ = Vec.free u; print "local: {a} {b} {c}".\n')
    run(['./fpr','build',local,'-o',exe])
    assert run([exe]).stdout == 'local: 2.5 8 3.5\n'
    # Layout requirements can propagate through more than 32 wrappers.
    chain = tmp/'chain.fpr'
    chain.write_text('unsafe base.\nmake0 x = Vec.push x (Vec.new Unit).\n'+
                     ''.join(f'make{i} x = make{i-1} x.\n' for i in range(1, 41))+
                     'main = (x,v) = Vec.at 0 (make40 2.5); _ = Vec.free v; print x.\n')
    run(['./fpr','build',chain,'-o',exe])
    assert run([exe]).stdout == '2.5\n'
    # Independent obligations must stay linked to their respective types.
    multiple = tmp/'multiple.fpr'
    multiple.write_text('unsafe base.\n'
                        'two x y = (Vec.push x (Vec.new Unit), Vec.push y (Vec.new Unit)).\n'
                        'record x = Vec.push {x=x} (Vec.new Unit).\n'
                        'main = (a,b) = two 2.5 8; (x,a2) = Vec.at 0 a; (y,b2) = Vec.at 0 b; '
                        '_ = Vec.free a2; _ = Vec.free b2; '
                        '(r,v) = Vec.at 0 (record 3.5); _ = Vec.free v; print "{x} {y} {r.x}".\n')
    run(['./fpr','build',multiple,'-o',exe])
    assert run([exe]).stdout == '2.5 8 3.5\n'
    # Imported dictionaries must agree in the cached home unit and its caller.
    module=tmp/'builders.fpr'
    module.write_text('build : a -> Vector a.\nbuild x = Vec.push x (Vec.new Unit).\nwrap x = build x.\n')
    caller=tmp/'import.fpr'
    caller.write_text('unsafe base.\nG = use "'+str(module.with_suffix(''))+'".\n'
                      'main = (x,v) = Vec.at 0 (G.wrap 2.5); _ = Vec.free v; '
                      '(i,w) = Vec.at 0 (G.wrap 9); _ = Vec.free w; print "import: {x} {i}".\n')
    for _ in range(2):
        run(['./fpr','build',caller,'-o',exe])
        assert run([exe]).stdout == 'import: 2.5 9\n'
    # The direct callback retains exact eager traversal and panic behavior.
    p = run(['./fpr','build','-v','tests/base/vecmapas_fail.fpr','-o',exe])
    p = run([exe],1)
    assert p.stdout.startswith('visited 0\nvisited 1\n') and 'type-changing map failed on 2' in p.stdout+p.stderr, p.stdout+p.stderr
    assert 'visited 3' not in p.stdout and 'unreachable' not in p.stdout, p.stdout
    for target in ('rv64','a64','x64'):
        asm=tmp/(target+'.s')
        run(['./fprc','--profile=base','--target='+target,'tests/base/veclimits.fpr',asm])
        text=asm.read_text()
        assert 'Vec.mapAs direct scalar kernel on toFloat' in text, target
        assert 'Vec.fold specialized on rstep' in text, target
        if target == 'x64':
            run(['clang','--target=x86_64-linux-gnu','-c',asm,'-o',tmp/'x64.o'])
    run(['./fprc','--profile=base','--target=rv32','tests/base/veccaps_fold.fpr',tmp/'rv32.s'])
    print('Vector limits: generic/imported/recursive layouts, nested float records and copies, captured/wide folds, direct type-changing map and ordered failure; 64-bit layouts and RV32 integer fold emission PASS')
