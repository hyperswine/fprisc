#!/usr/bin/env python3
"""Typed memory layouts (docs/LAYOUTS.md): `Node = Layout { ... }` is a nominal
pointer type over raw memory.  It computes offsets, it is a type of its own, a
malformed one is refused by name, and it costs nothing: the code a Layout
generates is no larger than the same function written with raw offsets, and no
accessor survives into a linked image.  Needs RISC-V GCC and QEMU."""
from pathlib import Path
import os, re, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
subprocess.run(['make', 'fpr'], check=True, capture_output=True, timeout=300)

def run(args, expected=0, timeout=120):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    assert p.returncode == expected, f'{args}: exit {p.returncode}, expected {expected}\n{p.stdout}\n{p.stderr}'
    return p.stdout + p.stderr

with tempfile.TemporaryDirectory(prefix='fpr-layout-') as temp:
    tmp = Path(temp)
    # 1. it runs: offsets, alignment, narrow and pinned fields, helpers, no leak
    image = tmp / 'list.elf'
    run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', 'PROG=tests/layouts/list.fpr', f'IMAGE={image}', f'BUILD={tmp}'], timeout=300)
    out = run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic', '-bios', 'none', '-kernel', image], timeout=30)
    for want in ['sum=42 sizeOf=32 tag=7 wide=513 second=2', 'offsets: next=8 tag=16 flags=20 wide=30',
                 'eq: self=True other=False null=True', 'index: third.b=99 stride=16', 'LAYOUTS HOLD live=0']:
        assert want in out, f'missing {want!r} in\n{out}'
    syms = run(['riscv64-unknown-elf-nm', image])
    assert not re.search(r'fpr_fn_(Node|Pair)_x2e', syms), 'an accessor survived into the image:\n' + syms
    print('Offsets, natural alignment, U8/U16/U32, a pinned field, null/eq/index; no accessor in the image: PASS')

    # 2. nominal: a Layout is not an Addr, and not another Layout
    def refused(name, body, *needles, flags=('--arc',)):
        src = tmp / f'{name}.fpr'
        src.write_text('profile builtin.\n' + body)
        p = subprocess.run(['./fprc', '--profile=bare-metal-builtin', *flags, str(src), str(tmp / 'bad.s')], capture_output=True, text=True, timeout=120)
        text = p.stdout + p.stderr
        assert p.returncode != 0, f'{name} should be refused:\n{text}'
        for n in needles:
            assert n in text, f'{name}: expected {n!r} in\n{text}'
    two = 'Node = Layout { value : Int, next : Node }.\nTask = Layout { id : Int, stack : Addr }.\n'
    refused('addr', two + 'main = Node.value (Mem.alloc 16).\n', 'cannot unify Node with Addr')
    refused('other', two + 'main = Node.value (Task.at (Mem.alloc 16)).\n', 'cannot unify Node with Task')
    refused('setter', two + 'main = Node.setNext (Node.null Unit) (Mem.alloc 16).\n', 'cannot unify Node with Addr')
    refused('field', two + 'main = Task.setStack (Task.null Unit) (Node.null Unit).\n', 'cannot unify')
    print('Nominal: an Addr is not a Node, a Task is not a Node, a setter takes its field\'s type: PASS')

    # 3. a malformed declaration says why
    refused('align', 'N = Layout { a : Word @ 3 }.\nmain = 0.\n', 'is not aligned to its 8-byte type Word', flags=())
    refused('twice', 'N = Layout { a : Word, a : Int }.\nmain = 0.\n', 'is declared twice', flags=())
    refused('clash', 'N = Layout { addr : Word }.\nmain = 0.\n', 'collides with the generated N.addr', flags=())
    print('Refused by name: a misaligned pin, a field declared twice, a field that collides with a helper: PASS')

    # 4. free: the same functions by hand and through a Layout, as raw library units
    hand = tmp / 'hand.fpr'
    hand.write_text('''profile builtin.
rd a o = Mem.readWord (Addr.add a o).
rdA a o = Addr.fromWord (Mem.readWord (Addr.add a o)).
isNil p = Addr.eq p (Addr.null Unit).
total n acc = case isNil n of True -> acc | False -> total (rdA n 8) (Word.add acc (rd n 0)).
bump n = Mem.writeWord (Addr.add n 0) (Word.add (rd n 0) (Word.fromInt 1)).
cTotal : Addr -> Word -> Word .
cTotal a acc = total a acc.
cBump : Addr -> Unit .
cBump a = bump a.
''')
    typed = tmp / 'typed.fpr'
    typed.write_text('''profile builtin.
Node = Layout { value : Word, next : Node }.
total n acc = case Node.isNull n of True -> acc | False -> total (Node.next n) (Word.add acc (Node.value n)).
bump n = Node.setValue n (Word.add (Node.value n) (Word.fromInt 1)).
cTotal : Addr -> Word -> Word .
cTotal a acc = total (Node.at a) acc.
cBump : Addr -> Unit .
cBump a = bump (Node.at a).
''')
    def body(asm, fn):
        lines, on = [], False
        for l in asm.splitlines():
            if l.startswith(f'fpr_fn_{fn}_x40'): on = True; continue
            if on and re.match(r'(fpr_|c_|\s*\.globl|\s*\.section|\s*\.weak)', l): break
            if on and l.strip() and not l.strip().startswith('#') and not l.rstrip().endswith(':'): lines.append(l.strip())
        assert lines, f'no body found for {fn}'
        return lines
    asms = {}
    for src in (hand, typed):
        out_s = tmp / (src.stem + '.s')
        run(['./fprc', '--profile=bare-metal-builtin', '--arc', '--raw', '--lib', '--export=cTotal:c_total,cBump:c_bump', src, out_s])
        asms[src.stem] = out_s.read_text()
    for fn in ('total', 'bump'):
        h, t = body(asms['hand'], fn), body(asms['typed'], fn)
        assert len(t) <= len(h), f'{fn}: the Layout version is larger ({len(t)} vs {len(h)} instructions)'
        assert not [l for l in t if re.search(r'(call|j) fpr_fn_Node_', l)], f'{fn}: an accessor was not inlined'
    print('Free: no accessor call remains, and each function is no larger than its hand-written twin: PASS')
