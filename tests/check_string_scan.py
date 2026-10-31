#!/usr/bin/env python3
"""String scan versioning: native bounds/traps/order and selector admission."""
import os
import platform
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = '''unsafe base.
notString : Unit -> String.
scan : unsafe String -> Int -> Int -> Int -> Int.
scan s i n acc = if i >= n then acc else
  _ = print "visit {i}";
  scan s (i + 1) n (acc + charAt s i).
inclusive : unsafe String -> Int -> Int -> Int -> Int.
inclusive s i n acc = if i > n then acc else inclusive s (i + 1) n (acc + charAt s i).
main = case Sys.args Unit of
    ["negative"] -> print (scan "abc" (0 - 1) 2 0)
  | ["upper"] -> print (scan "abc" 0 4 0)
  | ["empty"] -> print (scan "" 0 1 0)
  | ["wrong"] -> print (scan (notString Unit) 0 1 0)
  | ["wrong-empty"] -> print (scan (notString Unit) 4 4 7)
  | ["overflow"] -> print (scan "abc" 0 3 4611686018427387903)
  | ["index-overflow"] -> print (inclusive (notString Unit) 4611686018427387903 4611686018427387903 0)
  | ["near-max"] -> print (scan "abc" 4611686018427387902 4611686018427387903 0)
  | ["zero-max"] -> print (scan (notString Unit) 4611686018427387903 4611686018427387903 9)
  | _ -> print (scan "abc" 1 3 0).
'''
PROBE = '#include "fpr.h"\nstatic V wrong(V u) { (void)u; return TAG(42); }\nFPR_FN(fpr_g_notString, wrong, 1);\n'
CASES = {
    '': (0, 'visit 1\nvisit 2\n197\n', None),
    'negative': (1, 'visit -1\n', 'charAt: index out of range'),
    'upper': (1, 'visit 0\nvisit 1\nvisit 2\nvisit 3\n', 'charAt: index out of range'),
    'empty': (1, 'visit 0\n', 'charAt: index out of range'),
    'wrong': (1, 'visit 0\n', 'charAt: not a string'),
    'wrong-empty': (0, '7\n', None),
    'overflow': (1, 'visit 0\n', 'Int overflow'),
    'index-overflow': (1, '', 'Int overflow'),
    'near-max': (1, 'visit 4611686018427387902\n', 'charAt: index out of range'),
    'zero-max': (0, '9\n', None),
}


def run(args, env):
    p = subprocess.run([str(x) for x in args], cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=240)
    assert p.returncode == 0, p.stdout + p.stderr
    return p


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-string-scan-') as directory:
        tmp = Path(directory)
        source, probe = tmp / 'scan.fpr', tmp / 'probe.c'
        source.write_text(SOURCE)
        probe.write_text(PROBE)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / 'cache'), FPR_TYPED_IR_EARLY_LOOPS='1',
                   FPR_TYPED_IR_LOOP_MOTION='0', FPR_NO_LOOP_REGIONS='1')
        env.pop('FPR_FOREIGN', None)
        # The diagnostic source with visible effects must itself be admitted,
        # otherwise a native differential could pass only through the fallback.
        for enabled in ('0', '1'):
            asm = tmp / f'trace-{enabled}.s'
            p = run([ROOT / 'fpr', 'compile', '--system=posix', source, asm],
                    dict(env, FPR_TYPED_IR_STRING_SCAN=enabled, FPR_TYPED_IR='dump'))
            match = re.search(r'(?ms)^typed-ir: \| fn scan .*?(?=^typed-ir: \| fn |^typed-ir-backend:)', p.stdout + p.stderr)
            assert match, p.stdout[-2000:] + p.stderr[-2000:]
            assert match.group().count('load.byte') == (2 if enabled == '1' else 1), match.group()
        observations = {}
        for inline in ('0', '1'):
            for enabled in ('0', '1', '0'):
                mode = dict(env, FPR_TYPED_IR_STRING_SCAN=enabled, FPR_NO_INLINE=inline)
                exe = tmp / 'scan'
                run([ROOT / 'fpr', 'build', source, '--harts', '4', '--with', probe, '-o', exe], mode)
                for harts in ('1', '4'):
                    for case, (status, prefix, trap) in CASES.items():
                        p = subprocess.run([str(exe)] + ([case] if case else []),
                                           env=dict(mode, FPR_HARTS=harts), capture_output=True, text=True, timeout=20)
                        assert p.returncode == status and p.stdout.startswith(prefix), (enabled, case, p)
                        if trap:
                            assert trap in p.stdout + p.stderr, (enabled, case, p.stdout, p.stderr)
                        else:
                            assert p.stdout == prefix and not p.stderr, (case, p.stdout, p.stderr)
                        result = (p.returncode, p.stdout, p.stderr)
                        key = (inline, harts, case)
                        if key in observations:
                            assert result == observations[key], (enabled, key, result, observations[key])
                        observations[key] = result
                print(f'string scan native: no-inline={inline} range={enabled}, exact bounds/traps/order on 1/4 harts PASS', flush=True)
        can_x64 = platform.system() == 'Darwin' and (
            platform.machine() == 'x86_64' or
            subprocess.run(['arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode == 0)
        if can_x64:
            for enabled in ('0', '1'):
                mode = dict(env, FPR_TYPED_IR_STRING_SCAN=enabled, FPR_NO_INLINE='0')
                exe = tmp / 'scan-x64'
                run([ROOT / 'fpr', 'build', '--target=macos-x86_64', source,
                     '--harts', '4', '--with', probe, '-o', exe], mode)
                for harts in ('1', '4'):
                    for case in CASES:
                        p = subprocess.run([str(exe)] + ([case] if case else []),
                                           env=dict(mode, FPR_HARTS=harts), capture_output=True, text=True, timeout=20)
                        assert (p.returncode, p.stdout, p.stderr) == observations['0', harts, case], (enabled, harts, case, p)
                print(f'string scan x64 Darwin runtime: range={enabled}, exact 1/4-hart differential PASS', flush=True)
        else:
            print('string scan x64 runtime: SKIP (requires Darwin x86-64 or Rosetta)', flush=True)
        # Dump the real benchmark: the optimized loop must actually have no
        # descriptor/bounds miss path, with a checked copy retained in its body.
        for target in ('a64', 'x64', 'rv64', 'rv32'):
            bodies = []
            for enabled in ('0', '1'):
                asm = tmp / f'{target}-{enabled}.s'
                p = run([ROOT / 'fpr', 'compile', f'--target={target}', ROOT / 'tests/bench/byteloop.fpr', asm],
                        dict(env, FPR_TYPED_IR_STRING_SCAN=enabled, FPR_TYPED_IR='dump'))
                text = asm.read_text()
                body = re.search(r'(?ms)^# fn sumB .*?(?=^# fn |\Z)', text)
                assert body, (target, text[-1000:])
                bodies.append(body.group())
            assert (bodies[0] != bodies[1]) == (target != 'rv32'), target
            print(f'string scan emission: {target} versioning boundary PASS', flush=True)


if __name__ == '__main__':
    main()
