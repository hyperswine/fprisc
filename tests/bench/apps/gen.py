#!/usr/bin/env python3
"""gen.py [DATADIR] -- write the application workloads' inputs (SPEC.md).

Deterministic: the same files on every machine. data/ is not checked in."""
import os, sys

def lcg(x):
    return (x * 1103515245 + 12345) % 2147483648

def sales(path, n=1000000):
    x, out = 3, []
    for _ in range(n):
        x = lcg(x); k = x % 1000
        x = lcg(x); a = x % 1000
        x = lcg(x); b = x % 100000
        out.append(f'k{k:04d},{a},{b}\n')
    open(path, 'w').write(''.join(out))

def corpus(path, n=2000000, distinct=50000):
    # 50,000 distinct words: base-26 spellings of a scrambled index, 3-9 letters
    words = []
    for i in range(distinct):
        v, w = (i * 2654435761) % 4294967296, ''
        for _ in range(3 + i % 7):
            w += chr(97 + v % 26); v //= 26
        words.append(w + chr(97 + i % 26) + chr(97 + (i // 26) % 26) + chr(97 + (i // 676) % 26))
    assert len(set(words)) == distinct
    # Zipf-like: rank r drawn with weight ~ 1/r, via an inverse table
    x, out = 11, []
    cdf, s = [], 0.0
    for r in range(1, distinct + 1):
        s += 1.0 / r; cdf.append(s)
    import bisect
    for i in range(n):
        x = lcg(x)
        r = bisect.bisect_left(cdf, (x / 2147483648) * s)
        out.append(words[min(r, distinct - 1)])
        out.append('\n' if i % 12 == 11 else ' ')
    # every distinct word appears at least once: replace a strided set of draws
    toks = ''.join(out).split()
    for i in range(distinct):
        toks[i * (n // distinct)] = words[i]
    lines = [' '.join(toks[j:j + 12]) for j in range(0, n, 12)]
    open(path, 'w').write('\n'.join(lines) + '\n')

if __name__ == '__main__':
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')
    os.makedirs(d, exist_ok=True)
    sales(os.path.join(d, 'sales.csv'))
    corpus(os.path.join(d, 'corpus.txt'))
    print('wrote', d)
