#!/usr/bin/env python3
"""Stage a private standalone native/Sol SDK for installed-workflow qualification.

Contributor tool only. Does not install into Homebrew, publish a release, or
change global commands. The output must be a new directory.
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

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(prefix):
    return {str(p.relative_to(prefix)): digest(p) for p in sorted(prefix.rglob('*'))
            if p.is_file() and p.name != 'toolchain.json' and not p.is_symlink()}


def stage(binary, output):
    if output.exists():
        raise ValueError('output already exists; select a fresh prefix')
    binary = binary.resolve(strict=True)
    sdk = output / 'libexec/fprisc'
    sdk.mkdir(parents=True)
    shutil.copy2(binary, sdk / 'fpr')
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
    meta['files'] = inventory(output)
    (sdk / 'toolchain.json').write_text(json.dumps(meta, indent=2) + '\n')
    return meta


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'fpr')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        meta = stage(args.binary, args.output.absolute())
    except (ValueError, OSError, subprocess.CalledProcessError) as why:
        parser.exit(1, f'toolchain stage: {why}\n')
    print(json.dumps(dict(prefix=str(args.output.absolute()), compilerSha256=meta['compilerSha256'], files=len(meta['files']))))


if __name__ == '__main__':
    main()
