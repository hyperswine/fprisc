#!/usr/bin/env python3
"""Acceptance for fprmeta/qosmeta and the launchers, with source checkouts denied.

Takes two FP-RISC release archives of the same series, OLD and NEW (each with
its SHA256SUMS beside it), and optionally a QOS SDK archive. Everything runs
under sandbox-exec in a fresh --output directory outside the workspace:
installing from an archive and from a version list, refusals (checksum,
inventory, duplicate, lock), choosing a version (default, +VERSION, the
environment, compatible and exact project pins), Sol through the launcher
(both shebang forms), byte-identical builds for an exactly pinned project
across an upgrade, uninstalling without touching projects or caches, and the
launcher's start-up cost. docs/2026-11-01-TOOLCHAIN-MANAGER.md.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tarfile
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tree(root, skip=()):
    return {str(p.relative_to(root)): sha(p) for p in sorted(Path(root).rglob('*'))
            if p.is_file() and not any(part in skip for part in p.relative_to(root).parts)}


def release_of(archive):
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            if member.name.endswith('libexec/fprisc/toolchain.json'):
                return json.load(tar.extractfile(member))['release']
    raise SystemExit(f'{archive}: not an FP-RISC release archive')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--fprmeta', type=Path, default=ROOT / 'build/fprmeta/fprmeta')
    ap.add_argument('--old', type=Path, required=True, help='the older FP-RISC release archive')
    ap.add_argument('--new', type=Path, required=True, help='the newer one, same series')
    ap.add_argument('--qos', type=Path, help='optional QOS SDK release archive for qosmeta')
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    if sys.platform != 'darwin':
        ap.error('this check uses macOS sandbox-exec')
    out = args.output.resolve()
    if out.is_relative_to(ROOT.parent):
        ap.error('output must be outside the workspace that this check denies')
    out.mkdir(parents=True, exist_ok=False)
    old_v, new_v = release_of(args.old), release_of(args.new)

    # inputs copied out of the denied workspace
    tools = out / 'path'
    tools.mkdir()
    binary = out / 'fprmeta-binary'
    shutil.copy2(args.fprmeta, binary)
    for name in ('fprmeta', 'qosmeta', 'fpr', 'sol', 'qos'):
        (tools / name).symlink_to(binary)
    archives = out / 'archives'
    archives.mkdir()
    for a in (args.old, args.new):
        shutil.copy2(a, archives / a.name)
    (archives / 'SHA256SUMS').write_text(''.join(f'{sha(archives / a.name)}  {a.name}\n' for a in (args.old, args.new)))
    home = out / 'fpr home'
    project = out / 'external project'
    cache = out / 'cache'
    for d in (project, cache, out / 'tmp', out / 'user'):
        d.mkdir()

    policy = out / 'check.sb'
    blocked = [ROOT.parent, Path.home() / '.ghcup', Path.home() / '.cabal', Path.home() / '.fpr', Path.home() / '.qos']
    policy.write_text('(version 1)\n(allow default)\n' + ''.join(
        f'(deny file-read* file-write* (subpath {json.dumps(str(p))}))\n' for p in blocked)
        + '(deny process-exec (literal "/usr/bin/make") (literal "/usr/bin/git"))\n')
    env = dict(PATH=f'{tools}:/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(out / 'user'), FPRMETA_HOME=str(home),
               QOSMETA_HOME=str(out / 'qos home'), XDG_CACHE_HOME=str(cache), TMPDIR=str(out / 'tmp'),
               LANG='en_US.UTF-8', SOL_GPU='0', FPR_HARTS='2')
    report = dict(old=old_v, new=new_v, sourceAccess='denied', steps=[], status='running')

    def save():
        (out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')

    def run(name, argv, code=0, cwd=project, expect=None, extra=None, input=None):
        start = time.monotonic()
        e = dict(env, **(extra or {}))
        r = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(policy), *map(str, argv)], cwd=cwd, env=e,
                           capture_output=True, text=True, input=input, timeout=600)
        (out / f'{name}.log').write_text(r.stdout + r.stderr)
        report['steps'].append(dict(name=name, argv=list(map(str, argv)), exit=r.returncode,
                                    seconds=round(time.monotonic() - start, 3)))
        save()
        assert r.returncode == code, f'{name}: exit {r.returncode}, wanted {code}\n{r.stdout[-1500:]}{r.stderr[-1500:]}'
        if expect is not None:
            assert expect in r.stdout + r.stderr, f'{name}: missing {expect!r} in\n{r.stdout}{r.stderr}'
        return r

    def which(name='fpr', cwd=project, extra=None):
        return run(f'which-{len(report["steps"])}', ['fprmeta', 'which', name], cwd=cwd, extra=extra).stdout.splitlines()[1]

    try:
        run('source-denied', ['/bin/cat', ROOT / 'core/prelude.fpr'], code=1)
        run('nothing-chosen', ['fpr', '--version'], code=2, expect='fprmeta install VERSION')
        # install OLD from its archive; the first install becomes the default
        run('install-archive', ['fprmeta', 'install', '--archive', archives / args.old.name], expect='(now the default)')
        assert (home / old_v / 'bin/fpr').is_symlink() and not os.access(home / old_v, os.W_OK)
        run('default-launch', ['fpr', '--version'], expect='fpr ')
        # refusals
        run('wrong-sha', ['fprmeta', 'install', '--archive', archives / args.new.name, '--sha256', '0' * 64], code=1, expect='expected 000')
        tampered = out / 'tampered'
        tampered.mkdir()
        with tarfile.open(args.new) as tar:
            tar.extractall(tampered, filter='data')
        (top,) = tampered.iterdir()
        meta = top / 'libexec/fprisc/toolchain.json'
        data = json.loads(meta.read_text())
        data['release'] = '0.0.1'
        meta.write_text(json.dumps(data))
        (top / 'libexec/fprisc/std/list.fpr').write_text('# changed\n')
        bad = archives / 'fprisc-0.0.1-tampered.tar.gz'
        with tarfile.open(bad, 'w:gz') as tar:
            tar.add(top, arcname=top.name)
        run('tampered-refused', ['fprmeta', 'install', '--archive', bad, '--sha256', sha(bad)], code=1, expect='inventory')
        assert not (home / '0.0.1').exists()
        run('duplicate-refused', ['fprmeta', 'install', '--archive', archives / args.old.name], code=1, expect='already installed')
        (home / 'lock').mkdir()
        run('lock-refused', ['fprmeta', 'install', '--archive', archives / args.new.name], code=1, expect='another fprmeta is installing')
        assert (home / 'lock').is_dir(), 'a refused install removed the lock it did not take'
        (home / 'lock').rmdir()

        # a project with a compatible pin on OLD, built and fingerprinted
        (project / 'src/deep').mkdir(parents=True)
        (project / 'src/main.fpr').write_text('profile base.\nL = use "std/list".\nmain = print "pinned: {L.length [1,2,3]}".\n')
        manifest = project / 'fpr.toml'
        manifest.write_text('manifest = 1\n\n[project]\nname = "pinned"\nversion = "0.1.0"\nkind = "cli"\n'
                            f'entry = "src/main.fpr"\n\n[toolchain]\nfpr = "{old_v}"          # this fpr or a later compatible one\n')
        assert which(cwd=project / 'src/deep').startswith(f'fprisc {old_v}, chosen by {manifest}:')
        run('pin-exact', ['fprmeta', 'pin'], expect=f'pinned exactly to {old_v}')
        assert f'fpr = "={old_v}"' in manifest.read_text() and 'exactly this fpr' in manifest.read_text()
        run('build-old', ['fpr', 'build', 'src/main.fpr', '-o', 'hello-old'])
        run('run-old', [project / 'hello-old'], expect='pinned: 3')
        before = sha(project / 'hello-old')

        # NEW from a version list: a withdrawn entry and another platform are skipped
        index = out / 'index.json'
        def entry(v, archive, **more):
            return dict(component='fprisc', version=v, platform='macos-arm64', url=f'file://{archive}', sha256=sha(archive), **more)
        index.write_text(json.dumps(dict(format=1, entries=[
            entry(old_v, archives / args.old.name), entry(new_v, archives / args.new.name),
            entry('0.0.1', bad, yanked=True), dict(entry('9.9.9', bad), platform='linux-arm64')])))
        run('index-withdrawn', ['fprmeta', 'install', '0.0.1', '--index', index], code=1, expect='has no fprisc 0.0.1')
        run('install-index', ['fprmeta', 'install', '--index', f'file://{index}'], expect=f'installed fprisc {new_v}')
        run('list', ['fprmeta', 'list'], expect=f'{old_v}  (default)')

        # choosing: the exact pin stays, +VERSION and the environment override
        assert which().startswith(f'fprisc {old_v}, chosen by {manifest}')
        run('plus-override', ['fprmeta', 'which', 'fpr'], extra=dict(FPR_TOOLCHAIN=new_v), expect=f'fprisc {new_v}, chosen by FPR_TOOLCHAIN')
        run('plus-arg', ['fpr', f'+{new_v}', '--version'], expect='fpr ')
        # the output name is part of the ad hoc signature, so rebuild under the same name
        shutil.move(project / 'hello-old', out / 'hello-old-first')
        run('rebuild-old', ['fpr', 'build', 'src/main.fpr', '-o', 'hello-old'])
        assert sha(project / 'hello-old') == before, 'the exactly pinned build changed after an upgrade'
        report['pinnedBuildSha256'] = before
        # a compatible pin moves to the newest installed release of its series
        manifest.write_text(manifest.read_text().replace(f'"={old_v}"', f'"{old_v}"'))
        assert which().startswith(f'fprisc {new_v}, chosen by {manifest}')
        run('build-new', ['fpr', 'build', 'src/main.fpr', '-o', 'hello-new'])
        run('run-new', [project / 'hello-new'], expect='pinned: 3')
        manifest.write_text(manifest.read_text().replace(f'"{old_v}"', f'"={old_v}"'))

        # Sol through the launcher, both shebang forms, arguments intact
        script = project / 'args.sol'
        script.write_text('#!/usr/bin/env sol\n> print (args Unit).\n')
        script.chmod(0o755)
        run('sol-env-shebang', [script, 'a b', '', '--x'], expect='[a b, , --x]')
        absolute = project / 'abs.sol'
        absolute.write_text(f'#!{tools}/sol\n> print (args Unit).\n')
        absolute.chmod(0o755)
        run('sol-absolute-shebang', [absolute, 'one', 'two'], expect='[one, two]')

        # uninstalling OLD leaves projects and caches alone; the exact pin then stops with the hint
        kept = tree(project)
        kept_cache = tree(cache)
        run('uninstall-old', ['fprmeta', 'uninstall', old_v], expect='it was the default')
        assert not (home / old_v).exists() and tree(project) == kept and tree(cache) == kept_cache
        run('pinned-missing', ['fpr', 'build', 'src/main.fpr', '-o', 'x'], code=2, expect=f'fprmeta install {old_v}')
        run('old-binary-still-runs', [project / 'hello-old'], expect='pinned: 3')

        # launcher start-up cost: median of 25 runs, launcher against the real binary
        real = home / new_v / 'bin/fpr'
        def median(argv, extra):
            times = []
            for _ in range(25):
                s = time.perf_counter()
                subprocess.run(argv, env=dict(env, **extra), cwd=out, capture_output=True)
                times.append(time.perf_counter() - s)
            return statistics.median(times) * 1000
        direct = median([real, '--version'], {})
        launched = median([tools / 'fpr', '--version'], dict(FPR_TOOLCHAIN=new_v))
        report['launcherMs'] = dict(direct=round(direct, 1), launched=round(launched, 1), overhead=round(launched - direct, 1))

        if args.qos:
            # QOS 0.2.0's own bin/qos still needs Python 3.11+ and Homebrew llvm/lld
            # (docs/2026-11-01-SDK-PROCESS-APPS.md removes both)
            qenv = dict(PATH=f'{tools}:/opt/homebrew/bin:/usr/bin:/bin')
            run('qos-install', ['qosmeta', 'install', '--archive', args.qos, '--sha256', sha(args.qos)], expect='(now the default)')
            run('qos-version', ['qos', '--version'], expect='QOS Portable', extra=qenv)
            run('qos-new', ['qos', 'new', project / 'qos-app'], extra=qenv)
            run('qos-build', ['qos', 'build'], cwd=project / 'qos-app', expect='Built', extra=qenv)
            report['qos'] = 'installed, chosen by default, built a desktop app through the launcher'
        report.update(status='passed', output=str(out))
    except BaseException as why:
        report.update(status='failed', error=str(why))
        raise
    finally:
        save()
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
