"""Coverage is never dropped when CI configurations are deduplicated."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_ci
from check_registry import BASE, CI, GROUPS, Check, ci


class CoverageTests(unittest.TestCase):
    def test_all_base_paths_exist_and_are_unique(self):
        self.assertEqual(len(BASE), len({c.id for c in BASE}))
        for c in BASE:
            self.assertTrue((check_ci.ROOT / c.path).is_file(), c.path)
        for c in CI.values():
            self.assertTrue((check_ci.ROOT / c.path).is_file(), c.path)

    def test_required_modes_and_default_have_same_coverage(self):
        for c in CI.values():
            if c.args == ('--require-execution',):
                self.assertEqual(c.covers, (c.path,) if c.path in {b.id for b in BASE} else ())
        self.assertFalse(CI['tests/check_typed_ir_x64.py::entry-optimizations'].covers)
        self.assertFalse(CI['tests/check_rv64_linux.py::typed-runtime'].covers)
        self.assertEqual(CI['tests/check_rv64_linux.py::runtime'].covers, ('tests/check_rv64_linux.py',))

    def test_old_explicit_configurations_are_preserved(self):
        # Lock down the execution obligations during the move out of YAML.
        self.assertEqual(len(CI), 31)
        self.assertEqual(len({(c.path, c.args, c.env) for c in CI.values()}), len(CI))
        with self.assertRaisesRegex(ValueError, 'variant'):
            ci('tests/check_typed_ir_x64.py', required=True, env=(('FPR_NO_INLINE', '1'),))
        rv = [c for c in CI.values() if c.path == 'tests/check_typed_ir_rv.py']
        self.assertEqual({c.args for c in rv}, {
            ('--require-execution', '--width', '32'), ('--require-execution', '--width', '64')})
        x64 = [c for c in CI.values() if c.path == 'tests/check_typed_ir_x64.py']
        self.assertEqual({c.args for c in x64}, {
            ('--require-execution',), ('--require-execution', '--entry-optimizations')})
        # A strict ARC child is not used to remove the default raw invocation.
        self.assertIn('tests/check_raw.py', CI)

    def test_workflow_runs_every_group_and_verifies_before_base(self):
        workflow = (check_ci.ROOT / '.github/workflows/ci.yml').read_text()
        for group in GROUPS:
            self.assertEqual(workflow.count('--group ' + group + ' '), 1)
        self.assertLess(workflow.index('--verify'), workflow.index('--completed'))
        self.assertNotIn('--skip-typed-ir-native', workflow)

    def test_receipts_cover_only_successes_and_reject_changed_context(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'results.json'
            ctx = {'source': 'same'}
            calls = []
            def execute(args, **kwargs):
                calls.append(args)
                if len(calls) == 2:
                    raise subprocess.CalledProcessError(1, args)
            with patch.object(check_ci, 'context', return_value=ctx):
                with self.assertRaises(subprocess.CalledProcessError):
                    check_ci.run_group('native', path, Path(d), execute=execute)
                self.assertEqual(check_ci.covered_base(path), {'tests/check_native_data.py'})
                with self.assertRaisesRegex(ValueError, 'already completed'):
                    check_ci.run_group('native', path, Path(d), execute=execute)
            with patch.object(check_ci, 'context', return_value={'source': 'edited'}):
                with self.assertRaisesRegex(ValueError, 'different source'):
                    check_ci.covered_base(path)
            result = json.loads(path.read_text())
            result['checks']['unknown'] = {'status': 'ok'}
            path.write_text(json.dumps(result))
            with patch.object(check_ci, 'context', return_value=ctx):
                with self.assertRaisesRegex(ValueError, 'invalid completed'):
                    check_ci.covered_base(path)

    def test_execution_keeps_arguments_environment_and_partial_coverage(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'results.json'
            calls = []
            def execute(args, **kwargs):
                calls.append((args, kwargs))
            with patch.object(check_ci, 'context', return_value={'source': 'same'}):
                check_ci.run_group('rv64-typed', path, Path(d), execute=execute)
                self.assertEqual(check_ci.covered_base(path), set())
            args, options = calls[0]
            self.assertIn('--typed-ir', args)
            self.assertIn(str(Path(d) / 'rv64-typed'), args)
            self.assertIn('qemu-riscv64 -L /usr/riscv64-linux-gnu', args)
            self.assertEqual(options['env']['FPR_TYPED_IR_BACKEND'], 'mixed')
            self.assertTrue(options['check'])

    def test_base_uses_registered_arguments_environment_and_lock(self):
        import check_base
        check = Check('example::mode', 'example.py', 90, args=('--mode',),
                      env=(('FPR_MODE', 'yes'),), lock='cabal')
        original_jobs = list(check_base.JOBS)
        try:
            check_base.script(check)
            name, job, options = check_base.JOBS[-1]
            with patch.object(check_base, 'run', return_value=subprocess.CompletedProcess([], 0, '')) as run:
                job(None)
            run.assert_called_once_with(['python3', 'example.py', '--mode'], timeout=90, env={'FPR_MODE': 'yes'})
            self.assertEqual(name, 'example::mode')
            self.assertEqual(options['lock'], 'cabal')
        finally:
            check_base.JOBS[:] = original_jobs

    def test_source_digest_changes_on_edits_and_untracked_sources(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'input').write_text('first')
            a = check_ci.source_digest(root)
            subprocess.run(['git', 'add', 'input'], cwd=root, check=True)
            self.assertEqual(a, check_ci.source_digest(root))
            (root / 'input').write_text('second')
            b = check_ci.source_digest(root)
            self.assertNotEqual(a, b)
            (root / 'untracked').write_text('new')
            self.assertNotEqual(b, check_ci.source_digest(root))


if __name__ == '__main__':
    unittest.main()
