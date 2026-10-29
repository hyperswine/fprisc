#!/usr/bin/env python3
"""Guarded native scalar Vector reads: bits, mutation, fallbacks and traps."""
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = '''unsafe base.
wideValue : Int -> F64.
narrowValue : Int -> F32.
wideBits : F64 -> String.
narrowBits : F32 -> String.
badIndex : Int -> Int.
badHandle : Unit -> Vector Int.
index i = _ = print "index"; i.
pushRead i acc v = if i == 80 then (acc,v) else
  w = Vec.push i v; (x,w) = Vec.at i w; pushRead (i + 1) (acc + x) w.
emptyWide : Unit -> Vector F64.
emptyWide u = Vec.fromList [].
run u =
  ints = Vec.fromList [(-3),0,41];
  (a,ints) = Vec.at (index 0) ints; (b,ints) = Vec.get 2 ints;
  ints = Vec.put 2 99 ints; (c,ints) = Vec.at 2 ints; (n,ints) = Vec.len ints;
  _ = print "ints {a} {b} {c} {n}"; _ = Vec.free ints;
  (total,grown) = pushRead 0 0 (Vec.new Unit); (n,grown) = Vec.len grown;
  _ = print "grow {total} {n}"; _ = Vec.free grown;
  wide = Vec.fromList [wideValue 0,wideValue 1,wideValue 2,wideValue 3];
  (a,wide) = Vec.at 0 wide; (b,wide) = Vec.get 1 wide;
  (c,wide) = Vec.at 2 wide; (d,wide) = Vec.get 3 wide;
  _ = print "wide {wideBits a} {wideBits b} {wideBits c} {wideBits d}"; _ = Vec.free wide;
  narrow = Vec.fromList [narrowValue 0,narrowValue 1,narrowValue 2,narrowValue 3];
  (a,narrow) = Vec.at 0 narrow; (b,narrow) = Vec.get 1 narrow;
  (c,narrow) = Vec.at 2 narrow; (d,narrow) = Vec.get 3 narrow;
  _ = print "narrow {narrowBits a} {narrowBits b} {narrowBits c} {narrowBits d}"; _ = Vec.free narrow;
  strings = Vec.fromList ["fallback"]; (s,strings) = Vec.at 0 strings;
  rows = Vec.fromList [{x=17,ok=True}]; (r,rows) = Vec.get 0 rows;
  pairs = Vec.fromList [(23,False)]; ((p,q),pairs) = Vec.at 0 pairs;
  _ = print "fallback {s} {r.x} {r.ok} {p} {q}";
  _ = Vec.free strings; _ = Vec.free rows; _ = Vec.free pairs;
  empty = emptyWide Unit; (n,empty) = Vec.len empty;
  _ = print "empty {n}"; Vec.free empty.
main = case Sys.args Unit of
    ["negative"] -> v = Vec.iota 2; (x,v) = Vec.at (index (-1)) v; _ = Vec.free v; print x
  | ["upper"] -> v = Vec.iota 2; (x,v) = Vec.get (index 2) v; _ = Vec.free v; print x
  | ["empty"] -> v = emptyWide Unit; (x,v) = Vec.at (index 0) v; _ = Vec.free v; print x
  | ["at-types"] -> (x,v) = Vec.at (badIndex 0) (badHandle Unit); _ = Vec.free v; print x
  | ["get-types"] -> (x,v) = Vec.get (badIndex 0) (badHandle Unit); _ = Vec.free v; print x
  | ["index-trap"] -> (x,v) = Vec.at (1 / 0) (badHandle Unit); _ = Vec.free v; print x
  | _ -> run Unit.
'''
PROBE = '''#include "fpr.h"
static V wide_value(V i) { const uint64_t bits[]={0x8000000000000000ULL,0x7ff0000000000000ULL,0x7ff8000000000123ULL,0xfff0000000000000ULL}; return (V)bits[UNTAG(i)&3]; }
static V narrow_value(V i) { const uint32_t bits[]={0x80000000U,0x7f800000U,0x7fc00123U,0xff800000U}; return (V)bits[UNTAG(i)&3]; }
static V hex_bits(V x, unsigned count) { char b[16]; const char*hex="0123456789abcdef"; for(unsigned i=0;i<count;i++) b[i]=hex[((uw)x >> (4*(count-1-i)))&15]; return (V)fpr_mkstr(b,count); }
static V wide_bits(V x) { return hex_bits(x,16); }
static V narrow_bits(V x) { return hex_bits(x,8); }
static V bad_index(V x) { (void)x; return BOOL(0); }
static V bad_handle(V x) { (void)x; return TAG(42); }
FPR_FN(fpr_g_wideValue,wide_value,1);
FPR_FN(fpr_g_narrowValue,narrow_value,1);
FPR_FN(fpr_g_wideBits,wide_bits,1);
FPR_FN(fpr_g_narrowBits,narrow_bits,1);
FPR_FN(fpr_g_badIndex,bad_index,1);
FPR_FN(fpr_g_badHandle,bad_handle,1);
'''
EXPECTED = ('index\nints -3 41 99 3\ngrow 3160 80\n'
            'wide 8000000000000000 7ff0000000000000 7ff8000000000123 fff0000000000000\n'
            'narrow 80000000 7f800000 7fc00123 ff800000\n'
            'fallback fallback 17 True 23 False\nempty 0\n')


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-vector-fast-') as directory:
        tmp = Path(directory)
        source, probe = tmp / 'reads.fpr', tmp / 'probe.c'
        source.write_text(SOURCE)
        probe.write_text(PROBE)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache')))
        env.pop('FPR_FOREIGN', None)
        for no_inline in ('0', '1'):
            # Alternate within the same cache to catch missing option identities.
            for no_fast in ('0', '1', '0'):
                mode = dict(env, FPR_NO_INLINE=no_inline, FPR_NO_VEC_FAST=no_fast)
                exe = tmp / 'reads'
                p = subprocess.run([str(ROOT / 'fpr'), 'build', source, '--harts', '4', '--with', probe, '-o', exe],
                                   cwd=ROOT, env=mode, capture_output=True, text=True, timeout=180)
                assert p.returncode == 0, p.stdout + p.stderr
                for harts in ('1', '4'):
                    native = dict(mode, FPR_HARTS=harts)
                    p = subprocess.run([exe], env=native, capture_output=True, text=True, timeout=30)
                    assert p.returncode == 0 and p.stdout == EXPECTED, (no_inline, no_fast, harts, p.returncode, p.stdout, p.stderr)
                    for case, prefix, message in [
                        ('negative', 'index\n', 'Vec.get: index out of range'),
                        ('upper', 'index\n', 'Vec.get: index out of range'),
                        ('empty', 'index\n', 'Vec.get: index out of range'),
                        ('at-types', '', 'Vec.at: index not an Int'),
                        ('get-types', '', 'Vec.get: not a Vector'),
                        ('index-trap', '', 'division by zero')]:
                        p = subprocess.run([exe, case], env=native, capture_output=True, text=True, timeout=30)
                        assert p.returncode == 1 and p.stdout.startswith(prefix) and message in p.stdout + p.stderr, (
                            no_inline, no_fast, harts, case, p.returncode, p.stdout, p.stderr)
                print(f'vector fast: no-inline={no_inline} no-fast={no_fast}: bits, growth, fallback, bounds and trap order 1/4 harts PASS', flush=True)
        # The emitted body has a guarded direct read on 64-bit selectors and
        # an original C miss path. RV32 retains its boxed-float ABI.
        emission = tmp / 'emission.fpr'
        emission.write_text('unsafe base. readInt i v = (x,v) = Vec.at i v; (x,v). main = Unit.\n')
        for target in ('a64', 'x64', 'rv64', 'rv32'):
            outputs = []
            for disabled in ('0', '1'):
                assembly = tmp / f'{target}-{disabled}.s'
                p = subprocess.run([str(ROOT / 'fpr'), 'compile', f'--target={target}', emission, assembly],
                                   cwd=ROOT, env=dict(env, FPR_NO_VEC_FAST=disabled, FPR_NO_INLINE='1'),
                                   capture_output=True, text=True, timeout=180)
                assert p.returncode == 0, p.stdout + p.stderr
                text = assembly.read_text()
                body = re.search(r'(?ms)^# fn readInt .*?(?=^# fn |\Z)', text)
                assert body, (target, text[-1000:])
                outputs.append(body.group())
            assert (outputs[0] != outputs[1]) == (target != 'rv32'), target
            print(f'vector read emission: {target} fast/fallback boundary PASS', flush=True)


if __name__ == '__main__':
    main()
