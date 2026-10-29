#!/usr/bin/env python3
"""Editor checks accept modules without main and keep real source diagnostics."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-check-only-') as temp:
        work = Path(temp)
        env = {**os.environ, 'FPR_HOME': str(ROOT), 'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(work/'cache'))}
        env.pop('FPR_FOREIGN', None)
        output = work/'out.s'

        def invoke(source, flags=(), success=True):
            result = subprocess.run([str(ROOT/'fpr'), 'compile', *flags, source.name, str(output)],
                                    cwd=work, env=env, capture_output=True, text=True, timeout=120)
            report = result.stdout + result.stderr
            assert (result.returncode == 0) == success, (source.name, flags, report)
            assert not output.exists() and not Path(str(output)+'.units').exists(), report
            return report

        helper = work/'helper.fpr'
        helper.write_text('next : Int -> Int.\nnext x = x + 1.\n')
        for system in ('posix', 'bare-metal', 'qos-native', 'qos-portable'):
            invoke(helper, [f'--system={system}', '--check-only'])
        invoke(helper, ['--system=posix', '--check-only', '--lib'])
        module = work/'module.fpr'
        module.write_text('H = use "./helper".\nanswer = H.next 41.\n')
        invoke(module, ['--system=posix', '--check-only'])
        empty = work/'empty.fpr'; empty.write_text('# a module being written\n')
        invoke(empty, ['--system=posix', '--check-only'])
        print('Check-only: mainless, empty and importing modules accepted; no assembly/manifest output PASS')

        for source, text, marker in (
            ('types.fpr', 'value : Int.\nvalue = "wrong".\n', '=== TYPE ERRORS ==='),
            ('names.fpr', 'value = nobodyDefined 1.\n', 'unbound name: nobodyDefined'),
            ('safety.fpr', 'loop x = loop (x + 1).\n', '=== SAFETY:'),
            ('parse.fpr', 'value = (1 +).\n', 'unexpected'),
            ('imports.fpr', 'M = use "./missing".\nvalue = 1.\n', 'no such module file'),
        ):
            bad = work/source; bad.write_text(text)
            report = invoke(bad, ['--system=posix', '--check-only'], success=False)
            assert marker in report and 'has no `main`' not in report, report
        helper.write_text('next : Int -> Int.\nnext x = "wrong".\n')
        report = invoke(module, ['--system=posix', '--check-only'], success=False)
        assert 'helper.fpr:1:' in report and 'cannot unify' in report, report
        print('Check-only: type/name/parse/safety/import failures retained, imported error located on its source PASS')

        program = work/'program.fpr'
        program.write_text('main = error "CHECK_ONLY_MUST_NOT_RUN".\n')
        invoke(program, ['--system=posix', '--check-only'])
        report = invoke(module, ['--system=posix'], success=False)
        assert 'has no `main`' in report, report
        result = subprocess.run([str(ROOT/'fpr'), 'build', str(module), '-o', str(work/'program')],
                                cwd=work, env=env, capture_output=True, text=True, timeout=120)
        assert result.returncode != 0 and 'has no `main`' in result.stderr, result
        assert not (work/'program').exists()
        report = invoke(helper, ['--system=posix', '--profile=builtin', '--check-only'], success=False)
        assert 'bare-metal system only' in report, report
        print('Check-only never executes main; executable compile/build still require main; profile checks retained PASS')


if __name__ == '__main__':
    main()
