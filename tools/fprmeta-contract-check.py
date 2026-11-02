#!/usr/bin/env python3
"""Focused native launcher/installer regressions. Uses disposable manager homes.

make fprmeta && python3 tools/fprmeta-contract-check.py
No production installs, network, signing credentials, or source SDK required.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('FPRMETA_TEST_BINARY', ROOT / 'build/fprmeta/fprmeta')).resolve()
FIXTURES = ROOT / 'tests/fixtures/fprmeta'


def digest(b):
    return hashlib.sha256(b).hexdigest()


class Contracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fprmeta-contract-')
        self.addCleanup(self.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'manager home'
        self.project = self.root / 'project'
        self.project.mkdir()
        self.meta = self.root / 'fprmeta'
        self.meta.symlink_to(BINARY)
        self.qmeta = self.root / 'qosmeta'
        self.qmeta.symlink_to(BINARY)
        self.env = dict(os.environ, FPRMETA_HOME=str(self.home), QOSMETA_HOME=str(self.home))
        for name in ('FPR_TOOLCHAIN', 'QOS_SDK', 'FPRMETA_TRUSTED_KEY', 'QOSMETA_TRUSTED_KEY'):
            self.env.pop(name, None)

    def cleanup(self):
        for p in self.root.rglob('*'):
            if not p.is_symlink():
                p.chmod(0o700 if p.is_dir() else 0o600)
        self.tmp.cleanup()

    def run_meta(self, *args, code=0, contains=None, qos=False):
        r = subprocess.run([self.qmeta if qos else self.meta, *map(str, args)], cwd=self.project,
                           env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, code, f'{args}: {r.stdout}{r.stderr}')
        if contains:
            self.assertIn(contains, r.stdout + r.stderr)
        return r.stdout + r.stderr

    def installed(self, *versions):
        (self.home / 'receipts').mkdir(parents=True, exist_ok=True)
        for v in versions:
            (self.home / v).mkdir(exist_ok=True)
            (self.home / 'receipts' / f'{v}.json').write_text('{}')

    def pin(self, pin, section='[toolchain] # valid comment', key='fpr'):
        name = 'qos.toml' if key == 'version' else 'fpr.toml'
        (self.project / name).write_text(f'{section}\n{key} = {json.dumps(pin)} # pin\n')

    def archive(self, version='0.12.0', *, changes=None, members=(), qos=False):
        payload = b'#!/bin/sh\nprintf "fixture\\n"\n'
        if qos:
            files = {'bin/qos': payload, 'libexec/qos-portable/qos': payload}
            meta = dict(format=1, release=version, os='darwin', architecture='aarch64', minimumMacOS='1.0')
            inv = {'qos': digest(payload)}
            files['libexec/qos-portable/files.sha256.json'] = json.dumps(inv).encode()
            meta_path = 'libexec/qos-portable/sdk.json'
        else:
            files = {'libexec/fprisc/fpr': payload}
            meta = dict(format=1, release=version, host=dict(system='Darwin', machine='arm64'),
                        minimumMacOS='1.0', files={p: digest(b) for p, b in files.items()})
            meta_path = 'libexec/fprisc/toolchain.json'
        if changes:
            meta.update(changes)
        files[meta_path] = json.dumps(meta).encode()
        if qos:
            inv['sdk.json'] = digest(files[meta_path])
            files['libexec/qos-portable/files.sha256.json'] = json.dumps(inv).encode()
        archive = self.root / f'archive-{len(list(self.root.glob("*.tar.gz")))}.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for name, b in files.items():
                info = tarfile.TarInfo('release/' + name)
                info.size, info.mode = len(b), 0o755 if name.endswith(('fpr', 'qos')) else 0o644
                tar.addfile(info, io.BytesIO(b))
            for member in members:
                tar.addfile(member, io.BytesIO(b'x') if member.isfile() else None)
        return archive

    def install(self, archive, **kwargs):
        return self.run_meta('install', '--archive', archive, '--sha256', digest(archive.read_bytes()), **kwargs)

    def index(self, archive, version='0.12.0', **entry_changes):
        entry = dict(component='fprisc', version=version, platform='macos-arm64', url=archive.as_uri(),
                     sha256=digest(archive.read_bytes()), size=archive.stat().st_size, minimumOS='1.0', requires=[])
        entry.update(entry_changes)
        path = self.root / 'index.json'
        path.write_text(json.dumps(dict(format=1, component='fprisc', entries=[entry])))
        return path

    def test_commented_sections_and_nearest_pin(self):
        self.installed('0.12.0', '0.12.2', '0.13.0')
        self.run_meta('default', '0.13.0')
        self.pin('0.12.0', '[ toolchain ] # uses this project, not the default')
        self.run_meta('which', contains='fprisc 0.12.2, chosen by')
        self.run_meta('pin', '0.12.0', contains='pinned exactly')
        self.run_meta('which', contains='fprisc 0.12.0, chosen by')
        (self.project / 'fpr.toml').write_text("[toolchain] # comment\nfpr = '0.12.0' # literal\n")
        self.run_meta('pin', '0.12.2', contains='pinned exactly')
        self.run_meta('which', contains='asks for =0.12.2')

    def test_bad_pins_never_fall_back(self):
        self.installed('0.13.0')
        self.run_meta('default', '0.13.0')
        for body in ('[toolchain]\nfpr = 123', '[toolchain]\nfpr = "0.13.0" garbage',
                     '[toolchain]\nfpr = "0.13.0"\nfpr = "0.13.0"', '[toolchain # bad',
                     '[toolchain]\n', '[toolchain]\nfpr = "not-a-version"'):
            with self.subTest(body=body):
                (self.project / 'fpr.toml').write_text(body + '\n')
                self.run_meta('which', code=2, contains='fpr.toml')

    def test_shared_version_policy(self):
        self.installed('0.12.0-rc.2', '0.12.0-rc.10', '0.12.0', '0.12.1-dev', '0.13.0', '1.2.0', '1.3.0', '2.0.0')
        for pin, wanted in [('0.12.0', '0.12.0'), ('=0.12.0-rc.2', '0.12.0-rc.2'),
                            ('0.12.0-rc.2', '0.12.1-dev'), ('1.2.0', '1.3.0')]:
            for qos in (False, True):
                self.pin(pin, '[sdk] # SDK pin' if qos else '[toolchain] # compiler pin', 'version' if qos else 'fpr')
                self.run_meta('which', qos=qos, contains=f'{wanted}, chosen by')
        self.pin('0.12.0-rc.2')
        shutil.rmtree(self.home / '0.12.0')
        shutil.rmtree(self.home / '0.12.1-dev')
        self.run_meta('which', contains='0.12.0-rc.10, chosen by')
        self.pin('0.12.0')
        self.run_meta('which', code=2, contains='not installed')

    def test_receipt_is_published_with_payload_and_repaired(self):
        self.install(self.archive())
        self.assertTrue((self.home / '0.12.0/.fprmeta-receipt.json').is_file())
        (self.home / 'receipts/0.12.0.json').unlink()
        (self.home / 'settings.toml').unlink()
        self.run_meta('list', contains='0.12.0')
        self.run_meta('repair', contains='repaired')
        self.assertTrue((self.home / 'receipts/0.12.0.json').is_file())
        self.run_meta('default', '0.12.0')
        self.run_meta('uninstall', '../project', code=2, contains='not a version')
        self.assertTrue(self.project.exists())

    def test_old_orphan_recovered_only_after_validation(self):
        self.install(self.archive())
        top = self.home / '0.12.0'
        top.chmod(0o700)
        (top / '.fprmeta-receipt.json').unlink()
        (self.home / 'receipts/0.12.0.json').unlink()
        self.run_meta('repair', contains='repaired')
        (self.home / 'receipts/0.12.0.json').unlink()
        binary = top / 'libexec/fprisc/fpr'
        binary.chmod(0o700)
        binary.write_text('corrupt')
        self.run_meta('repair', code=1, contains='inventory')
        self.assertFalse((self.home / 'receipts/0.12.0.json').exists())

    def test_payload_contracts(self):
        for changes, message in [(dict(format=2), 'format'), (dict(host=dict(system='Linux', machine='arm64')), 'platform'),
                                 (dict(minimumMacOS='99.0'), 'needs macOS'), (dict(minimumMacOS='bad'), 'minimumOS'),
                                 (dict(files={}), 'inventory')]:
            with self.subTest(changes=changes):
                self.install(self.archive(changes=changes), code=1, contains=message)
                self.assertFalse((self.home / '0.12.0').exists())
        self.install(self.archive(qos=True), qos=True)
        self.run_meta('list', qos=True, contains='0.12.0')

    def test_archive_paths_links_and_duplicates(self):
        for name, kind, target in [('../escaped', tarfile.REGTYPE, ''), ('/tmp/fprmeta-escape', tarfile.REGTYPE, ''),
                                   ('release/escape', tarfile.SYMTYPE, '../../escaped'),
                                   ('release/device', tarfile.FIFOTYPE, ''),
                                   ('release/alias', tarfile.LNKTYPE, 'release/libexec/fprisc/fpr'),
                                   ('release/libexec/fprisc/fpr', tarfile.REGTYPE, '')]:
            with self.subTest(name=name, kind=kind):
                m = tarfile.TarInfo(name)
                m.type, m.linkname, m.size = kind, target, 1 if kind == tarfile.REGTYPE else 0
                self.install(self.archive(members=[m]), code=1)
                self.assertFalse((self.root / 'escaped').exists())
                self.assertFalse((self.home / '0.12.0').exists())

    def test_lock_exclusion_and_reuse(self):
        import fcntl
        self.home.mkdir()
        archive = self.archive()
        lock = self.home / 'lock'
        with lock.open('w') as fd:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.install(archive, code=1, contains='another fprmeta')
        self.install(archive)
        self.assertTrue(lock.is_file(), 'kernel lock inode must remain stable')

    def test_index_contracts(self):
        archive = self.archive()
        for changes, message in [(dict(version='0.12.1'), 'differs from payload'), (dict(size=1), 'size'),
                                 (dict(minimumOS='2.0'), 'minimumOS differs'), (dict(size='bad'), 'size'),
                                 (dict(requires=[1]), 'strings'), (dict(requires=['unknown']), 'unsupported'),
                                 (dict(yanked='no'), 'boolean'), (dict(sha256='x'), 'SHA-256')]:
            with self.subTest(changes=changes):
                index = self.index(archive, **changes)
                self.run_meta('install', '--index', index, '--allow-unsigned-index', code=1, contains=message)
                self.assertFalse((self.home / '0.12.0').exists())
        index = self.index(archive)
        self.run_meta('install', '--index', index, code=1, contains='signature')
        self.run_meta('install', '--index', index, '--allow-unsigned-index', contains='installed fprisc 0.12.0')

    def test_index_schema_duplicates_and_stable_latest(self):
        archive = self.archive()
        index = self.index(archive)
        original = json.loads(index.read_text())
        for changes in (dict(format=2), dict(component="qos-portable"), dict(entries="bad"),
                        dict(entries=[original['entries'][0], dict(original['entries'][0], yanked=True)])):
            index.write_text(json.dumps(dict(original, **changes)))
            self.run_meta('available', '--index', index, '--allow-unsigned-index', code=1)
        pre = self.index(archive, version='0.12.0-rc.1')
        self.run_meta('install', '--index', pre, '--allow-unsigned-index', code=1, contains='no fprisc stable release')

    def test_compiler_packaged_identity(self):
        compiler = ROOT / 'fpr'
        sdk = self.root / 'compiler home'
        sdk.mkdir()
        for name in ('core', 'std', 'runtime', 'machine', 'sol'):
            (sdk / name).symlink_to(ROOT / name)
        (sdk / 'toolchain.json').write_text('{"release":"0.13.0-rc.2"}')
        env = dict(self.env, FPR_HOME=str(sdk), XDG_CACHE_HOME=str(self.root / 'cache'))
        project = self.root / 'packaged-project'
        created = subprocess.run([compiler, 'new', project], env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(created.returncode, 0, created.stderr)
        manifest = project / 'fpr.toml'
        text = manifest.read_text()
        self.assertIn('"0.13.0-rc.2"', text)
        for pin, status in [('=0.13.0-rc.2', 0), ('=0.13.0-rc.1', 2), ('0.13.0', 2)]:
            manifest.write_text(text.replace('"0.13.0-rc.2"', json.dumps(pin)))
            check = subprocess.run([compiler, 'check'], env=env, cwd=project, capture_output=True, text=True, timeout=30)
            self.assertEqual(check.returncode, status, check.stdout + check.stderr)

    def test_signed_index(self):
        index = self.root / 'signed.json'
        sig = Path(str(index) + '.sig')
        shutil.copyfile(FIXTURES / 'index.json', index)
        shutil.copyfile(FIXTURES / 'index.json.sig', sig)
        key = FIXTURES / 'release.pub'
        self.run_meta('available', '--index', index, '--trusted-key', key, contains='offers no')
        index.write_text(index.read_text() + ' ')
        self.run_meta('available', '--index', index, '--trusted-key', key, code=1, contains='verification failed')
        sig.unlink()
        self.run_meta('available', '--index', index, '--trusted-key', key, code=1, contains='signature')
        # Supplying a trust key always verifies, even if unsigned mode is also named.
        self.run_meta('available', '--index', index, '--trusted-key', key, '--allow-unsigned-index', code=1)


if __name__ == '__main__':
    unittest.main()
