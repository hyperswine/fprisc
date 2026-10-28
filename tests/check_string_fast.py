#!/usr/bin/env python3
"""Guarded inline String reads: values, fallbacks, bounds and trap order."""
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = '''unsafe base.
notString : Unit -> String.
idx : Int -> Int.
idx i = _ = print "index"; i.
run u =
  s = "hello, FP-RISC!";
  n = strlen s;
  a = charAt s (idx 0); b = charAt s (idx (n - 1));
  e = ""; m = strlen e;
  print "len {n} first {a} last {b} empty {m}".
main = case Sys.args Unit of
    ["negative"] -> print (charAt "abc" (idx (0 - 1)))
  | ["upper"] -> print (charAt "abc" (idx 3))
  | ["empty"] -> print (charAt "" (idx 0))
  | ["notstring"] -> print (charAt (notString Unit) 0)
  | ["strlen-notstring"] -> print (strlen (notString Unit))
  | _ -> run Unit.
'''
PROBE = '''#include "fpr.h"
static V not_string(V u) { (void)u; return TAG(42); }
FPR_FN(fpr_g_notString, not_string, 1);
'''
EXPECTED = 'index\nindex\nlen 15 first 104 last 33 empty 0\n'


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-string-fast-') as directory:
        tmp = Path(directory)
        source = tmp / 'reads.fpr'
        probe = tmp / 'probe.c'
        source.write_text(SOURCE)
        probe.write_text(PROBE)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / 'cache'))
        env.pop('FPR_FOREIGN', None)
        for no_inline in ('0', '1'):
            # Alternate within the same cache to catch missing option identities.
            for no_fast in ('0', '1', '0'):
                mode = dict(env, FPR_NO_INLINE=no_inline, FPR_NO_STR_FAST=no_fast)
                exe = tmp / 'reads'
                p = subprocess.run([str(ROOT / 'fpr'), 'build', source, '--harts', '4', '--with', probe, '-o', exe],
                                   cwd=ROOT, env=mode, capture_output=True, text=True, timeout=180)
                assert p.returncode == 0, p.stdout + p.stderr
                for harts in ('1', '4'):
                    native = dict(mode, FPR_HARTS=harts)
                    p = subprocess.run([exe], env=native, capture_output=True, text=True, timeout=30)
                    assert p.returncode == 0 and p.stdout == EXPECTED, (no_inline, no_fast, harts, p.returncode, p.stdout, p.stderr)
                    for case, prefix, message in [
                        ('negative', 'index\n', 'charAt: index out of range'),
                        ('upper', 'index\n', 'charAt: index out of range'),
                        ('empty', 'index\n', 'charAt: index out of range'),
                        ('notstring', '', 'charAt: not a string'),
                        ('strlen-notstring', '', 'strlen: not a string')]:
                        p = subprocess.run([exe, case], env=native, capture_output=True, text=True, timeout=30)
                        assert p.returncode == 1 and p.stdout.startswith(prefix) and message in p.stdout + p.stderr, (
                            no_inline, no_fast, harts, case, p.returncode, p.stdout, p.stderr)
                print(f'string fast: no-inline={no_inline} no-fast={no_fast}: values, bounds, fallback and trap order 1/4 harts PASS', flush=True)
        # The emitted body has a guarded direct read on 64-bit selectors and
        # an original C miss path. RV32 retains its C entry.
        emission = tmp / 'emission.fpr'
        emission.write_text('unsafe base. readByte s i = charAt s i. main = Unit.\n')
        for target in ('a64', 'x64', 'rv64', 'rv32'):
            outputs = []
            for disabled in ('0', '1'):
                assembly = tmp / f'{target}-{disabled}.s'
                p = subprocess.run([str(ROOT / 'fpr'), 'compile', f'--target={target}', emission, assembly],
                                   cwd=ROOT, env=dict(env, FPR_NO_STR_FAST=disabled, FPR_NO_INLINE='1'),
                                   capture_output=True, text=True, timeout=180)
                assert p.returncode == 0, p.stdout + p.stderr
                text = assembly.read_text()
                body = re.search(r'(?ms)^# fn readByte .*?(?=^# fn |\Z)', text)
                assert body, (target, text[-1000:])
                outputs.append(body.group())
            assert (outputs[0] != outputs[1]) == (target != 'rv32'), target
            print(f'string read emission: {target} fast/fallback boundary PASS', flush=True)


if __name__ == '__main__':
    main()
