#!/usr/bin/env python3
"""Collect binary compiler notices from its Cabal plan, GHC docs and source cache.

Contributor-only: does not download dependencies or run on app authors' machines.
The package inventory records the collected notices; missing notices fail closed.
Used by tools/package-toolchain.py (and by QOS's SDK packager, which ships
this compiler too).
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--plan', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    if args.output.exists():
        ap.error('output already exists')
    plan = json.loads(args.plan.read_text())
    libdir = Path(subprocess.check_output(['ghc', '--print-libdir'], text=True).strip())
    prefix = libdir.parents[2]
    ghc_version = plan['compiler-id'].removeprefix('ghc-')
    if ghc_version not in str(libdir):
        ap.error('selected GHC differs from the compiler plan')
    documents = prefix / 'share/doc'
    cache = Path(subprocess.check_output(['cabal', 'path', '--cache-home'], text=True).strip())
    output = args.output
    output.mkdir(parents=True)
    entries = {}
    packages = {(p['pkg-name'], p['pkg-version']) for p in plan['install-plan']}
    for name, version in sorted(packages):
        if name == 'fp-risc':
            continue  # its project license is already staged
        label = f'{name}-{version}'
        candidates = list(documents.glob(f'*/{label}/LICENSE*'))
        if name == 'rts':
            candidates = list(documents.glob(f'*/ghc-{ghc_version}/LICENSE*'))
        texts = []
        for candidate in candidates:
            texts.append((candidate.name, candidate.read_bytes()))
        if not texts:
            source = cache / 'packages/hackage.haskell.org' / name / version / (label + '.tar.gz')
            if source.is_file():
                with tarfile.open(source) as tar:
                    for item in tar.getmembers():
                        if item.isfile() and Path(item.name).name.upper().startswith(('LICENSE', 'COPYING')):
                            texts.append((Path(item.name).name, tar.extractfile(item).read()))
        if not texts:
            ap.error(f'no license notice for {label}; prepare the matching GHC docs/source cache')
        for index, (filename, data) in enumerate(texts):
            relative = f'{label}/{index}-{filename}'
            path = output / relative
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(data)
            entries[relative] = hashlib.sha256(data).hexdigest()
    (output / 'manifest.json').write_text(json.dumps(dict(compiler=plan['compiler-id'], notices=entries), indent=2) + '\n')
    print(f'Collected notices for {len(packages) - 1} packages in {output}')


if __name__ == '__main__':
    main()
