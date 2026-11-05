#!/usr/bin/env python3
"""Admit a linked Linux ARM64 entry through return or fuel-exhaustion runtime entry.

Reads executable LOAD bytes. A stack-window certificate is conditional on the
actual actor window and writable stack at entry. It does not time the scheduler.
"""

import argparse
from copy import deepcopy
from dataclasses import dataclass, field
import hashlib
import json
import os
import tempfile
from pathlib import Path
import struct


def require(ok, why):
    if not ok:
        raise ValueError(why)


def signed(bits, width):
    return bits - (1 << width) if bits & (1 << (width - 1)) else bits


class Image:
    """Fixed-address ELF64 with immutable executable mappings and defined symbols."""

    def __init__(self, data):
        require(
            len(data) >= 64 and data[:7] == b"\x7fELF\x02\x01\x01",
            "expected little-endian ELF64",
        )
        typ, machine, ver, _, ph, sh, _, eh, ps, pn, ss, sn, _ = struct.unpack_from(
            "<HHIQQQIHHHHHH", data, 16
        )
        require(
            (typ, machine, ver, eh, ps, ss) == (2, 183, 1, 64, 56, 64),
            "expected linked AArch64 ET_EXEC",
        )
        require(
            pn and sn and ph + ps * pn <= len(data) and sh + ss * sn <= len(data),
            "invalid ELF tables",
        )
        self.data = data
        self.code = []
        dynamic = []
        loads = []
        for j in range(pn):
            kind, flags, off, at, _, filesz, memsz, _ = struct.unpack_from(
                "<IIQQQQQQ", data, ph + ps * j
            )
            if kind == 2:
                require(
                    off + filesz <= len(data) and filesz % 16 == 0,
                    "invalid dynamic table",
                )
                dynamic.append((off, filesz))
            if kind != 1:
                continue
            require(
                filesz <= memsz and off + filesz <= len(data) and at + memsz <= 2**64,
                "invalid LOAD",
            )
            require(
                all(at + memsz <= lo or hi <= at for lo, hi in loads),
                "overlapping LOADs",
            )
            loads.append((at, at + memsz))
            if flags & 1:
                require(not flags & 2, "writable executable LOAD")
                self.code.append((at, at + filesz, off))
        for off, size in dynamic:
            for pos in range(off, off + size, 16):
                tag, val = struct.unpack_from("<qQ", data, pos)
                if not tag:
                    break
                require(
                    tag != 22 and not (tag == 30 and val & 4),
                    "dynamic text relocations",
                )
        sections = [
            struct.unpack_from("<IIQQQQIIQQ", data, sh + ss * j) for j in range(sn)
        ]
        self.names = {}
        self.function_entries = set()
        for _, kind, _, _, off, size, link, _, _, stride in sections:
            if kind != 2:
                continue
            require(
                stride == 24
                and size % stride == 0
                and off + size <= len(data)
                and link < sn,
                "invalid symbol table",
            )
            _, t, _, _, strings, nbytes, *_ = sections[link]
            require(t == 3 and strings + nbytes <= len(data), "invalid string table")
            names = data[strings : strings + nbytes]
            for pos in range(off, off + size, 24):
                idx, info, _, section, addr, _ = struct.unpack_from(
                    "<IBBHQQ", data, pos
                )
                if (
                    not 0 < section < sn
                    or info >> 4 not in (0, 1)
                    or (info & 15) not in (0, 2)
                    or not sections[section][2] & 4
                ):
                    continue
                require(idx < len(names), "bad symbol name")
                end = names.find(b"\0", idx)
                require(end >= idx, "unterminated symbol name")
                name = names[idx:end].decode()
                _, _, _, va, file_offset, extent, *_ = sections[section]
                if (
                    name
                    and va <= addr < va + extent
                    and any(
                        start <= addr < stop
                        and off + addr - start == file_offset + addr - va
                        for start, stop, off in self.code
                    )
                ):
                    self.names.setdefault(addr, set()).add(name)
                    if info & 15 == 2 or name.startswith("fpr_"):
                        self.function_entries.add(addr)
        self.addresses = {}
        for address, names in self.names.items():
            for name in names:
                self.addresses.setdefault(name, []).append(address)
        self.digest = hashlib.sha256(data).hexdigest()

    def word(self, pc):
        require(pc % 4 == 0, "unaligned PC")
        for start, end, off in self.code:
            if start <= pc and pc + 4 <= end:
                return struct.unpack_from("<I", self.data, off + pc - start)[0]
        raise ValueError(f"no executable LOAD at {pc:#x}")

    def symbol(self, name):
        addresses = self.addresses.get(name, [])
        require(len(addresses) == 1, "missing or ambiguous linked symbol " + name)
        return addresses[0]


@dataclass(frozen=True)
class Stack:
    offset: int


@dataclass(frozen=True)
class Link:
    pc: int | None


@dataclass(frozen=True)
class Incoming:
    reg: int


@dataclass
class Frame:
    entry: int
    sp: int
    link: Link
    preserved: tuple
    fuel: int


@dataclass
class PathState:
    pc: int
    fuel: int
    regs: list
    frames: list
    sp: int = 0
    memory: dict = field(default_factory=dict)
    count: int = 0
    window: int = 0
    depth: int = 0
    ticks: int = 0
    seen: set = field(default_factory=set)
    comparison: tuple | None = None

    def value(self, i):
        return self.regs[i] if i != 31 else 0

    def base(self, i):
        return Stack(self.sp) if i == 31 else self.regs[i]

    def write(self, i, v, pc):
        if i != 31:
            require(i != 28 or v == HART, f"hart register changed at {pc:#x}")
            self.regs[i] = v

    def set_sp(self, v, pc):
        require(
            isinstance(v, Stack)
            and -(2**64) < v.offset <= self.frames[-1].sp
            and v.offset % 16 == 0,
            f"unproved SP at {pc:#x}",
        )
        if v.offset > self.sp:
            self.memory = {k: x for k, x in self.memory.items() if k >= v.offset}
        self.sp = v.offset
        self.depth = max(self.depth, -self.sp)

    def slot(self, i, disp, width, pc):
        b = self.base(i)
        require(isinstance(b, Stack), f"unproved memory base at {pc:#x}")
        at = b.offset + disp
        require(
            self.sp <= at and at + width <= self.frames[-1].sp and at % 8 == 0,
            f"out-of-frame access at {pc:#x}",
        )
        return at

    def restored(self):
        return (
            self.sp == self.frames[-1].sp
            and self.regs[30] == self.frames[-1].link
            and tuple(self.regs[i] for i in PRESERVED) == self.frames[-1].preserved
        )


# These words implement sp - hart->stk_lo < hart->stk_span (unsigned).
# Both offsets are independently pinned by the deployed C ABI. The compiler
# may reload x9 after migration; each accepted prefix takes it from x28.
WINDOW = (
    0xAA1C03E9,
    0x910003EA,
    0xF940E52B,
    0xCB0B014A,
    0xF940E92B,
    0xEB0B015F,
    0x540000A3,
)
FUEL = (0xF840012A, 0xD100054A, 0xF800012A, 0xF100015F, 0x5400004C)
HART = Incoming(28)
PRESERVED = range(19, 30)
FUEL_SAVE = (
    0xA9B37BFD,
    0x910003FD,
    *(
        0xA9000000 | ((2 + i) << 15) | ((i + 1) << 10) | (31 << 5) | i
        for i in range(0, 16, 2)
    ),
    *(
        0x6D000000 | ((18 + i) << 15) | ((i + 1) << 10) | (31 << 5) | i
        for i in range(0, 8, 2)
    ),
)


def target(pc, w):
    return pc + 4 * signed(w & 0x3FFFFFF, 26)


def bl_to(image, pc, name):
    word = image.word(pc)
    require(
        word >> 26 == 0x25 and name in image.names.get(target(pc, word), ()),
        f"expected direct {name} call at {pc:#x}",
    )
    dest = target(pc, word)
    if name != "fpr_fuel_save_local":
        require(dest == image.symbol(name), f"ambiguous runtime boundary {name}")
    return dest


def words(image, pc, expected):
    return all(image.word(pc + 4 * i) == v for i, v in enumerate(expected))


MASK = 2**64 - 1


def branch_condition(cond, comparison):
    if comparison is None:
        return None
    a, b = comparison
    result = (a - b) & MASK
    z = result == 0
    n = result >> 63
    c = a >= b
    v = ((a ^ b) & (a ^ result)) >> 63
    tests = (z, c, bool(n), bool(v), c and not z, n == v, n == v and not z, True)
    verdict = tests[cond >> 1]
    return not verdict if cond & 1 and cond != 15 else verdict


def admit(
    image,
    name,
    fuel,
    limit,
    room=None,
    writable=None,
    arguments=None,
    analysis_limit=1_000_000,
):
    require(
        type(fuel) is int and 0 < fuel < 2**63,
        "incoming fuel must be positive signed 64-bit",
    )
    require(type(limit) is int and 0 < limit < 2**64, "invalid instruction budget")
    require(
        all(n is None or type(n) is int and 0 <= n < 2**64 for n in (room, writable)),
        "invalid stack capacity",
    )
    require(name.startswith("fpr_fn_"), "expected generated function entry")
    require(
        type(analysis_limit) is int and analysis_limit > 0,
        "invalid verifier work budget",
    )
    arguments = {} if arguments is None else arguments
    require(
        all(
            type(i) is int and 0 <= i <= 7 and type(v) is int and 0 <= v <= MASK
            for i, v in arguments.items()
        ),
        "argument requires x0..x7 and an unsigned 64-bit word",
    )
    root = image.symbol(name)
    regs = [Incoming(i) for i in range(31)]
    for i, v in arguments.items():
        regs[i] = v
    regs[30] = Link(None)
    pending = [
        PathState(
            root,
            fuel,
            regs,
            [Frame(root, 0, regs[30], tuple(regs[i] for i in PRESERVED), fuel)],
        )
    ]
    outcomes = {}
    guards = set()
    calls = set()

    def generated(pc):
        return any(n.startswith("fpr_fn_") for n in image.names.get(pc, ()))

    def charge(s, n):
        s.count += n
        require(s.count <= limit, f"instruction budget {limit} exceeded at {s.pc:#x}")

    def complete(s, outcome):
        r = outcomes.setdefault(
            outcome,
            dict(
                max_instructions=0,
                stack_window_bytes=0,
                writable_stack_bytes=0,
                max_ticks=0,
            ),
        )
        for k, v in [
            ("max_instructions", s.count),
            ("stack_window_bytes", s.window),
            ("writable_stack_bytes", s.depth),
            ("max_ticks", s.ticks),
        ]:
            r[k] = max(r[k], v)

    analyzed = 0
    while pending:
        s = pending.pop()
        while True:
            analyzed += 1
            require(
                analyzed <= analysis_limit,
                "verifier work budget exhausted before proof",
            )
            pc = s.pc
            if pc in image.function_entries:
                require(generated(pc), f"unproved runtime entry at {pc:#x}")
            # Repeated control with the same remaining fuel cannot be given
            # an input-independent bound by this interpreter.
            key = (pc, len(s.frames), s.frames[-1].link)
            require(key not in s.seen, f"unproved cycle before a fuel tick at {pc:#x}")
            s.seen.add(key)
            w = image.word(pc)
            frame = s.frames[-1]

            if w == WINDOW[0] and image.word(pc + 4) == WINDOW[1]:
                require(
                    words(image, pc, WINDOW) and s.regs[28] == HART,
                    f"unproved stack guard at {pc:#x}",
                )
                # Validate the skipped growth/rebase arm and exact rejoin.
                bl_to(image, pc + 28, "fpr_stack_grow")
                require(
                    words(image, pc + 32, (0xB4000040, 0x9100001F, 0xAA1C03E9)),
                    f"invalid growth rejoin at {pc:#x}",
                )
                s.window = max(s.window, -s.sp)
                guards.add(pc)
                s.regs[9:12] = [HART, None, None]
                s.comparison = None
                s.pc = pc + 44
                charge(s, 7)
                continue
            if w == FUEL[0] and s.regs[9] == HART:
                require(words(image, pc, FUEL), f"invalid fuel update at {pc:#x}")
                shim = bl_to(image, pc + 20, "fpr_fuel_save_local")
                charge(s, 5)
                s.ticks += 1
                s.fuel -= 1
                s.seen.clear()
                s.regs[10] = s.fuel
                s.comparison = (s.fuel, 0)
                if s.fuel:
                    s.pc = pc + 24
                    continue
                require(words(image, shim, FUEL_SAVE), "unproved fuel save prefix")
                bl_to(image, shim + 4 * len(FUEL_SAVE), "fpr_fuel_exhausted")
                charge(s, 1 + len(FUEL_SAVE) + 1)
                s.depth = max(s.depth, 208 - s.sp)
                complete(s, "fuel_runtime")
                break

            charge(s, 1)
            rd = w & 31
            rn = (w >> 5) & 31
            rt2 = (w >> 10) & 31
            s.pc = pc + 4
            if w & 0xFF800000 in (
                0x91000000,
                0xD1000000,
            ):  # ADD/SUB X immediate, incl. MOV SP
                imm = ((w >> 10) & 4095) << (12 if w & (1 << 22) else 0)
                diff = imm if w & 0xFF800000 == 0x91000000 else -imm
                v = s.base(rn)
                if isinstance(v, Stack):
                    new = Stack(v.offset + diff)
                elif isinstance(v, int):
                    new = (v + diff) & MASK
                else:
                    new = v if diff == 0 else None
                if rd == 31:
                    s.set_sp(new, pc)
                else:
                    s.write(rd, new, pc)
            elif w & 0xFFE0FFE0 == 0xAA0003E0:  # MOV Xd,Xm (ORR Xd,XZR,Xm)
                s.write(rd, s.value((w >> 16) & 31), pc)
            elif w & 0xFFC00000 in (0xA9000000, 0xA9400000):  # STP/LDP X, signed offset
                require(rd != rt2 or not w & (1 << 22), "ambiguous pair load")
                at = s.slot(rn, 8 * signed((w >> 15) & 127, 7), 16, pc)
                if w & (1 << 22):
                    s.write(rd, s.memory.get(at), pc)
                    s.write(rt2, s.memory.get(at + 8), pc)
                else:
                    s.memory[at] = s.value(rd)
                    s.memory[at + 8] = s.value(rt2)
            elif w & 0xFFE00C00 in (0xF8000000, 0xF8400000) or w & 0xFFC00000 in (
                0xF9000000,
                0xF9400000,
            ):
                disp = (
                    8 * ((w >> 10) & 4095)
                    if w & (1 << 24)
                    else signed((w >> 12) & 511, 9)
                )
                at = s.slot(rn, disp, 8, pc)
                if w & (1 << 22):
                    s.write(rd, s.memory.get(at), pc)
                else:
                    s.memory[at] = s.value(rd)
            elif w & 0xFFE0FC00 == 0x8B000000:  # ADD Xd,Xn,Xm, LSL #0
                a, b = s.value(rn), s.value((w >> 16) & 31)
                s.write(
                    rd,
                    (a + b) & MASK
                    if isinstance(a, int) and isinstance(b, int)
                    else None,
                    pc,
                )
            elif w & 0xFFC00000 in (0x93400000, 0xD3400000):  # 64-bit SBFM/UBFM
                a = s.value(rn)
                r = (w >> 16) & 63
                m = (w >> 10) & 63
                is_signed = w & 0xFFC00000 == 0x93400000
                require(
                    m >= r or (not is_signed and r == m + 1),
                    f"unproved bitfield at {pc:#x}",
                )
                result = None
                if isinstance(a, int):
                    if m < r:
                        result = (a << (64 - r)) & MASK
                    else:
                        width = m - r + 1
                        bits = (a >> r) & ((1 << width) - 1)
                        result = (signed(bits, width) & MASK) if is_signed else bits
                s.write(rd, result, pc)
            elif w & 0xFFFFFC00 == 0xB2400000:  # ORR Xd,Xn,#1
                require(rd != 31, f"unproved logical-immediate SP write at {pc:#x}")
                a = s.value(rn)
                s.write(rd, a | 1 if isinstance(a, int) else None, pc)
            elif w & 0xFFE0FC1F == 0xEB00001F:  # CMP Xn,Xm, LSL #0
                a, b = s.value(rn), s.value((w >> 16) & 31)
                s.comparison = (
                    (a, b) if isinstance(a, int) and isinstance(b, int) else None
                )
            elif w >> 26 == 0x25:  # BL, ordinary generated ABI
                dest = target(pc, w)
                require(
                    generated(dest),
                    f"unproved call at {pc:#x} to {image.names.get(dest, dest)}",
                )
                require(
                    not any(f.entry == dest and f.fuel == s.fuel for f in s.frames),
                    f"unproved recursive call without a fuel tick at {pc:#x}",
                )
                s.regs[30] = Link(pc + 4)
                s.frames.append(
                    Frame(
                        dest,
                        s.sp,
                        s.regs[30],
                        tuple(s.regs[i] for i in PRESERVED),
                        s.fuel,
                    )
                )
                calls.add((pc, dest))
                s.pc = dest
            elif w >> 26 == 0x5:  # B, including tail transfer
                dest = target(pc, w)
                if generated(dest):
                    require(s.restored(), f"unrestored tail transfer at {pc:#x}")
                    calls.add((pc, dest))
                s.pc = dest
            elif w == 0xD65F03C0:  # RET X30
                require(s.restored(), f"unrestored return at {pc:#x}")
                s.frames.pop()
                if not s.frames:
                    complete(s, "return")
                    break
                s.pc = frame.link.pc
            elif w & 0xFF000010 == 0x54000000 or w & 0x7E000000 in (
                0x34000000,
                0x36000000,
            ):
                # Without operand/range evidence either arm is possible.
                width = 14 if w & 0x7E000000 == 0x36000000 else 19
                dest = pc + 4 * signed((w >> 5) & ((1 << width) - 1), width)
                if w & 0xFF000010 == 0x54000000:
                    take = branch_condition(w & 15, s.comparison)
                else:
                    a = s.value(rd)
                    take = None
                    if isinstance(a, int):
                        if width == 14:
                            bit = ((w >> 26) & 32) | ((w >> 19) & 31)
                            nonzero = bool(a & (1 << bit))
                        else:
                            nonzero = bool(a & (MASK if w >> 31 else 0xFFFFFFFF))
                        take = nonzero if w & (1 << 24) else not nonzero
                if take is True:
                    s.pc = dest
                elif take is None and dest != s.pc:
                    branch = deepcopy(s)
                    branch.pc = dest
                    pending.append(branch)
            elif w == 0xD503201F:  # NOP
                pass
            else:
                raise ValueError(f"unproved instruction {w:08x} at {pc:#x}")
    need = max(r["stack_window_bytes"] for r in outcomes.values())
    depth = max(r["writable_stack_bytes"] for r in outcomes.values())
    require(
        room is None or room >= need,
        f"needs {need} bytes above stack-window low bound; supplied {room}",
    )
    require(
        writable is None or writable >= depth,
        f"needs {depth} writable stack bytes; supplied {writable}",
    )
    return dict(
        schema="linked-aarch64-fuel-v1",
        image_sha256=image.digest,
        entry=name,
        address=root,
        incoming_fuel=fuel,
        argument_words={f"x{i}": v for i, v in sorted(arguments.items())},
        verifier_states=analyzed,
        verifier_limit=analysis_limit,
        limit=limit,
        required=max(r["max_instructions"] for r in outcomes.values()),
        outcomes=outcomes,
        stack_window_bytes=need,
        writable_stack_bytes=depth,
        window_limit=room,
        writable_limit=writable,
        guards=sorted(guards),
        direct_calls=sorted(calls),
        assumptions=[
            "Trusted linked FP-RISC runtime bindings and 64-bit dedicated-hart ABI (fuel at 0, stack window low/span at 456/464).",
            "Aligned entry SP is inside the current owned half-open stack window with the reported room below SP.",
            "x28 names the current hart; offset zero holds the supplied positive fuel. Window, stack and code are stable until handoff.",
            "All traced instructions and ordinary stack accesses complete without an asynchronous trap, signal handler or code patch.",
        ],
        scope="Generated entry through matched return or first instruction of fpr_fuel_exhausted, including the linked save shim prefix. No elapsed-time or scheduler-dispatch bound.",
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("image", type=Path)
    ap.add_argument("--entry", required=True)
    ap.add_argument("--fuel", type=int, required=True)
    ap.add_argument("--max-instructions", type=int, required=True)
    ap.add_argument("--window-bytes", type=int, required=True)
    ap.add_argument("--writable-bytes", type=int, required=True)
    ap.add_argument(
        "--word",
        action="append",
        default=[],
        metavar="xN=VALUE",
        help="known unsigned ABI argument word at entry",
    )
    ap.add_argument("--verifier-steps", type=int, default=1_000_000)
    ap.add_argument("--record", type=Path)
    a = ap.parse_args()
    try:
        args = {}
        for item in a.word:
            key, sep, val = item.partition("=")
            require(
                key in {f"x{i}" for i in range(8)} and sep and int(key[1:]) not in args,
                "invalid/duplicate argument word",
            )
            args[int(key[1:])] = int(val, 0)
        if a.record:
            require(
                a.record.resolve() != a.image.resolve()
                and not (a.record.exists() and a.record.samefile(a.image)),
                "record would replace executable",
            )
        report = admit(
            Image(a.image.read_bytes()),
            a.entry,
            a.fuel,
            a.max_instructions,
            a.window_bytes,
            a.writable_bytes,
            args,
            a.verifier_steps,
        )
        if a.record:
            tmp = None
            try:
                with tempfile.NamedTemporaryFile(
                    mode="w", dir=a.record.parent, delete=False
                ) as f:
                    tmp = Path(f.name)
                    json.dump(report, f, indent=2)
                    f.write("\n")
                os.replace(tmp, a.record)
            finally:
                if tmp is not None:
                    tmp.unlink(missing_ok=True)
    except (ValueError, OSError, struct.error) as exc:
        ap.exit(1, f"ARM64 fuel admission refused: {exc}\n")
    print(
        f"admitted {report['required']}/{a.max_instructions} instructions; {', '.join(report['outcomes'])}"
    )


if __name__ == "__main__":
    main()
