#!/usr/bin/env python3
"""Execute typed hosted/QOS x64 kernels against independent C references."""
import argparse
import tempfile
from pathlib import Path
from check_typed_ir_kernels import check_targets, FIX
from x64_probe import environment, host


def main():
    if host() is None:
        print('x64 vector execution SKIP: requires native x64 or Rosetta')
        return
    with tempfile.TemporaryDirectory(prefix='fpr-x64-vectors-') as d:
        tmp = Path(d)
        env = environment(tmp / 'cache')
        support = (FIX / 'kernel_oracle.c').read_text().split('extern V fpr_fn_probeDiv')[0]
        fixtures = [('kernels', (FIX / 'kernel_oracle.c').read_text(), 6, 4, False),
                    ('record_kernels', support + (FIX / 'record_oracle.c').read_text(), 5, 1, False),
                    ('record_float_kernels', support + (FIX / 'record_float_oracle.c').read_text(), 3, 0, True),
                    ('f32_kernels', support + (FIX / 'f32_oracle.c').read_text(), 3, 0, True),
                    ('pairsum_kernels', support + (FIX / 'pairsum_oracle.c').read_text(), 1, 0, False)]
        for name, oracle, count, traps, floating in fixtures:
            check_targets(env, tmp, argparse.Namespace(require_execution=True), FIX / (name + '.fpr'),
                          oracle, count, traps, floating, targets=('x64', 'qx64'))


if __name__ == '__main__':
    main()
