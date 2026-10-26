#!/usr/bin/env python3
"""Constructor reuse cannot introduce writes across a pool reset.

The old constructor is dead in the source before the reset; only an unsafe
optimization would access it afterwards. Cover imported CAFs/helpers, unknown
callbacks and an opaque C entry, independently of inlining/specialization.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compiler', type=Path, default=ROOT / 'fpr')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='fpr-reset-reuse-') as directory:
        tmp = Path(directory)
        (tmp / 'reset.fpr').write_text('''unsafe base.
caf = _ = Sys.poolReset 0; 0.
boundary u = _ = Sys.poolReset 0; 0.
outer u = boundary u.
''')
        source = tmp / 'main.fpr'
        source.write_text('''unsafe base.
Reset = use "reset".
resetForeign : Unit -> Int.
run callback n =
  old = (n,n + 1);
  _ = callback Unit;
  noise = [n + 10,n + 11];
  fresh = (n + 2,n + 3);
  (fresh,noise).
main = case Sys.args Unit of
    ["caf"] -> print (run (fn u -> Reset.caf) 7)
  | ["wrapper"] -> print (run Reset.outer 7)
  | _ -> print (run resetForeign 7).
''')
        probe = tmp / 'reset.c'
        probe.write_text('''#include "fpr.h"
static V reset_entry(V u) {
  (void)u;
  fpr_pool_reset_c();
  return TAG(0);
}
FPR_FN(fpr_g_resetForeign, reset_entry, 1);
''')
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / 'cache'), FPR_NO_LOOP_REGIONS='1',
                   FPR_NO_CALL_REGIONS='1', FPR_NO_FIELD_WORKERS='1', FPR_NO_SCALAR_WORKERS='1')
        env.pop('FPR_FOREIGN', None)
        for no_inline, no_spec in [('0', '0'), ('1', '1')]:
            for no_reuse in ('0', '1'):
                mode = dict(env, FPR_NO_INLINE=no_inline, FPR_NO_SPEC=no_spec, FPR_NO_REUSE=no_reuse)
                exe = tmp / f'run-{no_inline}-{no_reuse}'
                build = subprocess.run([str(args.compiler), 'build', str(source), '--harts', '4',
                                        '--with', str(probe), '-o', str(exe)],
                                       cwd=ROOT, env=mode, capture_output=True, text=True, timeout=180)
                assert build.returncode == 0, build.stdout + build.stderr
                for harts in ('1', '4'):
                    for case in ('caf', 'wrapper', 'foreign'):
                        ran = subprocess.run([str(exe), case], cwd=ROOT, env=dict(mode, FPR_HARTS=harts),
                                             capture_output=True, text=True, timeout=30)
                        assert ran.returncode == 0 and ran.stdout == '((9, 10), [17, 18])\n', (
                            no_inline, no_reuse, harts, case, ran.returncode, ran.stdout, ran.stderr)
                print(f'reset barriers: inline-disabled={no_inline} reuse-disabled={no_reuse}: imported CAF/helper, callback and foreign entry PASS', flush=True)


if __name__ == '__main__':
    main()
