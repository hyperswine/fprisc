# Benchmarks Game k-nucleotide, single-threaded (see ../SPEC.md).
import sys
from collections import Counter


def read_three(path):
    with open(path, "rb") as f:
        lines = f.read().split(b"\n")
    i = 0
    while i < len(lines) and not lines[i].startswith(b">THREE"):
        i += 1
    parts = []
    for line in lines[i + 1:]:
        if line.startswith(b">"):
            break
        parts.append(line)
    return b"".join(parts).upper().decode("ascii")


def count(seq, k):
    return Counter(seq[i:i + k] for i in range(len(seq) - k + 1))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/fasta-1000000.txt"
    seq = read_three(path)
    out = []
    for k in (1, 2):
        table = count(seq, k)
        total = len(seq) - k + 1
        for kmer, c in sorted(table.items(), key=lambda kv: (-kv[1], kv[0])):
            out.append("%s %.3f" % (kmer, 100 * c / total))
        out.append("")
    for kmer in ("GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"):
        table = count(seq, len(kmer))
        out.append("%d\t%s" % (table.get(kmer, 0), kmer))
    sys.stdout.write("\n".join(out) + "\n")


main()
