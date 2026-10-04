#!/usr/bin/env python3
"""MVU ordering, env replacement/refusal and rendering with a test-only clock."""
import os
import subprocess
import tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'tests/base/mvureload.fpr').read_text()
TRACE = ('frame 0: [factor=2 acc=2] builds=1\nadapter: v2\n'
         'frame 1: [factor=3 acc=5] builds=2\nadapter: bad\nadapter: stale\n'
         'frame 2: [factor=3 acc=11] builds=2\n'
         'reload: acc=11 refused=2 [mvu: 3 frames, 2 statics builds]\n')
variants = [('runner', SOURCE, TRACE),
    ('observe', SOURCE.replace('  | other -> (m, Nil).',
       '  | MV.EReload info -> print "event: {env.factor} {env.hash}" >> (m, Nil)\n  | other -> (m, Nil).', 1),
       TRACE.replace('adapter: v2\n', 'adapter: v2\nevent: 3 v2\n')),
    ('legacy', SOURCE.replace('MV.runLive (myself 0) cfg app reload', 'MV.run (myself 0) cfg app'),
       'frame 0: [factor=2 acc=2] builds=1\nframe 1: [factor=2 acc=4] builds=1\n'
       'frame 2: [factor=2 acc=8] builds=1\nreload: acc=8 refused=3 [mvu: 3 frames, 1 statics builds]\n'),
    ('liveapp', SOURCE.replace('app = MV.MApp init update key statics vals done subs;',
       'app = MV.LiveApp init (update 0) subs (vals 0);').replace('MV.runLive (myself 0) cfg app reload',
       'MV.gameLive (myself 0) cfg app reload').replace('vals self env vp m =', 'vals self env m ='),
       TRACE.replace('reload: acc=11 refused=2', 'game over'))]
# The LiveApp view receives env and model (no viewport argument).
variants.append(('legacyapp', SOURCE.replace(
    'app = MV.MApp init update key statics vals done subs;',
    'app = MV.App init (update 0) subs oldView;').replace(
    'MV.runLive (myself 0) cfg app reload', 'MV.game (myself 0) cfg app') +
    '\noldView m = "factor=2 acc={m.acc}" :: Nil.\n',
    'frame 0: [factor=2 acc=2] builds=1\nframe 1: [factor=2 acc=4] builds=1\n'
    'frame 2: [factor=2 acc=8] builds=1\ngame over [mvu: 3 frames, 1 statics builds]\n'))
# Invalid baselines refuse before entering the platform attachment callback.
variants.append(('baseline', SOURCE.replace('main =\n',
    'Reload = use "std/reload".\nneverAttach bytes = error "unexpected attachment".\nmain =\n'
    '  _ = print "{Reload.attachAt (0 - 1) neverAttach \"\"}";\n'
    '  _ = print "{Reload.attachAt 0 neverAttach \"\"}";\n'),
    'Err reload: invalid baseline table\nErr reload: missing baseline table\n' + TRACE))
with tempfile.TemporaryDirectory(prefix='fpr-mvu-reload-') as d:
    tmp = Path(d)
    for name, source, expected in variants:
        src = tmp / (name + '.fpr'); src.write_text(source)
        exe = tmp / name
        p = subprocess.run([str(ROOT/'fpr'), 'build', str(src), '--with',
                            str(ROOT/'tests/base/mvuclock.c'), '-o', str(exe)],
                           cwd=ROOT, capture_output=True, text=True, timeout=180)
        assert p.returncode == 0, p.stdout + p.stderr
        for harts in ('1', '4', '4', '4'):
            p = subprocess.run([str(exe)], env={**os.environ, 'FPR_HARTS': harts},
                               capture_output=True, text=True, timeout=30)
            assert p.returncode == 0 and p.stdout == expected, (name, harts, p.stdout, p.stderr)
        print(f'MVU reload {name}: one/four harts PASS')
