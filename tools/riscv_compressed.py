"""RV64 integer C instructions normalized to their base encoding.

The caller retains the original two-byte length (especially for C.JALR's
return PC). Floating-point, reserved, breakpoint and newer Zc encodings refuse.
Reference: RISC-V unprivileged ISA, C 2.0, RV64 instruction listings.
"""


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def i(op, rd, f3, rs1, imm):
    return ((imm & 4095) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def r(op, rd, f3, rs1, rs2, f7=0):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def store(f3, rs1, rs2, imm):
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 31) << 7) | 0x23


def branch(f3, rs1, imm):
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 63) << 25) | (rs1 << 15) | (f3 << 12) | (((imm >> 1) & 15) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def jump(imm):
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 1023) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 255) << 12) | 0x6f


def expand(h):
    if type(h) is not int or not 0 <= h <= 65535 or h & 3 == 3:
        raise ValueError('not a compressed instruction')
    q, f = h & 3, h >> 13
    rd, rs2 = (h >> 7) & 31, (h >> 2) & 31
    a, b = 8 + ((h >> 7) & 7), 8 + ((h >> 2) & 7)
    imm6 = ((h >> 12) & 1) << 5 | ((h >> 2) & 31)
    if q == 0:
        if f == 0:  # ADDI4SPN
            imm = ((h >> 7) & 15) << 6 | ((h >> 11) & 3) << 4 | ((h >> 5) & 1) << 3 | ((h >> 6) & 1) << 2
            if imm:
                return i(0x13, b, 0, 2, imm)
        elif f in (2, 3, 6, 7):  # LW/LD/SW/SD
            wide = f & 1
            imm = ((h >> 10) & 7) << 3
            imm |= ((h >> 5) & 3) << 6 if wide else (((h >> 5) & 1) << 6 | ((h >> 6) & 1) << 2)
            return i(3, b, 3 if wide else 2, a, imm) if f < 4 else store(3 if wide else 2, a, b, imm)
    elif q == 1:
        if f in (0, 1, 2):  # ADDI/NOP, ADDIW, LI
            if f != 1 or rd:
                return i(0x1b if f == 1 else 0x13, rd, 0, 0 if f == 2 else rd, signed(imm6, 6))
        elif f == 3:
            if rd == 2:  # ADDI16SP
                imm = ((h >> 12) & 1) << 9 | ((h >> 3) & 3) << 7 | ((h >> 5) & 1) << 6 | ((h >> 2) & 1) << 5 | ((h >> 6) & 1) << 4
                if imm:
                    return i(0x13, 2, 0, 2, signed(imm, 10))
            elif imm6:  # LUI, including architectural HINTs to x0
                return ((signed(imm6, 6) << 12) & 0xfffff000) | (rd << 7) | 0x37
        elif f == 4:
            sub = (h >> 10) & 3
            if sub < 2:  # SRLI/SRAI
                return i(0x13, a, 5, a, imm6 | (0x400 if sub else 0))
            if sub == 2:  # ANDI
                return i(0x13, a, 7, a, signed(imm6, 6))
            kind = (h >> 5) & 3
            if not (h & 0x1000):  # SUB/XOR/OR/AND
                return r(0x33, a, (0, 4, 6, 7)[kind], a, b, 0x20 if kind == 0 else 0)
            if kind < 2:  # SUBW/ADDW (RV64, not the RV32 reserved encodings)
                return r(0x3b, a, 0, a, b, 0x20 if kind == 0 else 0)
        elif f == 5:  # J
            imm = ((h >> 12) & 1) << 11 | ((h >> 8) & 1) << 10 | ((h >> 9) & 3) << 8 | ((h >> 6) & 1) << 7 | ((h >> 7) & 1) << 6 | ((h >> 2) & 1) << 5 | ((h >> 11) & 1) << 4 | ((h >> 3) & 7) << 1
            return jump(signed(imm, 12))
        elif f in (6, 7):  # BEQZ/BNEZ
            imm = ((h >> 12) & 1) << 8 | ((h >> 5) & 3) << 6 | ((h >> 2) & 1) << 5 | ((h >> 10) & 3) << 3 | ((h >> 3) & 3) << 1
            return branch(f - 6, a, signed(imm, 9))
    elif q == 2:
        if f == 0:  # SLLI (zero shift/destination are HINTs)
            return i(0x13, rd, 1, rd, imm6)
        if f in (2, 3) and rd:  # LWSP/LDSP; rd=x0 is reserved
            imm = ((h >> 12) & 1) << 5
            imm |= (((h >> 2) & 7) << 6 | ((h >> 5) & 3) << 3) if f == 3 else (((h >> 2) & 3) << 6 | ((h >> 4) & 7) << 2)
            return i(3, rd, f, 2, imm)
        if f == 4:
            high = bool(h & 0x1000)
            if rs2:
                return r(0x33, rd, 0, rd if high else 0, rs2)  # ADD/MV
            if rd:  # JALR/JR; rd=0 is reserved or EBREAK
                return i(0x67, 1 if high else 0, 0, rd, 0)
        if f in (6, 7):  # SWSP/SDSP
            imm = (((h >> 7) & 7) << 6 | ((h >> 10) & 7) << 3) if f == 7 else (((h >> 7) & 3) << 6 | ((h >> 9) & 15) << 2)
            return store(3 if f == 7 else 2, 2, rs2, imm)
    raise ValueError(f'unsupported/reserved compressed instruction {h:#06x}')
