#!/usr/bin/env python3
"""Check RV32 Base float boxing emission and the current Int/Word/I32 boundary.

Run after make fpr. This checks emitted RV32 assembly and compiler refusals;
physical execution is covered by the board numeric and Word smoke programs.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-rv32-base-codegen-') as directory:
        out = Path(directory)

        def compile_(source, target, *, no_float='0', succeeds=True):
            process = subprocess.run(
                [str(ROOT / 'fprc'), '--system=bare-metal', '--target=rv32',
                 '--prelude=' + str(ROOT / 'core/prelude.fpr'), str(source), str(target)],
                cwd=ROOT, env={**os.environ, 'FPR_NO_F64_INLINE': no_float},
                capture_output=True, text=True, timeout=180)
            message = process.stdout + process.stderr
            assert (process.returncode == 0) == succeeds, message
            return message

        for disabled in ('0', '1'):
            target = out / ('float-' + disabled) / 'numeric.s'
            target.parent.mkdir()
            diagnostic = compile_(ROOT / 'tests/tangnano20k_rv32_numeric.fpr', target,
                                  no_float=disabled)
            assembly = '\n'.join(path.read_text() for path in target.parent.rglob('*.s'))
            assert re.search(r'\.Lfloat\d+:\n\s*\.long 9004\n\s*\.long 5\n\s*\.quad 64', assembly), 'F64 literal must use static wide box'
            assert re.search(r'\.Lfloat\d+:\n\s*\.long 9004\n\s*\.long 6\n\s*\.word 32', assembly), 'F32 literal must use static word box'
            assert 'call fpr_f64_from_bits32' not in assembly and 'call fpr_f32_from_bits32' not in assembly, 'literal allocation leaked'
            assert 'software-float mode' in diagnostic, diagnostic
            assert '# ---- Vec specializations' in assembly, 'integer kernels disabled'
            assert not re.search(r'^\s*(?:f(?:add|sub|mul|div|sqrt|mv|cvt|eq|lt|le)\.|fl[wd]\s|fs[wd]\s)',
                                 assembly, re.MULTILINE), 'native float instruction leaked'
            compile_(ROOT / 'tests/tangnano20k_rv32_numeric.fpr', target, no_float=disabled)
            warm = '\n'.join(path.read_text() for path in target.parent.rglob('*.s'))
            assert assembly == warm, 'warm-cache assembly changed'
        print('PASS: RV32 static float literal boxes and generic float callbacks, integer kernels retained, cold/warm')

        compile_(ROOT / 'tests/tangnano20k_rv32_int.fpr', out / 'int.s')
        compile_(ROOT / 'tests/builtin_tangnano20k_word32.fpr', out / 'word.s')
        i32 = out / 'i32.fpr'
        i32.write_text('profile base.\nmain = print "{I32.ofInt 1 + I32.ofInt 2}".\n')
        compile_(i32, out / 'i32.s')
        assert 'fpr_g_I32_x2e_x2b_call2' in (out / 'i32.s').read_text(), 'I32 arithmetic must use its wrapping primitive'
        i32.write_text('profile base.\nmain = I32.ofInt 1 + 2.\n')
        refusal = compile_(i32, out / 'i32-mixed.s', succeeds=False)
        assert 'cannot unify I32 with Int' in refusal or 'cannot unify Int with I32' in refusal, refusal
        outside = out / 'outside.fpr'
        outside.write_text('profile base.\nmain = print "{1073741824}".\n')
        refusal = compile_(outside, out / 'outside.s', succeeds=False)
        assert 'does not fit a tagged rv32 word' in refusal, refusal
        f32 = out / 'builtin-f32.fpr'
        f32.write_text('profile builtin.\nmain = F32.toInt 1f.\n')
        refusal = compile_(f32, out / 'builtin-f32.s', succeeds=False)
        assert 'F32 also requires the boxed Base runtime' in refusal, refusal
        print('PASS: Int31, Word32 and wrapping I32 compile; mixed I32/Int, oversized Int and Builtin F32 refused')


if __name__ == '__main__':
    main()
