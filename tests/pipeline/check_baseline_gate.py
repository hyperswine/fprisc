#!/usr/bin/env python3
"""Exercise the P0 gate without timing noise or a native toolchain."""
import copy
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('baseline', Path(__file__).resolve().parents[2] / 'tools/pipeline-baseline.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
base = {'entries': {'f': {'behaviour': {'stdout': 'ok'},
    'coverage': {'complete': True, 'units': []}, 'remarks': [],
    'compile': {'allocated_bytes': 100}, 'code': {'asm_bytes': 100},
    'cost': {'alloc_bytes': 0},
    'functions': {'f': {'spills': 0, 'segmax': 10, 'frame': 0, 'loops': 0}}}}}
def compare(fresh, same=True):
    return b.compare(base, fresh, .1, same, False)
assert compare(copy.deepcopy(base)) == ([], [])
for key, value in [('allocated_bytes', 111), ('allocated_bytes', 89)]:
    fresh = copy.deepcopy(base); fresh['entries']['f']['compile'][key] = value
    assert compare(fresh)[0]
    failures, drift = compare(fresh, False)
    assert not failures and drift
fresh = copy.deepcopy(base); fresh['entries']['f']['compile']['allocated_bytes'] = 110
assert not compare(fresh)[0]
fresh = copy.deepcopy(base); fresh['entries']['f']['cost']['alloc_bytes'] = 1
assert compare(fresh)[0]
fresh = copy.deepcopy(base); fresh['entries']['f']['functions']['f']['spills'] = 1
assert compare(fresh)[0] and not compare(fresh, False)[0]
fresh = copy.deepcopy(base); fresh['entries']['f']['behaviour']['stdout'] = 'wrong'
assert compare(fresh, False)[0]
fresh = copy.deepcopy(base); fresh['entries']['f']['functions']['f']['segmax'] = None
assert compare(fresh, False)[0]
# Exercise the actual CLI return code as well as its comparison helper.
import contextlib, io, json, sys, tempfile
with tempfile.TemporaryDirectory() as directory:
    old = dict(base, host='test-host', compiler_sha256='same', unverified=[])
    fresh = copy.deepcopy(old); fresh['entries']['f']['compile']['allocated_bytes'] = 111
    out = Path(directory) / 'baseline.json'; out.write_text(json.dumps(old))
    b.record = lambda *_args: fresh
    sys.argv = ['pipeline-baseline.py', '--check', '--out', str(out)]
    with contextlib.redirect_stdout(io.StringIO()):
        assert b.main() == 1
        fresh['compiler_sha256'] = 'new'
        assert b.main() == 0
        fresh['entries']['f']['behaviour']['stdout'] = 'wrong'
        assert b.main() == 1
print('P0 baseline gate: tolerance, zero baseline, per-function drift, changed compiler and behavior PASS')
