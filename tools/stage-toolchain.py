#!/usr/bin/env python3
"""Stage a private standalone native/Sol SDK for installed-workflow qualification.

Contributor tool only. Does not install into Homebrew, publish a release, or
change global commands. The output must be a new directory.

On macOS the stage is self-contained: every library the compiler loads from
outside /usr/lib and /System (libgit2, libarchive and what they load) is
copied into libexec/fprisc/lib with its license notices and loaded through
@rpath. The stage refuses to finish if any Mach-O file still names another
path. It also records the Cabal plan the compiler was built from, which
tools/package-toolchain.py compares with cabal.project.freeze.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess

import native_linkage

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(prefix):
    return {str(p.relative_to(prefix)): digest(p) for p in sorted(prefix.rglob('*'))
            if p.is_file() and p.name != 'toolchain.json' and not p.is_symlink()}


def cabal_plan(plan_path, binary):
    """The plan's library versions and flags, if `binary` is the plan's exe:fpr."""
    if not plan_path.is_file():
        return dict(recorded=False, reason=f'no Cabal plan at {plan_path}')
    plan = json.loads(plan_path.read_text())
    exe = next((p for p in plan['install-plan'] if p.get('component-name') == 'exe:fpr'
                and p['pkg-name'] == 'fp-risc'), None)
    built = Path(exe['bin-file']) if exe and exe.get('bin-file') else None
    if not built or not built.is_file() or digest(built) != digest(binary):
        return dict(recorded=False, reason=f'{binary} is not the exe:fpr that {plan_path} built')
    packages = {}
    for p in plan['install-plan']:
        if p['pkg-name'] != 'fp-risc' or p is exe:
            packages[p['pkg-name']] = dict(version=p['pkg-version'], flags=p.get('flags', {}))
    return dict(recorded=True, compiler=plan['compiler-id'], sha256=digest(plan_path), packages=packages)


def stage(binary, output, plan=ROOT / 'dist-newstyle/cache/plan.json'):
    if output.exists():
        raise ValueError('output already exists; select a fresh prefix')
    binary = binary.resolve(strict=True)
    sdk = output / 'libexec/fprisc'
    sdk.mkdir(parents=True)
    shutil.copy2(binary, sdk / 'fpr')
    bundled = native_linkage.bundle(sdk, sdk / 'fpr') if platform.system() == 'Darwin' else []
    shutil.copy2(ROOT / 'LICENSE', sdk / 'LICENSE')
    for folder in ('core', 'std', 'sol/lib', '.fpr', 'runtime', 'machine/posix', 'machine/unix'):
        source = ROOT / folder
        if not source.exists():
            continue
        for p in sorted(source.rglob('*')):
            if p.is_file() and (folder == '.fpr' or p.suffix in ('.fpr', '.sol', '.c', '.h', '.S')):
                dest = sdk / p.relative_to(ROOT)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, dest)
    bindir = output / 'bin'
    bindir.mkdir()
    for name in ('fpr', 'sol'):
        (bindir / name).symlink_to('../libexec/fprisc/fpr')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FPR_', 'SOL_'))}
    meta = dict(format=1, qualification='private staging, not a public release',
                version=subprocess.check_output([sdk / 'fpr', '--version'], env=env, text=True).strip(),
                sourceRevision=subprocess.check_output(['git', '-C', ROOT, 'rev-parse', 'HEAD'], text=True).strip(),
                sourceDirty=bool(subprocess.check_output(['git', '-C', ROOT, 'status', '--porcelain'])),
                compilerSha256=digest(sdk / 'fpr'), host=dict(system=platform.system(), machine=platform.machine()),
                nativeBuildDependencies=['C compiler, assembler/linker and platform SDK'],
                links={name: os.readlink(bindir / name) for name in ('fpr', 'sol')})
    if platform.system() == 'Darwin':
        load = subprocess.check_output(['vtool', '-show-build', sdk / 'fpr'], text=True)
        meta['minimumMacOS'] = re.search(r'\bminos\s+(\S+)', load)[1]
        meta['nativeLibraries'] = subprocess.check_output(['otool', '-L', sdk / 'fpr'], text=True).splitlines()[1:]
        meta['bundledLibraries'] = bundled
        found = native_linkage.problems(output, sdk / 'fpr')
        if found:
            raise ValueError('the stage loads libraries from outside the toolchain: ' + native_linkage.describe(found))
    meta['cabalPlan'] = cabal_plan(plan, binary)
    meta['files'] = inventory(output)
    (sdk / 'toolchain.json').write_text(json.dumps(meta, indent=2) + '\n')
    return meta


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'fpr')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--plan', type=Path, default=ROOT / 'dist-newstyle/cache/plan.json',
                        help='the Cabal plan that built --binary (recorded for the freeze check)')
    args = parser.parse_args()
    try:
        meta = stage(args.binary, args.output.absolute(), args.plan)
    except (ValueError, OSError, subprocess.CalledProcessError) as why:
        parser.exit(1, f'toolchain stage: {why}\n')
    print(json.dumps(dict(prefix=str(args.output.absolute()), compilerSha256=meta['compilerSha256'], files=len(meta['files']))))


if __name__ == '__main__':
    main()
