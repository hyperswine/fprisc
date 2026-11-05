"""Independent instruction-step SP observations for the linked stack gate."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.check_linked_stack import Image, function, prove


def qualify(image_path, target, names, expected_calls):
    data = image_path.read_bytes()
    manifest = json.dumps(target).encode()
    discovery = prove(data, manifest, target['target'], [(n, 65536) for n in names])
    exact = [(e['symbol'], e['peak_bytes']) for e in discovery['entries']]
    receipt = prove(data, manifest, target['target'], exact)
    for name, size in exact:
        try:
            prove(data, manifest, target['target'], [(name, size - 1)])
        except ValueError as exc:
            assert 'needs' in str(exc), str(exc)
        else:
            raise AssertionError('one-byte-short linked stack admitted')
    image = Image(data)
    returning = {f['address'] for f in receipt['functions'] if f['may_return']}
    pcs = sorted({pc for f in receipt['functions'] for pc in function(image, f['address'], returning)['pcs']})
    covered = set(pcs)
    # Trace the complete executable regions, independently of the proof's CFG.
    # Filtering to predicted PCs could hide an incorrectly omitted path and
    # make an underestimated bound appear to agree with the execution oracle.
    ranges = [(start,end-1) for start,end,_ in image.code]
    trace = image_path.with_suffix('.cpu.log')
    command = ['qemu-system-riscv64', '-machine', 'virt', '-m', '16M', '-nographic', '-bios', 'none',
               '-accel', 'tcg,one-insn-per-tb=on', '-d', 'cpu,nochain',
               '-dfilter', ','.join(f'{a:#x}..{b:#x}' for a, b in ranges), '-D', str(trace), '-kernel', str(image_path)]
    p = subprocess.run(command, capture_output=True, text=True, timeout=180)
    assert p.returncode == 0 and 'HEAP_BUDGET_FIXED_ARENAS_PASS' in p.stdout, (p.returncode, p.stdout, p.stderr)
    entries = {e['address']: e for e in receipt['entries']}
    observed = {name: [] for name in names}
    active, pc, steps = None, None, 0
    digest = hashlib.sha256()
    with trace.open('rb') as stream:
        for raw in stream:
            digest.update(raw)
            line = raw.decode('ascii')
            if m := re.match(r' pc\s+([0-9a-f]+)', line):
                pc = int(m[1], 16)
            elif m := re.search(r'x1/ra\s+([0-9a-f]+)\s+x2/sp\s+([0-9a-f]+)', line):
                assert pc is not None
                ra, sp = (int(x, 16) for x in m.groups())
                if active is None and pc in entries:
                    active = dict(entry=entries[pc], initial=sp, low=sp, return_pc=ra)
                if active is not None:
                    assert pc in covered, hex(pc)
                    steps += 1
                    active['low'] = min(active['low'], sp)
                    # End at the final ABI return, including a tail-called C
                    # callee. Internal returns do not have the caller's RA/SP.
                    if image.word(pc) == 0x00008067 and ra == active['return_pc'] and sp == active['initial']:
                        used = active['initial'] - active['low']
                        assert used <= active['entry']['peak_bytes'], (active, used)
                        observed[active['entry']['symbol']].append(used)
                        active = None
                pc = None
    assert active is None and sum(map(len, observed.values())) == expected_calls, (active, observed)
    assert all(observed.values()) and steps > expected_calls
    result = dict(proof=receipt, execution='RV64-QEMU-instruction-step-pass',
                  observed_peak_bytes={name: max(samples) for name, samples in observed.items()},
                  invocations={name: len(samples) for name, samples in observed.items()},
                  observed_instruction_steps=steps, trace_scope='all executable sections, independent of predicted CFG',
                  trace_sha256=digest.hexdigest(), trace_bytes=trace.stat().st_size)
    trace.unlink()
    print('Linked stack: exact/short budgets and unmodified instruction-step observations PASS', result['observed_peak_bytes'], flush=True)
    return result
