"""Preset conflicts and failure controls for the unified example runner."""
import copy
import json
import os
import runpy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from run_tangnano20k_examples import FPGA_CONFIG, fpga_image, validate_case, validate_classifier
from tangnano_artifact import sha


class ExampleGate(unittest.TestCase):
    def test_program_preflight_invalidates_old_success_before_build(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            source = out / 'source.fpr'
            source.write_text('profile base. main = print "hello".\n')
            common = [sys.executable, str(ROOT / 'tools/run_tangnano20k_examples.py'), '--out', temp]
            invalid = [
                ['--program', str(out / 'missing.fpr')],
                ['--program', str(source), '--root', str(out / 'missing')],
                ['--program', str(source), '--env', 'bad'],
                ['--program', str(source), '--env', '=empty-name'],
                ['--program', str(source), '--timeout', 'nan'],
                ['--program', str(source), '--timeout', '0'],
                ['--program', str(source), '--timeout', '-1'],
                ['--program', str(source)] + ['--arg=x'] * 257,
                ['--arg=ignored'], ['--input=ignored'], ['--root', temp],
            ]
            for options in invalid:
                (out / 'results.json').write_text('{"passed": true, "suite_complete": true}')
                result = subprocess.run(common + options, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0, options)
                report = json.loads((out / 'results.json').read_text())
                self.assertFalse(report['passed'])
                self.assertFalse(report['suite_complete'])
                self.assertEqual(report['cases'], [])
                self.assertFalse((out / 'compiler-build.log').exists())
                self.assertFalse((out / 'program-fpga.log').exists())

    def test_program_and_suite_selection_are_exclusive(self):
        result = subprocess.run([sys.executable, str(ROOT / 'tools/run_tangnano20k_examples.py'),
                                 '--program', 'any.fpr', '--cases', 'hello'],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn('not allowed with argument', result.stderr)

    def test_failed_run_invalidates_previous_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / 'results.json').write_text('{"passed": true, "suite_complete": true}')
            env = {**os.environ, 'FPR_XLEN': '64'}
            result = subprocess.run([sys.executable, str(ROOT / 'tools/run_tangnano20k_examples.py'),
                                     '--target', 'qemu', '--cases', 'hello', '--out', temp],
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((out / 'results.json').read_text())
            self.assertFalse(report['passed'])
            self.assertFalse(report['suite_complete'])
            self.assertEqual(report['cases'], [])

    def test_presets_refuse_conflicting_environment(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FPR_', 'SDRAM_'))}
        runtime = ROOT / 'machine/tangnano20k/preset.sh'
        hardware = Path(os.environ.get('SIMPLE_RISC_ROOT', ROOT.parent / 'simple-risc')) / 'boards/tangnano20k/sdram/preset.sh'
        for script, key, options in (
            (runtime, 'FPR_PRESET', {'FPR_XLEN': '64', 'FPR_CPU_MHZ': '72', 'FPR_RVC': '0'}),
            (hardware, 'SDRAM_PRESET', {'SDRAM_FREQ_MHZ': '54', 'SDRAM_CPU_FREQ_MHZ': '72',
                                      'SDRAM_RVC': '0', 'SDRAM_PHASE_DEGREES': '90',
                                      'SDRAM_CACHE_LINE_BITS': '7', 'SDRAM_RTL_FILE': '/tmp/stale.v'})):
            command = ['bash', '-c', 'set -eu; source "$1"', 'test', str(script)]
            good = subprocess.run(command, env={**env, key: 'fprisc-48'}, capture_output=True)
            self.assertEqual(good.returncode, 0, good.stderr)
            for name, value in options.items():
                bad = subprocess.run(command, env={**env, key: 'fprisc-48', name: value}, capture_output=True)
                self.assertNotEqual(bad.returncode, 0, name)
            bad = subprocess.run(command, env={**env, key: 'unknown'}, capture_output=True)
            self.assertNotEqual(bad.returncode, 0)

    def test_manifest_rejects_incomplete_mismatched_or_modified_images(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'impl/pnr').mkdir(parents=True)
            artifacts = {}
            for name in ('impl/pnr/sdram_test.fs', 'impl/pnr/sdram_test.tr'):
                (root / name).write_text(name)
                artifacts[name] = sha(root / name)
            path = root / 'build-manifest.json'
            report = dict(preset='fprisc-48', ready=True, configuration=FPGA_CONFIG, artifacts=artifacts)
            path.write_text(json.dumps(report))
            self.assertEqual(fpga_image(path)[0], root / 'impl/pnr/sdram_test.fs')
            for field, value in [('ready', False), ('preset', 'other'), ('configuration', {})]:
                path.write_text(json.dumps({**report, field: value}))
                with self.assertRaises(ValueError):
                    fpga_image(path)
            path.write_text(json.dumps(report))
            (root / 'impl/pnr/sdram_test.fs').write_text('corrupted')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                fpga_image(path)

    def test_manifest_geometry_matches_actual_simple_risc_producer(self):
        hardware = Path(os.environ.get('SIMPLE_RISC_ROOT', ROOT.parent / 'simple-risc'))
        producer = runpy.run_path(str(hardware / 'boards/tangnano20k/sdram/preset_manifest.py'))
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / 'impl/pnr').mkdir(parents=True)
            artifacts = {}
            for name in ('impl/pnr/sdram_test.fs', 'impl/pnr/sdram_test.tr'):
                (out / name).write_text(name)
                artifacts[name] = sha(out / name)
            path = out / 'build-manifest.json'
            config = producer['CONFIG']
            self.assertEqual(config, FPGA_CONFIG)
            report = dict(preset='fprisc-48', ready=True, configuration=config, artifacts=artifacts)
            path.write_text(json.dumps(report))
            self.assertEqual(fpga_image(path)[0], out / 'impl/pnr/sdram_test.fs')
            legacy = {key: value for key, value in config.items()
                      if key not in ('cache_ways', 'cache_line_bits')}
            path.write_text(json.dumps({**report, 'configuration': legacy}))
            self.assertEqual(fpga_image(path)[0], out / 'impl/pnr/sdram_test.fs')
            for bad in ({**config, 'cache_ways': 2}, {**config, 'cache_line_bits': 11},
                        {**legacy, 'cache_ways': 1}, {**legacy, 'cache_line_bits': 12},
                        {**config, 'unknown_setting': 1}):
                path.write_text(json.dumps({**report, 'configuration': bad}))
                with self.assertRaisesRegex(ValueError, 'configuration mismatch'):
                    fpga_image(path)

    def test_classifier_region_summary_and_refusals(self):
        # The real CI summary after collector retirement: one exit sample,
        # substantial reclamation and an all-run peak below the actual budget.
        valid = dict(passed=True, elapsed_us_runs=[12000000] * 10,
                     usable_heap_block_bytes=8052496,
                     heap_samples=[dict(live=1254336, peak=2532832,
                                        regions=25321, reclaimed=183472640)])
        validate_classifier(valid)
        mutations = [
            lambda r: r.update(passed=False),
            lambda r: r.update(elapsed_us_runs=[12000000] * 9),
            lambda r: r.update(heap_samples=[]),
            lambda r: r.update(usable_heap_block_bytes=0),
            lambda r: r['heap_samples'][0].update(peak=8052497),
            lambda r: r['heap_samples'][0].update(live=0, peak=0),
            lambda r: r['heap_samples'][0].update(live=2532833),
            lambda r: r['heap_samples'][0].update(regions=9),
            lambda r: r['heap_samples'][0].update(reclaimed=80524960),
            lambda r: r['heap_samples'][0].pop('regions'),
        ]
        for mutate in mutations:
            bad = copy.deepcopy(valid)
            mutate(bad)
            with self.assertRaises(ValueError):
                validate_classifier(bad)

    def test_exit_alone_and_wrong_results_do_not_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            valid = 'SimpleRisc: factorial(6)=720\nFPR EXIT 0\n'
            validate_case('hello', valid, root)
            for output in ('FPR EXIT 0\n', valid.replace('720', '721'), valid + 'FPR EXIT 0\n', valid + 'FPR EXIT 1\n'):
                with self.assertRaises(ValueError):
                    validate_case('hello', output, root)
            with self.assertRaises(ValueError):
                validate_case('wc', 'FPR EXIT 0\n', root)
            with self.assertRaises(ValueError):
                validate_case('args', 'ARGS count=5\nFPR EXIT 0\n', root)


if __name__ == '__main__':
    unittest.main()
