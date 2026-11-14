# Benchmarks Game spectral-norm, single-threaded (see ../SPEC.md).
# Sums use explicit loops: sum() of floats is compensated since Python 3.12,
# which would not match the plain left-to-right sums of the other languages.
import sys
from math import sqrt


def a(i, j):
    ij = i + j
    return 1.0 / (ij * (ij + 1) // 2 + i + 1)


def av(n, v):
    out = []
    for i in range(n):
        s = 0.0
        for j in range(n):
            s += a(i, j) * v[j]
        out.append(s)
    return out


def atv(n, v):
    out = []
    for i in range(n):
        s = 0.0
        for j in range(n):
            s += a(j, i) * v[j]
        out.append(s)
    return out


def atav(n, v):
    return atv(n, av(n, v))


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    u = [1.0] * n
    v = u
    for _ in range(10):
        v = atav(n, u)
        u = atav(n, v)
    vbv = 0.0
    vv = 0.0
    for ue, ve in zip(u, v):
        vbv += ue * ve
        vv += ve * ve
    sys.stdout.write("%.9f\n" % sqrt(vbv / vv))


main()
