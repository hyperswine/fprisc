# Benchmarks Game fasta, single-threaded (see ../SPEC.md).
import sys
from bisect import bisect_right

ALU = ("GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGG"
       "AGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTG"
       "GCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGC"
       "AGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA")

IUB = [("a", 0.27), ("c", 0.12), ("g", 0.12), ("t", 0.27),
       ("B", 0.02), ("D", 0.02), ("H", 0.02), ("K", 0.02), ("M", 0.02), ("N", 0.02),
       ("R", 0.02), ("S", 0.02), ("V", 0.02), ("W", 0.02), ("Y", 0.02)]
HOMOSAPIENS = [("a", 0.3029549426680), ("c", 0.1979883004921),
               ("g", 0.1975473066391), ("t", 0.3015094502008)]

LINE = 60
IM = 139968
IA = 3877
IC = 29573


class Random:
    def __init__(self):
        self.seed = 42


def repeat_fasta(out, header, src, count):
    out.write(header.encode() + b"\n")
    s = src.encode()
    length = len(s)
    doubled = s * (LINE // length + 2)
    k = 0
    lines = []
    while count > 0:
        line = min(LINE, count)
        lines.append(doubled[k:k + line])
        k = (k + line) % length
        count -= line
        if len(lines) >= 4096:
            out.write(b"\n".join(lines) + b"\n")
            lines = []
    if lines:
        out.write(b"\n".join(lines) + b"\n")


def random_fasta(out, header, table, count, rng):
    out.write(header.encode() + b"\n")
    chars = bytes(ord(c) for c, _ in table)
    cum = []
    acc = 0.0
    for _, p in table:
        acc += p
        cum.append(acc)
    last = len(table) - 1
    seed = rng.seed
    lines = []
    while count > 0:
        line = min(LINE, count)
        buf = bytearray(line)
        for i in range(line):
            seed = (seed * IA + IC) % IM
            j = bisect_right(cum, seed / IM)
            buf[i] = chars[j if j <= last else last]
        lines.append(bytes(buf))
        count -= line
        if len(lines) >= 4096:
            out.write(b"\n".join(lines) + b"\n")
            lines = []
    if lines:
        out.write(b"\n".join(lines) + b"\n")
    rng.seed = seed


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2500000
    out = sys.stdout.buffer
    rng = Random()
    repeat_fasta(out, ">ONE Homo sapiens alu", ALU, 2 * n)
    random_fasta(out, ">TWO IUB ambiguity codes", IUB, 3 * n, rng)
    random_fasta(out, ">THREE Homo sapiens frequency", HOMOSAPIENS, 5 * n, rng)
    out.flush()


main()
