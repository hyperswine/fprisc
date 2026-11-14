# Benchmarks Game reverse-complement, single-threaded (see ../SPEC.md).
import sys

LINE = 60
PAIRS = "AT CG GC TA UA MK RY WW SS YR KM VB HD DH BV NN".split()
COMP = bytes.maketrans(
    "".join(p[0] for p in PAIRS).encode() + "".join(p[0] for p in PAIRS).lower().encode(),
    "".join(p[1] for p in PAIRS).encode() * 2)


def write_sequence(out, header, lines):
    seq = b"".join(lines).translate(COMP)[::-1]
    out.write(header + b"\n")
    if seq:
        out.write(b"\n".join(seq[i:i + LINE] for i in range(0, len(seq), LINE)) + b"\n")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/fasta-2500000.txt"
    with open(path, "rb") as f:
        data = f.read()
    out = sys.stdout.buffer
    header = None
    lines = []
    for line in data.split(b"\n"):
        if line.startswith(b">"):
            if header is not None:
                write_sequence(out, header, lines)
            header = line
            lines = []
        else:
            lines.append(line)
    if header is not None:
        write_sequence(out, header, lines)
    out.flush()


main()
