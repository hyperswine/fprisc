#!/usr/bin/env python3
"""Admit a linked builtin ELF against its selected physical target contract.

Measure load segments, including padding, address gaps and unsectioned tails,
rather than ELF file size or Core nodes. Unloaded debug tables/headers cost no
RAM; segment zero-fill counts toward RAM but not the boot image. Section
agreement and the target linker remain independent hard gates.
This is image admission, not a proof of dynamic heap/stack use or WCET.
"""
import argparse
import os
import subprocess
import tempfile
import json
from pathlib import Path
import struct


def require(condition, message):
    if not condition:
        raise ValueError(message)


def admit(image_bytes, manifest_bytes, expected_target=None):
    """Compatibility interface for proof and qualification tools that hold the exact bytes."""
    tool = Path(__file__).with_name('target-image.sol').resolve()
    with tempfile.TemporaryDirectory(prefix='fpr-image-input-') as directory:
        image = Path(directory) / 'image.elf'
        manifest = Path(directory) / 'target.json'
        image.write_bytes(image_bytes)
        manifest.write_bytes(manifest_bytes)
        argv = [os.environ.get('SOL') or 'sol', tool, '--image', image, '--manifest', manifest]
        if expected_target is not None:
            require(expected_target != '', 'manifest target differs from selected build target')
            argv.extend(['--target', expected_target])
        result = subprocess.run(argv, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or 'target image refused')
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--target", required=True, help="identity selected by the build, independently of the manifest")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--stack-entries", default="", help="optional space-separated public-symbol:byte-limit pairs, proved from linked RV64 IMC integer code")
    args = parser.parse_args()
    try:
        image_bytes, manifest_bytes = args.image.read_bytes(), args.manifest.read_bytes()
        result = admit(image_bytes, manifest_bytes, args.target)
        if args.stack_entries:
            # The optional resource check runs on the same bytes before the
            # build publishes either image or receipt. No old sidecar supplies
            # bounds. Keep the ordinary image-only receipt at schema 2.
            try:
                from .check_linked_stack import prove, parse_entries
            except ImportError:
                from check_linked_stack import prove, parse_entries
            proof = prove(image_bytes, manifest_bytes, args.target,
                          parse_entries(args.stack_entries.split()))
            result = result | {"schema": 3, "linked_stack": proof}
    except (OSError, ValueError, struct.error) as exc:
        parser.exit(1, f"target image refused: {exc}\n")
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(f"target image admitted: {result['target']}: {result['image_bytes']}/{result['image_limit_bytes']} load bytes; "
          f"{result['remaining_ram_bytes']} RAM bytes after load segments")


if __name__ == "__main__":
    main()
