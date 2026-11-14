# Benchmarks Game binary-trees, single-threaded (see ../SPEC.md).
# A tree is None (empty) or a (left, right) tuple.
import sys


def make(d):
    if d == 0:
        return (None, None)
    d -= 1
    return (make(d), make(d))


def check(t):
    if t is None:
        return 0
    left, right = t
    return 1 + check(left) + check(right)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 18
    min_depth = 4
    max_depth = max(min_depth + 2, n)
    stretch = max_depth + 1
    out = [f"stretch tree of depth {stretch}\t check: {check(make(stretch))}"]
    long_lived = make(max_depth)
    for d in range(min_depth, max_depth + 1, 2):
        iters = 2 ** (max_depth - d + min_depth)
        total = 0
        for _ in range(iters):
            total += check(make(d))
        out.append(f"{iters}\t trees of depth {d}\t check: {total}")
    out.append(f"long lived tree of depth {max_depth}\t check: {check(long_lived)}")
    sys.stdout.write("\n".join(out) + "\n")


main()
