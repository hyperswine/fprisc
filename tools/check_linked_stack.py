#!/usr/bin/env python3
"""Prove RV64 IMC integer stack-pointer bounds from the exact linked image.

Calls, branches and stack adjustments come from executable bytes, including C
runtime code. No compiler report, symbol size or source annotation supplies a
bound. Indirect control flow, dynamic SP changes, incompatible stack joins and
retaining call cycles refuse. Returns use the ordinary ABI return contract;
this is not a memory-safety verifier or an interrupt/startup/WCET proof.
"""
import argparse
from collections import deque
from dataclasses import dataclass
import json
from pathlib import Path
import struct

try:
    from .check_target_image import admit, require
    from .riscv_compressed import expand
except ImportError:
    from check_target_image import admit, require
    from riscv_compressed import expand

MASK = (1 << 64) - 1


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


@dataclass(frozen=True)
class Stack:
    offset: int


@dataclass(frozen=True)
class Incoming:
    register: int


# Registers an ordinary synchronous integer activation must restore. Work
# admission also proves its precise return link and isolates frame stores.
PRESERVED = {0, 2, 3, 4, 8, 9, *range(18, 28)}


def plus(a, b):
    if isinstance(a, Incoming) and b == 0:
        return a
    if a == 0 and isinstance(b, Incoming):
        return b
    if isinstance(a, int) and isinstance(b, int):
        return (a + b) & MASK
    if isinstance(a, Stack) and isinstance(b, int):
        return Stack(a.offset + signed(b, 64))
    if isinstance(b, Stack) and isinstance(a, int):
        return Stack(b.offset + signed(a, 64))
    return None


class Image:
    def __init__(self, data):
        self.data = data
        # The physical image gate has already validated the ELF header/tables.
        require(data[4] == 2, 'linked stack proof requires RV64')
        h = struct.unpack_from('<HHIQQQIHHHHHH', data, 16)
        self.rvc = bool(h[6] & 1)  # EF_RISCV_RVC selects IALIGN=16.
        phoff, shoff, phsize, phcount, shsize, shcount = h[4], h[5], h[8], h[9], h[10], h[11]
        for i in range(phcount):
            kind = struct.unpack_from('<I', data, phoff + i * phsize)[0]
            require(kind not in (2, 3), 'dynamic/interpreted images are not admitted')
        sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shsize) for i in range(shcount)]
        self.code = []
        self.symbols = {}
        for s in sections:
            _, kind, flags, address, offset, size, link, _, _, stride = s
            if flags & 6 == 6 and kind == 1 and size:
                require(offset + size <= len(data), 'truncated executable section')
                self.code.append((address, address + size, offset))
            if kind != 2:  # SHT_SYMTAB; stripped images have no selected roots.
                continue
            require(stride == 24 and size % stride == 0 and offset + size <= len(data), 'invalid symbol table')
            require(link < len(sections) and sections[link][1] == 3, 'missing symbol string table')
            strings = sections[link]
            require(strings[4] + strings[5] <= len(data), 'truncated symbol strings')
            names = data[strings[4]:strings[4] + strings[5]]
            for pos in range(offset, offset + size, stride):
                name, info, _, index, value, _ = struct.unpack_from('<IBBHQQ', data, pos)
                if not index or not name:
                    continue
                require(name < len(names) and b'\0' in names[name:], 'invalid symbol name')
                label = names[name:names.index(b'\0', name)].decode('utf-8')
                # Local compiler labels can repeat across object files. Only
                # nonlocal definitions can be requested as public roots.
                if info >> 4 not in (1, 2):
                    continue
                require(label not in self.symbols, 'duplicate public symbol: ' + label)
                self.symbols[label] = (value, info >> 4)
        self.names = {}
        for name, (address, _) in sorted(self.symbols.items(), reverse=True):
            self.names[address] = name

    def instruction(self, pc):
        require(pc % (2 if self.rvc else 4) == 0, f'unaligned instruction at {pc:#x}')
        matches = [(start, end, offset) for start, end, offset in self.code if start <= pc and pc + 2 <= end]
        require(len(matches) == 1, f'control leaves executable bytes at {pc:#x}')
        start, end, offset = matches[0]
        half = struct.unpack_from('<H', self.data, offset + pc - start)[0]
        if half & 3 != 3:
            require(self.rvc, f'compressed instruction without ELF RVC flag at {pc:#x}')
            return expand(half), 2
        require(half & 31 != 31, f'unsupported instruction length at {pc:#x}')
        require(pc + 4 <= end, f'truncated instruction at {pc:#x}')
        return struct.unpack_from('<I', self.data, offset + pc - start)[0], 4

    def word(self, pc):
        return self.instruction(pc)[0]

    def label(self, address):
        return self.names.get(address, hex(address))


def function(image, entry, returning, *, control=None):
    """Forward constant/entry-SP interpretation; branches include both arms.

    A PC has one stack displacement. Other registers join to unknown when
    different paths disagree. Calls follow RV64 integer register preservation,
    shared by the C ABI and FPR's native allocator/frame convention. As with
    ABI returns, this is an explicit input contract, not a memory-safety proof.
    Direct tail transfers are followed as control flow in this activation.
    """
    initial = (0, None, Stack(0)) + (None,) * 29
    checked_return = control is not None
    if checked_return:
        initial = tuple(Incoming(i) if i in (PRESERVED | {1}) - {0, 2} else v for i, v in enumerate(initial))
    states, pending = {entry: initial}, deque([entry])
    frames = {entry: {}} if checked_return else None
    peak, edges, returns = 0, set(), False

    def enqueue(pc, state, frame):
        old = states.get(pc)
        if old is not None:
            require(old[2] == state[2], f'incompatible stack join at {pc:#x}')
            state = tuple(a if a == b else None for a, b in zip(old, state))
            if checked_return:
                frame = {k:v for k,v in frame.items() if k in frames[pc] and frames[pc][k] == v}
            if state == old and (not checked_return or frame == frames[pc]):
                return
        if checked_return:
            frames[pc] = frame
        states[pc] = state
        pending.append(pc)

    while pending:
        pc = pending.popleft()
        registers = list(states[pc])
        frame = dict(frames[pc]) if checked_return else None
        w, length = image.instruction(pc)
        op, rd, f3, rs1, rs2, f7 = w & 127, (w >> 7) & 31, (w >> 12) & 7, (w >> 15) & 31, (w >> 20) & 31, w >> 25
        imm = signed(w >> 20, 12)
        sp = registers[2]
        require(isinstance(sp, Stack), f'unknown stack pointer at {pc:#x}')
        peak = max(peak, -sp.offset)
        successors = [pc + length]
        callee = None
        write, value = False, None

        def transfer(target, call):
            nonlocal successors, registers, callee
            image.word(target)  # Check target even if a call never returns.
            if call:
                callee = target
                edges.add((target, -sp.offset))
                registers = [value if i in PRESERVED else None for i, value in enumerate(registers)]
                # Continuation is reachable only if the exact callee has an
                # ABI return path. This least fixed point handles panic/halt
                # calls without trusting a source noreturn declaration.
                successors = [pc + length] if target in returning else []
            else:
                successors = [target]

        if op in (0x37, 0x17):  # LUI / AUIPC
            write = True
            value = (signed(w & 0xfffff000, 32) + (pc if op == 0x17 else 0)) & MASK
        elif op in (0x13, 0x1b):  # Integer immediate / immediate word
            write = True
            a = registers[rs1]
            if f3 == 0:
                value = plus(a, imm & MASK)
            elif f3 in (1, 5):
                bits = 5 if op == 0x1b else 6
                upper = w >> (20 + bits)
                require(upper in ((0,) if f3 == 1 else (0, 0x20 if bits == 5 else 0x10)), f'invalid shift at {pc:#x}')
                shift = (w >> 20) & ((1 << bits) - 1)
                if shift == 0:
                    value = a  # RV64 C zero-shift HINTs preserve frame aliases.
                elif isinstance(a, int):
                    width = 32 if op == 0x1b else 64
                    value = a << shift if f3 == 1 else (signed(a & ((1 << width) - 1), width) if upper else a & ((1 << width) - 1)) >> shift
            else:
                require(op == 0x13 and f3 in (2, 3, 4, 6, 7), f'invalid immediate at {pc:#x}')
                if isinstance(a, int):
                    b = imm & MASK
                    value = {2: lambda: int(signed(a, 64) < imm), 3: lambda: int(a < b),
                             4: lambda: a ^ b, 6: lambda: a | b, 7: lambda: a & b}[f3]()
            if op == 0x1b and isinstance(value, int):
                value = signed(value & 0xffffffff, 32)
            elif op == 0x1b:
                value = None
        elif op in (0x33, 0x3b):
            require(f7 in (0, 1, 0x20) and (f7 != 0x20 or f3 in (0, 5)), f'invalid integer operation at {pc:#x}')
            require(op == 0x33 or (f7 == 1 and f3 in (0, 4, 5, 6, 7)) or (f7 != 1 and f3 in (0, 1, 5)), f'invalid word operation at {pc:#x}')
            write = True
            a, b = registers[rs1], registers[rs2]
            if f3 == 0 and f7 == 0:
                value = plus(a, b)
            elif f3 == 0 and f7 == 0x20 and isinstance(b, int):
                value = plus(a, (-b) & MASK)
            if op == 0x3b:
                value = signed(value & 0xffffffff, 32) if isinstance(value, int) else None
        elif op == 0x03:
            require(f3 in range(7), f'invalid load at {pc:#x}')
            write = True
            if checked_return and f3 == 3 and isinstance(registers[rs1], Stack):
                # Only a full-width load from an intact frame slot supplies
                # register/return provenance. Arbitrary memory stays unknown.
                value = frame.get(registers[rs1].offset + imm)
        elif op == 0x23:
            require(f3 in range(4), f'invalid store at {pc:#x}')
            if checked_return:
                require(isinstance(registers[rs1], Stack), f'callback store outside proved frame at {pc:#x}')
                offset = registers[rs1].offset + signed(((w >> 25) << 5) | rd, 12)
                width = 1 << f3
                require(sp.offset <= offset and offset + width <= 0, f'callback store outside proved frame at {pc:#x}')
                frame = {k:v for k,v in frame.items() if k+8 <= offset or offset+width <= k}
                if width == 8 and registers[rs2] is not None:
                    frame[offset] = registers[rs2]
        elif op == 0x63:
            require(f3 in (0, 1, 4, 5, 6, 7), f'invalid branch at {pc:#x}')
            displacement = signed(((w >> 31) << 12) | (((w >> 7) & 1) << 11) | (((w >> 25) & 63) << 5) | (((w >> 8) & 15) << 1), 13)
            successors.append(pc + displacement)
        elif op == 0x6f:
            require(rd in (0, 1), f'unsupported link register at {pc:#x}')
            displacement = signed(((w >> 31) << 20) | (((w >> 12) & 255) << 12) | (((w >> 20) & 1) << 11) | (((w >> 21) & 1023) << 1), 21)
            transfer(pc + displacement, rd == 1)
        elif op == 0x67:
            require(f3 == 0 and rd in (0, 1), f'unsupported indirect transfer at {pc:#x}')
            if rd == 0 and rs1 == 1 and imm == 0:
                require(sp.offset == 0, f'return with unrestored stack at {pc:#x}')
                if checked_return:
                    require(registers[1] == initial[1], f'unproved callback return address at {pc:#x}')
                    require(all(registers[i] == initial[i] for i in PRESERVED),
                            f'unrestored callback ABI register at {pc:#x}')
                successors = []
                returns = True
            else:
                base = registers[rs1]
                require(isinstance(base, int), f'unresolved indirect transfer at {pc:#x}')
                transfer(((base + imm) & MASK) & ~1, rd == 1)
        elif op == 0x0f:
            require(f3 in (0, 1) and rd == 0 and rs1 == 0, f'unsupported fence at {pc:#x}')
        else:
            raise ValueError(f'unsupported opcode {op:#x} at {pc:#x}')
        if write and rd:
            registers[rd] = value & MASK if isinstance(value, int) else value
        current = registers[2]
        require(isinstance(current, Stack), f'dynamic stack adjustment at {pc:#x}')
        require(-MASK <= current.offset <= 0 and current.offset % 16 == 0, f'invalid stack displacement at {pc:#x}')
        peak = max(peak, -current.offset)
        if checked_return and current.offset > sp.offset:
            frame = {k:v for k,v in frame.items() if k >= current.offset}
        if control is not None:
            # Keep the call separate from its possible continuation so a
            # work proof can count each matched callee invocation.
            control[pc] = (callee, tuple(successors))
        for target in successors:
            enqueue(target, tuple(registers), frame)
    return dict(local=peak, calls=sorted(edges), instructions=len(states), returns=returns, pcs=sorted(states),
                compressed=sum(image.instruction(pc)[1] == 2 for pc in states))


def reachable_functions(image, roots, *, include_control=False):
    """Compute reachable code and may-return facts together, from final bytes."""
    functions, pending, returning, dependents = {}, list(roots), set(), {}
    while pending:
        address = pending.pop()
        try:
            graph = {} if include_control else None
            facts = function(image, address, returning, control=graph)
            if include_control:
                facts["control"] = graph
        except ValueError as exc:
            raise ValueError(image.label(address) + ': ' + str(exc)) from exc
        functions[address] = facts
        for callee, _ in facts['calls']:
            dependents.setdefault(callee, set()).add(address)
            if callee not in functions and callee not in pending:
                pending.append(callee)
        if facts['returns'] and address not in returning:
            returning.add(address)
            pending.extend(dependents.get(address, set()) - set(pending))
    return functions


def prove(data, manifest, target, entries):
    receipt = admit(data, manifest, target)
    require(entries and len({name for name, _ in entries}) == len(entries), 'missing/duplicate stack entries')
    image = Image(data)
    roots = []
    for name, limit in entries:
        require(type(limit) is int and 0 < limit <= MASK, 'stack budget must be a positive RV64 integer')
        require(name in image.symbols, 'missing stack entry: ' + name)
        address, binding = image.symbols[name]
        require(binding == 1, 'weak stack entry: ' + name)
        roots.append((name, address, limit))
    functions = reachable_functions(image, (address for _, address, _ in roots))
    # Max-plus fixed point. With nonnegative retained sizes, N relaxations
    # suffice for every simple path. Any further increase proves a retaining
    # cycle; tail/zero-retaining cycles converge without an arbitrary budget.
    bounds = {address: f['local'] for address, f in functions.items()}
    for _ in range(len(functions)):
        updated = {address: max([f['local']] + [retained + bounds[callee] for callee, retained in f['calls']])
                   for address, f in functions.items()}
        if updated == bounds:
            break
        bounds = updated
    else:
        raise ValueError('retaining call cycle has no finite stack bound')
    admitted = []
    for name, address, limit in roots:
        need = bounds[address]
        require(need <= limit, f'{name}: needs {need} stack bytes, limit {limit}')
        admitted.append(dict(symbol=name, address=address, peak_bytes=need, limit_bytes=limit))
    return dict(schema='linked-rv64-stack-v2', image=receipt, entries=admitted,
                functions=[dict(symbol=image.label(address), address=address, local_bytes=f['local'],
                                peak_bytes=bounds[address], instructions=f['instructions'], compressed_instructions=f['compressed'], may_return=f['returns'],
                                calls=[dict(address=c, symbol=image.label(c), retained_bytes=r) for c, r in f['calls']])
                           for address, f in sorted(functions.items())],
                scope='ordinary ABI entry SP; synchronous RV64 IMC integer code; no asynchronous traps, startup or stack switching',
                assumptions=['Valid memory accesses and RV64 integer callee-saved register/return ABI, shared by the FPR native frame convention.',
                             'No asynchronous interrupt, fault-handler stack, stack switching or concurrent mutation of executable bytes.'])


def parse_entries(items):
    entries = []
    for item in items:
        name, separator, size = item.rpartition(':')
        require(separator and name and size.isascii() and size.isdecimal(), 'entry must be symbol:positive-bytes')
        entries.append((name, int(size)))
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--entry', action='append', required=True, help='public symbol:stack byte limit')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        entries = parse_entries(args.entry)
        result = prove(args.image.read_bytes(), args.manifest.read_bytes(), args.target, entries)
    except (OSError, ValueError, struct.error) as exc:
        parser.exit(1, f'linked stack refused: {exc}\n')
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + '\n')
    for entry in result['entries']:
        print(f"linked stack admitted: {entry['symbol']}: {entry['peak_bytes']}/{entry['limit_bytes']} bytes")


if __name__ == '__main__':
    main()
