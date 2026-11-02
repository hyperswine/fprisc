#!/usr/bin/env python3
"""Stage a versioned source-plus-runner bundle and optionally activate it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def source_files():
    # Honor the source snapshot when building a shipped archive without Git.
    if (ROOT/'bundle-source.json').is_file():
        return json.loads((ROOT/'bundle-source.json').read_text())['files']
    output = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT)
    return sorted(set(os.fsdecode(p) for p in output.split(b'\0') if p and (ROOT/os.fsdecode(p)).is_file()))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--binary', type=Path, default=ROOT/'fpr')
    ap.add_argument('--prefix', type=Path, help='activate PREFIX/bin/sol after staging succeeds')
    ap.add_argument('--output', type=Path, help='write a host-specific tar.gz bundle')
    args = ap.parse_args()
    if not args.prefix and not args.output:
        ap.error('supply --prefix or --output (or both)')
    binary = args.binary.resolve(strict=True)
    files = source_files()
    prefix = args.prefix.absolute() if args.prefix else None
    if prefix:
        target = prefix/'bin/sol'
        versions = prefix/'libexec/sol'
        versions.mkdir(parents=True, exist_ok=True)
        target.parent.mkdir(parents=True, exist_ok=True)
        if os.path.lexists(target):
            # Never replace an unrelated executable or a link outside this installation.
            if not target.is_symlink() or target.resolve().parent.parent != versions.resolve():
                ap.error('refusing to replace unmanaged '+str(target))
        stage_parent = versions
    else:
        stage_parent = None
    with tempfile.TemporaryDirectory(prefix='.sol-stage-', dir=stage_parent) as temporary:
        bundle = Path(temporary)/"bundle"
        bundle.mkdir()
        shutil.copy2(binary, bundle/'fpr')
        (bundle/'launch-sol').symlink_to('fpr')
        source = bundle/'source'
        source.mkdir()
        for name in files:
            dest = source/name
            dest.parent.mkdir(parents=True, exist_ok=True)
            if (ROOT/name).is_symlink():
                dest.symlink_to(os.readlink(ROOT/name))
            else:
                shutil.copy2(ROOT/name, dest)
        # Identity describes the staged bytes, even if an evidence file in the
        # live checkout changes during the copy. Never hash one version then
        # ship another; a source snapshot is not a signed build attestation.
        version = subprocess.check_output([bundle/'fpr', 'sol', '--version'], text=True, timeout=30).strip()
        if version != 'Sol 0.13.0 (scripting API 1)':
            ap.error('unexpected runner version '+version)
        hashes = {name: sha(source/name) for name in files}
        binary_hash = sha(bundle/'fpr')
        identity = hashlib.sha256(json.dumps([binary_hash, hashes], sort_keys=True).encode()).hexdigest()
        bundle_id = f'sol-0.13.0-api1-{platform.system().lower()}-{platform.machine()}-{identity[:16]}'
        manifest = dict(format=1, version=version, bundle_id=bundle_id, binary_sha256=binary_hash,
                        source_sha256=hashes, host=dict(system=platform.system(), machine=platform.machine()),
                        libraries=['core', 'std', 'sol'], dependencies='See docs/2026-10-29-SOL-INSTALLATION.md')
        named = bundle.with_name(bundle_id)
        bundle.rename(named)
        bundle = named
        source = bundle/'source'
        (source/'bundle-source.json').write_text(json.dumps(dict(files=files), indent=2)+'\n')
        for name in ('core', 'std', 'sol'):
            (bundle/name).symlink_to('source/'+name, target_is_directory=True)
        (bundle/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=args.output.parent, delete=False) as stream:
                archive = Path(stream.name)
            try:
                with tarfile.open(archive, 'w:gz') as tar:
                    tar.add(bundle, arcname=bundle_id)
                os.replace(archive, args.output)
            finally:
                archive.unlink(missing_ok=True)
        if prefix:
            final = versions/bundle_id
            if final.exists():
                try:
                    intact = ((final/'manifest.json').read_bytes() == (bundle/'manifest.json').read_bytes()
                              and sha(final/'fpr') == manifest['binary_sha256']
                              and (final/'launch-sol').is_symlink() and os.readlink(final/'launch-sol') == 'fpr'
                              and all(sha(final/'source'/name) == digest for name, digest in hashes.items())
                              and all((final/name).is_symlink() and os.readlink(final/name) == 'source/'+name
                                      for name in ('core', 'std', 'sol')))
                except OSError:
                    intact = False
                if not intact:
                    ap.error('existing bundle is corrupt or has a conflicting identity: '+str(final))
            else:
                os.rename(bundle, final)
            # One atomic symlink switch. A running process keeps its version.
            with tempfile.TemporaryDirectory(prefix='.sol-activate-', dir=target.parent) as activation:
                link = Path(activation)/'sol'
                link.symlink_to(Path('../libexec/sol')/bundle_id/'launch-sol')
                os.replace(link, target)
    print(json.dumps(dict(bundle_id=bundle_id, prefix=str(prefix) if prefix else None,
                          archive=str(args.output) if args.output else None, binary_sha256=manifest['binary_sha256'])))


if __name__ == '__main__':
    main()
