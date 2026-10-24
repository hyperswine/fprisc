#!/usr/bin/env python3
"""Build identity for the Tang Nano Base image, including local source edits."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def repository(root):
    """The checkout's revision and the SHA-256 of its diff. A checkout git cannot
    read (a container owned by another user, no .git) is reported as such, never
    raised: a runner must invalidate its report before any identity lookup."""
    try:
        return {'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True, stderr=subprocess.STDOUT).strip(),
                'diff_sha256': hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD'], cwd=root, stderr=subprocess.STDOUT)).hexdigest()}
    except (subprocess.CalledProcessError, OSError) as e:
        detail = e.output.decode(errors='replace').strip() if isinstance(getattr(e, 'output', None), bytes) else str(getattr(e, 'output', None) or e)
        return {'revision': None, 'diff_sha256': None, 'error': detail[-400:]}


def main():
    source, directory, xlen, rvc, frequency = sys.argv[1:]
    out = Path(directory).resolve()
    units = [Path(p) for p in (out / 'base.s.units').read_text().splitlines() if p]
    report = dict(preset=os.environ.get('FPR_PRESET'), repository=repository(ROOT),
                  program={'path': str(Path(source).resolve()), 'sha256': sha(source)},
                  compiler_sha256=sha(ROOT / 'fpr'),
                  gcc=subprocess.check_output(['riscv64-unknown-elf-gcc', '--version'], text=True).splitlines()[0],
                  configuration=dict(xlen=int(xlen), compressed=rvc == '1', cpu_mhz=int(frequency),
                                     reclamation='regions',
                                     qemu=os.environ.get('FPR_QEMU', '0') == '1'),
                  artifacts={name: sha(out / name) for name in ('base.s', 'base.elf', 'base.bin')},
                  units={str(p.resolve()): sha(p) for p in units})
    softfloat = Path(os.environ.get('FPR_SOFTFLOAT_ROOT', ROOT / 'build/tangnano20k-softfloat'))
    report['softfloat_sha256'] = sha(softfloat / f'build/Linux-RISCV{xlen}-GCC/softfloat.a')
    (out / 'build-manifest.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
