#!/usr/bin/env python3
"""Package a clean, staged macOS ARM64 FP-RISC toolchain and generate its formula.

Contributor tool. It never publishes, never installs into Homebrew and never
rebuilds. Input is a prefix made by tools/stage-toolchain.py from a clean
commit, plus compiler notices from tools/compiler-licenses.py. Output is a
fresh directory holding the release tarball, SHA256SUMS, release.json and
fprisc.rb with that exact artifact hash. Qualify the result with
tools/toolchain-install-check.py --release before publishing it.

It refuses:
- a Mach-O file that loads a library from outside /usr/lib, /System and the
  archive itself (naming the binary and the path);
- a bundled C library without its license notices;
- a compiler whose Cabal plan differs from the committed cabal.project.freeze.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

import native_linkage

ROOT = Path(__file__).resolve().parents[1]
LOCAL_PACKAGE = 'fp-risc'
QUALIFIED_MACOS_MAJOR = '27'  # the formula's `depends_on macos: :golden_gate`


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(prefix):
    # The same rule as tools/stage-toolchain.py: files, not links, not the metadata.
    return {str(p.relative_to(prefix)): digest(p) for p in sorted(prefix.rglob('*'))
            if p.is_file() and p.name != 'toolchain.json' and not p.is_symlink()}


def frozen_plan(path):
    """`any.NAME ==VERSION` constraints and `NAME +flag -flag` lines of a
    cabal.project.freeze, as {name: {version, flags}}."""
    if not path.is_file():
        raise ValueError(f'{path.name} is missing; generate it with `cabal freeze` (docs/2026-11-01-SELF-CONTAINED-TOOLCHAIN.md)')
    lines = [line for line in path.read_text().splitlines()
             if not line.startswith(('active-repositories:', 'index-state:'))]
    text = '\n'.join(lines).replace('constraints:', ' ')
    frozen = {}
    for item in (part.strip() for part in text.split(',')):
        if not item:
            continue
        words = item.split()
        if words[0].startswith('any.') and len(words) == 2 and words[1].startswith('=='):
            frozen.setdefault(words[0][4:], {})['version'] = words[1][2:]
        elif all(w[:1] in '+-' for w in words[1:]) and len(words) > 1:
            flags = frozen.setdefault(words[0], {}).setdefault('flags', {})
            flags.update({w[1:]: w[0] == '+' for w in words[1:]})
        else:
            raise ValueError(f'{path.name}: unexpected constraint {item!r}; regenerate it with `cabal freeze`')
    return frozen


def plan_drift(recorded, frozen):
    """Differences between a stage's recorded Cabal plan and the freeze file."""
    drift = []
    for name in sorted(set(recorded) | set(frozen)):
        have, want = recorded.get(name), frozen.get(name)
        if name == LOCAL_PACKAGE:  # built from this commit; only its flags are frozen
            want = dict(want or {}, version=have['version']) if have else want
        if have is None:
            drift.append(f'{name} is frozen at {want.get("version")} but not in the plan')
        elif want is None or 'version' not in want:
            drift.append(f'{name}-{have["version"]} is in the plan but not frozen')
        elif have['version'] != want['version']:
            drift.append(f'{name}: plan {have["version"]}, freeze {want["version"]}')
        else:
            for flag, value in want.get('flags', {}).items():
                if have['flags'].get(flag, value) != value:
                    drift.append(f'{name}: flag {flag} is {have["flags"].get(flag)} in the plan, {value} in the freeze')
    return drift


def package(prefix, version, notices, output):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-rc\d+)?', version):
        raise ValueError('version must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-rcN')
    sdk = prefix / 'libexec/fprisc'
    meta = json.loads((sdk / 'toolchain.json').read_text())
    # The release names exactly the committed source the binary was built from.
    revision = subprocess.check_output(['git', '-C', ROOT, 'rev-parse', 'HEAD'], text=True).strip()
    if subprocess.check_output(['git', '-C', ROOT, 'status', '--porcelain'], text=True):
        raise ValueError('commit FP-RISC changes before packaging a release')
    if meta['sourceDirty'] or meta['sourceRevision'] != revision:
        raise ValueError('stage the toolchain from this clean commit before packaging it')
    if meta['version'] != f'fpr {version.split("-")[0]}':
        raise ValueError(f'the staged compiler reports {meta["version"]!r}, not fpr {version}')
    if (meta['host']['system'], meta['host']['machine']) != ('Darwin', 'arm64'):
        raise ValueError('release packaging is currently qualified only for macOS ARM64')
    if inventory(prefix) != meta['files'] or digest(sdk / 'fpr') != meta['compilerSha256']:
        raise ValueError('staged toolchain inventory mismatch')
    if meta.get('minimumMacOS', '').split('.')[0] != QUALIFIED_MACOS_MAJOR:
        raise ValueError(f'the compiler targets macOS {meta.get("minimumMacOS")}; review the formula\'s '
                         'macOS requirement before packaging it')
    for path in sdk.rglob('*'):
        if path.suffix in ('.hs', '.o', '.hi') or path.name in ('.git', 'dist-newstyle'):
            raise ValueError(f'unexpected release file: {path}')
    if not (sdk / 'LICENSE').is_file():
        raise ValueError('the stage must include the FP-RISC license')
    for library in meta.get('bundledLibraries', []):
        if not library['notices'] or not all((sdk / n).is_file() for n in library['notices']):
            raise ValueError(f'bundled {library["file"]} ({library["package"]}) has no license notice in the stage')
    plan = meta.get('cabalPlan', {})
    if not plan.get('recorded'):
        raise ValueError(f'the stage has no Cabal plan for its compiler: {plan.get("reason", "stage it again")}')
    drift = plan_drift(plan['packages'], frozen_plan(ROOT / 'cabal.project.freeze'))
    if drift:
        raise ValueError('the compiler was not built from cabal.project.freeze: ' + '; '.join(drift))
    manifest = json.loads((notices / 'manifest.json').read_text())
    for relative, sha in manifest['notices'].items():
        notice = (notices / relative).resolve()
        if not notice.is_relative_to(notices) or digest(notice) != sha:
            raise ValueError('compiler notice inventory mismatch')
    if output.exists():
        raise ValueError('output must be a fresh directory')
    output.mkdir(parents=True)
    name = f'fprisc-{version}-macos-arm64'
    with tempfile.TemporaryDirectory(prefix='fprisc-release-') as temporary:
        bundle = Path(temporary) / name
        shutil.copytree(prefix, bundle, symlinks=True)
        # Qualification may have made the stage read-only; only this copy is writable.
        for p in bundle.rglob('*'):
            if not p.is_symlink():
                p.chmod(p.stat().st_mode | 0o200)
        copied = bundle / 'libexec/fprisc'
        if manifest['compiler'] != plan['compiler']:
            raise ValueError(f'compiler notices are for {manifest["compiler"]}, the plan for {plan["compiler"]}')
        found = native_linkage.problems(bundle, copied / 'fpr')
        if found:
            raise ValueError('the release loads libraries from outside the archive: ' + native_linkage.describe(found))
        shutil.copytree(notices, copied / 'licenses')
        meta.update(release=version, compilerNotices=manifest['compiler'],
                    qualification='release candidate: qualify with toolchain-install-check.py --release')
        meta['files'] = inventory(bundle)
        (copied / 'toolchain.json').write_text(json.dumps(meta, indent=2) + '\n')
        archive = output / (name + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(bundle, arcname=name)
    sha = digest(archive)
    (output / 'SHA256SUMS').write_text(f'{sha}  {archive.name}\n')
    (output / 'release.json').write_text(json.dumps(dict(meta, archive=archive.name, sha256=sha), indent=2) + '\n')
    formula = (ROOT / 'packaging/homebrew/fprisc.rb.in').read_text()
    formula = formula.replace('__COMPILER_VERSION__', version.split('-')[0]).replace('__VERSION__', version).replace('__ARCHIVE__', archive.name).replace('__SHA256__', sha)
    (output / 'fprisc.rb').write_text(formula)
    print(archive)
    print(f'SHA256 {sha}')
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True, help='prefix made by tools/stage-toolchain.py')
    parser.add_argument('--version', required=True)
    parser.add_argument('--notices', type=Path, required=True, help='output of tools/compiler-licenses.py')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        package(args.sdk.resolve(), args.version, args.notices.resolve(), args.output.resolve())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as why:
        parser.exit(1, f'fprisc release: {why}\n')


if __name__ == '__main__':
    main()
