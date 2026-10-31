#!/usr/bin/env python3
"""The posix runtime under UBSan: listing an EMPTY directory (machine/posix/os_fs.c
used to call qsort(NULL, 0), which is undefined behaviour) and a small std program
must run with no `runtime error` report. FPR_CC selects the sanitizing compiler and
is part of the build cache identity (compiler/Build.hs)."""
import os, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
SRC = '''Dir = use "std/dir".
main = case Dir.list (Sys.args Unit |> List.head |> O.withDefault ".") of
    Ok xs -> print "entries {List.length xs}"
  | Err e -> print "error {e}".
List = use "std/list".
O = use "std/option".
'''
with tempfile.TemporaryDirectory(prefix='fpr-ubsan-') as d:
    tmp = Path(d)
    cc = tmp / 'ubcc'
    cc.write_text('#!/bin/sh\nexec "${UBSAN_BASE_CC:-cc}" -fsanitize=undefined -fno-sanitize-recover=undefined "$@"\n')
    cc.chmod(0o755)
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_CC=str(cc), XDG_CACHE_HOME=str(tmp / 'cache'),
               UBSAN_OPTIONS='print_stacktrace=1:halt_on_error=1')
    (tmp / 'empty').mkdir()
    progs = [(tmp / 'dir.fpr', [str(tmp / 'empty')], 'entries 0\n')]
    progs[0][0].write_text(SRC)
    extra = sys.argv[1:] or ['tests/std/list.fpr', 'tests/std/string.fpr', 'tests/std/map.fpr']
    for src in extra:
        p = ROOT / src
        progs.append((p, [], p.with_suffix('.expected').read_text()))
    for src, args, want in progs:
        exe = tmp / (src.stem + '.ubsan')
        b = subprocess.run([str(ROOT / 'fpr'), 'build', str(src), '-o', str(exe)], cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
        assert b.returncode == 0, (src, b.stdout[-2000:], b.stderr[-2000:])
        r = subprocess.run([str(exe), *args], cwd=tmp, env=env, capture_output=True, text=True, timeout=300)
        assert 'runtime error' not in r.stderr, (src, r.stderr[-3000:])
        assert r.returncode == 0 and r.stdout == want, (src, r.returncode, r.stdout[-500:], r.stderr[-1000:])
        print(f'ubsan {src.name}: PASS')
