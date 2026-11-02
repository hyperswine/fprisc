#!/usr/bin/env python3
"""Package an already qualified manager from a clean commit; never publishes."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'build/fprmeta/fprmeta')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if subprocess.check_output(['git', '-C', ROOT, 'status', '--porcelain']):
        parser.error('commit source changes before packaging')
    reported = subprocess.check_output([args.binary, '--version'], text=True).strip()
    match = re.fullmatch(r'fprmeta (\d+\.\d+\.\d+)', reported)
    if not match:
        parser.error('build a stable manager version first')
    version = match[1]
    deps = subprocess.check_output(['/usr/bin/otool', '-L', args.binary], text=True).splitlines()[1:]
    if not all(line.strip().startswith(('/usr/lib/', '/System/')) for line in deps):
        parser.error('manager links a non-system library')
    subprocess.run(['/usr/bin/codesign', '--verify', args.binary], check=True)
    args.output.mkdir(parents=True, exist_ok=False)
    name = f'fprmeta-{version}-macos-arm64'
    prefix = args.output / name
    (prefix / 'bin').mkdir(parents=True)
    shutil.copy2(args.binary, prefix / 'bin/fprmeta')
    shutil.copy2(ROOT / 'LICENSE', prefix / 'LICENSE')
    shutil.copy2(ROOT / 'tools/fprmeta/release.pub', prefix / 'release.pub')
    archive = args.output / f'{name}.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        tar.add(prefix, arcname=name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.output / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
    manifest = dict(format=1, version=version, component='fprmeta', platform='macos-arm64',
                    sourceRevision=subprocess.check_output(['git', '-C', ROOT, 'rev-parse', 'HEAD'], text=True).strip(),
                    archive=archive.name, sha256=digest, size=archive.stat().st_size,
                    nativeLibraries=[line.strip() for line in deps], publicKey=(prefix / 'release.pub').read_text().strip())
    (args.output / 'release.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
