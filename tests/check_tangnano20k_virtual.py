#!/usr/bin/env python3
"""Virtual-device protocol, rooted filesystem and refusal checks (no FPGA)."""
import tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0,str(root/'tools'))
from run_tangnano20k_base import Device,frame,parse,MAX_PAYLOAD
from check_tangnano20k_isa import check
report='ELF64 little endian\nFlags: 0x0\nTag_RISCV_arch: "rv64i2p1_m2p0_zicsr2p0_zifencei2p0_zmmul1p0"'
check(report)
for invalid in [report.replace('0x0','0x1'), report.replace('_m2p0','_m2p0_a2p1'), report.replace('_m2p0','_m2p0_f2p2_d2p2'), report.replace('ELF64','ELF32')]:
    try:check(invalid)
    except ValueError:pass
    else:raise AssertionError(invalid)
with tempfile.TemporaryDirectory() as temp:
    d=Device(temp,{'WASM_DIR':'wasm'},['line'])
    for op,data in [(3,b'hello\0world'),(4,b'hello\0!')]:assert d.dispatch(op,data)==(0,b'')
    assert d.dispatch(1,b'hello')==(0,b'world!')
    assert d.dispatch(2,b'hello')==(0,b'1')
    assert d.dispatch(2,b'missing')==(0,b'0')
    assert d.dispatch(1,b'../escape')[0]==1
    assert d.dispatch(1,b'/etc/passwd')[0]==1
    Path(temp,'outside').symlink_to('/etc')
    assert d.dispatch(1,b'outside/passwd')[0]==1
    assert d.dispatch(5,b'WASM_DIR')==(0,b'wasm')
    assert d.dispatch(5,b'UNSET')==(1,b'unset')
    assert d.dispatch(8,b'')==(0,b'line')
    assert d.dispatch(8,b'')==(1,b'eof')
    assert d.dispatch(1,b'missing')[0]==1
    assert d.dispatch(6,b'invalid')[0]==1
    assert d.dispatch(8,b'invalid')[0]==1
    assert d.dispatch(3,b'no separator')[0]==1
    assert d.dispatch(255,b'')==(1,b'virtual operation unavailable')
    for payload in [b'',b'\x00\x03\xff',b'hello\nworld']:
        assert parse(frame(1,1,payload))==(1,1,payload)
    bad=[b'@FPR1 -0000001 01 00000000  00\n',frame(1,1,b'abc').replace(b' 60\n',b' 00\n'),b'@FPR1 00000001 01 00200000  00\n',b'@FPR1 00000001 01 00000002 00 00\n']
    for value in bad:
        try:parse(value)
        except ValueError:pass
        else:raise AssertionError(value)
print('PASS: framing, checksum/length refusal, file read/write/append, rooted paths/symlinks, environment, input, unavailable service')
# The hardware ABI uses no binary ETX in request/reply frames.
assert b'\x03' not in frame(7,1,bytes(range(256)))
