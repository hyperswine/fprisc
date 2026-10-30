#!/usr/bin/env python3
"""Qualify private macOS native/Sol SDK staging with contributor access denied.

Keeps logs and metadata in a fresh --output directory outside the workspace.
No Homebrew installation, global command, or QOS SDK is changed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tarfile
import time

ROOT = Path(__file__).resolve().parents[1]


def hashes(root):
    return {str(p.relative_to(root)): ('link:' + os.readlink(p) if p.is_symlink()
            else hashlib.sha256(p.read_bytes()).hexdigest())
            for p in sorted(root.rglob('*')) if p.is_symlink() or p.is_file()}


def unpack_release(archive, prefix, work):
    """The packaged tarball, checksum-verified, laid out as the formula installs it:
    libexec/fprisc plus bin/fpr and bin/sol links to its real compiler."""
    sums = (archive.parent / 'SHA256SUMS').read_text().split()
    if sums[1:2] != [archive.name] or sums[0] != hashlib.sha256(archive.read_bytes()).hexdigest():
        raise SystemExit('release archive does not match its SHA256SUMS')
    unpacked = work / 'unpacked'
    with tarfile.open(archive) as tar:
        tar.extractall(unpacked, filter='data')
    (top,) = unpacked.iterdir()
    meta = json.loads((top / 'libexec/fprisc/toolchain.json').read_text())
    files = {str(p.relative_to(top)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(top.rglob('*'))
             if p.is_file() and p.name != 'toolchain.json' and not p.is_symlink()}
    if files != meta['files'] or not meta.get('release'):
        raise SystemExit('release archive inventory mismatch')
    (prefix / 'libexec').mkdir(parents=True)
    (top / 'libexec/fprisc').rename(prefix / 'libexec/fprisc')
    (prefix / 'bin').mkdir()
    for name in ('fpr', 'sol'):
        (prefix / 'bin' / name).symlink_to('../libexec/fprisc/fpr')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'fpr')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--release', type=Path, metavar='ARCHIVE',
                        help='qualify a packaged release tarball (tools/package-toolchain.py; its SHA256SUMS beside it) '
                             'instead of staging --binary')
    parser.add_argument('--qos', type=Path, help='also prove an installed QOS CLI keeps using its private compiler')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('this source-denial probe currently requires macOS sandbox-exec')
    work = args.output.resolve()
    if work.is_relative_to(ROOT.parent):
        parser.error('output must be outside the workspace that this probe denies')
    work.mkdir(parents=True, exist_ok=False)
    prefix = work / 'SDK with spaces'
    if args.release:
        unpack_release(args.release.resolve(), prefix, work)
    else:
        subprocess.run([sys.executable, ROOT / 'tools/stage-toolchain.py', '--binary', args.binary,
                        '--output', prefix], check=True, capture_output=True, text=True)
    before = hashes(prefix)
    for p in sorted(prefix.rglob('*'), reverse=True):
        if not p.is_symlink():
            p.chmod(p.stat().st_mode & ~0o222)
    prefix.chmod(0o555)
    restricted = work / 'path'
    restricted.mkdir()
    for name in ('cc', 'clang', 'as', 'ld', 'getconf', 'xcrun', 'xcode-select', 'arch'):
        p = Path('/usr/bin') / name
        if p.exists():
            (restricted / name).symlink_to(p)
    for name in ('home', 'cache with spaces', 'state', 'tmp', 'external project'):
        (work / name).mkdir()
    project = work / 'external project'
    env = dict(PATH=str(prefix / 'bin') + ':' + str(restricted), HOME=str(work / 'home'),
               XDG_CACHE_HOME=str(work / 'cache with spaces'), XDG_STATE_HOME=str(work / 'state'),
               TMPDIR=str(work / 'tmp'), LANG='en_US.UTF-8', SOL_GPU='0', FPR_HARTS='2')
    blocked = [ROOT.parent, Path.home() / '.ghcup', Path.home() / '.cabal']
    policy = work / 'installed.sb'
    policy.write_text('(version 1)\n(allow default)\n' + ''.join(
        f'(deny file-read* file-write* (subpath {json.dumps(str(p))}))\n' for p in blocked)
        + f'(deny file-write* (subpath {json.dumps(str(prefix))}))\n'
        + '(deny process-exec (literal "/usr/bin/make") (literal "/usr/bin/git"))\n')
    guard = ['/usr/bin/sandbox-exec', '-f', str(policy)]
    report = dict(host=dict(system=platform.system(), machine=platform.machine()),
                  sourceAccess='denied', sdkReadOnly=True, absentTools=['ghc', 'cabal', 'make', 'git'],
                  steps=[], status='running')

    def save():
        (work / 'result.json').write_text(json.dumps(report, indent=2) + '\n')

    def run(name, command, expected=None, failure=False, input=None, extra_guard=None):
        start = time.monotonic()
        result = subprocess.run((extra_guard or guard) + list(map(str, command)), cwd=project,
                                env=env, capture_output=True, text=True, input=input, timeout=180)
        (work / (name + '.log')).write_text(result.stdout + result.stderr)
        report['steps'].append(dict(name=name, command=list(map(str, command)),
                                    seconds=time.monotonic() - start, exit=result.returncode))
        save()
        if failure:
            assert result.returncode != 0, name
        else:
            assert result.returncode == 0, f'{name}: {result.stdout[-1500:]}{result.stderr[-2500:]}'
        if expected is not None:
            assert result.stdout == expected, (name, result.stdout)
        return result

    try:
        run('source-denied', ['/bin/cat', ROOT / 'core/prelude.fpr'], failure=True)
        run('make-denied', ['/usr/bin/make', '--version'], failure=True)
        run('tools-absent', ['/bin/sh', '-c', 'for t in ghc cabal make git; do command -v "$t" && exit 1; done; exit 0'])
        fpr, sol = prefix / 'bin/fpr', prefix / 'bin/sol'
        metadata = json.loads((prefix / 'libexec/fprisc/toolchain.json').read_text())
        run('version', [fpr, '--version'], metadata['version'] + '\n')
        (project / 'main.fpr').write_text('profile base.\nL = use "std/list".\nmain = print "installed native: {L.length [1,2,3]}".\n')
        run('native-build', [fpr, 'build', 'main.fpr', '-o', 'hello'])
        run('native-execute', [project / 'hello'], 'installed native: 3\n')
        run('native-run', [fpr, 'run', 'main.fpr'], 'installed native: 3\n')
        (project / 'library.fpr').write_text('mathOp v = v * 2.\n')
        run('module-check', [fpr, 'compile', '--system=posix', '--check-only', 'library.fpr', 'unused.s'])
        assert not (project / 'unused.s').exists()
        run('module-build', [fpr, 'build', 'library.fpr', '--module', '-o', 'library.dylib'])
        assert (project / 'library.dylib').is_file()
        (project / 'bad.fpr').write_text('main = 1 + "bad".\n')
        result = run('diagnostics', [fpr, 'build', 'bad.fpr', '-o', 'bad'], failure=True)
        assert result.stderr.strip() and not (project / 'bad').exists()
        (project / 'daily.sol').write_text('#!/usr/bin/env sol\nJ = use "sol/lib/json".\n> print (J.render (J.strs ["installed", "sol"])).\n')
        (project / 'daily.sol').chmod(0o755)
        run('sol-library', [sol, 'daily.sol'], '["installed","sol"]\n')
        run('sol-shebang', [project / 'daily.sol'], '["installed","sol"]\n')
        result = run('sol-repl', [sol, '--repl'], input='> print "installed repl".\n')
        assert 'installed repl' in result.stdout and not result.stderr.strip()
        if platform.machine() == 'arm64':
            run('x64-build', [fpr, 'build', 'main.fpr', '--target=macos-x86_64', '-o', 'hello-x64'])
            result = run('x64-identity', ['/usr/bin/file', project / 'hello-x64'])
            assert 'x86_64' in result.stdout
            run('x64-rosetta', ['/usr/bin/arch', '-x86_64', project / 'hello-x64'], 'installed native: 3\n')
        # A standalone install never searches for a QOS SDK; it points at `qos build`.
        result = run('qos-target-refused', [fpr, 'build', '--target=qos-portable'], failure=True)
        assert result.returncode == 2 and 'qos build' in result.stderr, result.stderr
        independent = work / 'no-sdk.sb'
        independent.write_text(policy.read_text() + f'(deny file-read* (subpath {json.dumps(str(prefix))}))\n')
        run('standalone-app', [project / 'hello'], 'installed native: 3\n',
            extra_guard=['/usr/bin/sandbox-exec', '-f', str(independent)])
        assert hashes(prefix) == before, 'installed bytes changed'
        relocated = prefix.with_name('relocated SDK')
        prefix.rename(relocated)
        env['PATH'] = str(relocated / 'bin') + ':' + str(restricted)
        policy.write_text(policy.read_text().replace(str(prefix), str(relocated)))
        run('relocated-sol', [relocated / 'bin/sol', 'daily.sol'], '["installed","sol"]\n')
        env['XDG_CACHE_HOME'] = str(work / 'fresh relocated cache')
        run('relocated-native', [relocated / 'bin/fpr', 'build', 'main.fpr', '-o', 'relocated-hello'])
        run('relocated-execute', [project / 'relocated-hello'], 'installed native: 3\n')
        assert hashes(relocated) == before, 'relocated installed bytes changed'
        if args.qos:
            run('qos-scaffold', [args.qos, 'new', project / 'qos-counter'])
            run('qos-private-build', [args.qos, 'build', project / 'qos-counter'])
            assert (project / 'qos-counter/build/qos-counter.qa').is_file()
            log = (project / 'qos-counter/build/qos-build.log').read_text()
            commands = [shlex.split(line[2:]) for line in log.splitlines() if line.startswith('+ ')]
            compiler = Path(next(command[0] for command in commands if 'compile' in command)).resolve()
            assert compiler != (relocated / 'bin/fpr').resolve()
            meta = json.loads((compiler.parent.parent / 'sdk.json').read_text())
            assert hashlib.sha256(compiler.read_bytes()).hexdigest() == meta['compilerSha256']
            report['qosCoexistence'] = dict(privateCompiler=str(compiler), compilerSha256=meta['compilerSha256'],
                                          scope='external build with standalone fpr on PATH; no Brew co-installation')
            assert hashes(relocated) == before, 'QOS altered standalone SDK'
        if args.release:
            report.update(release=json.loads((relocated / 'libexec/fprisc/toolchain.json').read_text())['release'],
                          archive=args.release.name,
                          archiveSha256=hashlib.sha256(args.release.read_bytes()).hexdigest())
        report.update(status='passed', compilerSha256=hashlib.sha256((relocated / 'bin/fpr').read_bytes()).hexdigest(),
                      installedFilesUnchanged=True, relocation=True, output=str(work))
    except BaseException as why:
        report.update(status='failed', error=str(why))
        raise
    finally:
        save()
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
