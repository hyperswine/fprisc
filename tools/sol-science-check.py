#!/usr/bin/env python3
"""The Sol science vertical: CSV -> linear Matrix -> robust fit -> SVG chart.

sol/examples/csvplot.sol is the measured end-to-end workflow this suite
pins: a generated sensor CSV round-trips through the transactional
filesystem into the linear Matrix, gets a least-squares fit with an
iterated 3-sigma outlier rule, and lands as one mixed-series SVG
(sol/lib/plot.sol P.chart). The RNG and the arithmetic are replicated
here, so the printed statistics are asserted EXACTLY; the SVG structure
(series count, marker count, legend) is asserted structurally.
"""
import math
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()
ENV = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')} | {'SOL_GPU': '0'}

OUT = Path('/tmp/sol-csvplot')


def lcg_rows(seed, n):
    """sol/lib/rand.sol's LCG and sol/examples/csvplot.sol's mkRow."""
    s = seed
    rows = []
    for x in range(n):
        s = (s * 1103515245 + 12345) % 2**31
        k = (s // 65536) % 11
        y = 12 + 3 * x + k - 5 + (150 if x % 13 == 12 else 0)
        rows.append((x, y))
    return rows


def fold(f, z, xs):
    """Naive left fold — Sol's List.fold, NOT Python's compensated sum()."""
    acc = z
    for x in xs:
        acc = f(acc, x)
    return acc


def fit(pts):
    n = len(pts)
    sx = fold(lambda a, p: a + p[0], 0, pts); sy = fold(lambda a, p: a + p[1], 0, pts)
    sxx = fold(lambda a, p: a + p[0] * p[0], 0, pts); sxy = fold(lambda a, p: a + p[0] * p[1], 0, pts)
    xm = sx / n; ym = sy / n
    b = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    return n, xm, ym, ym - b * xm, b


def sigma(a, b, pts):
    rs = [y - (a + b * x) for x, y in pts]
    ss = fold(lambda acc, r: acc + r * r, 0, rs)
    return math.sqrt(ss / len(rs))  # math.sqrt == C sqrt, as Num.sqrt is


def main():
    # ---- exact expected statistics, replicated independently ---------------
    rows = lcg_rows(20261108, 40)
    _, _, _, a_all, b_all = fit(rows)
    sig_all = sigma(a_all, b_all, rows)
    clean = [(x, y) for (x, y), r in zip(rows, [(y - (a_all + b_all * x)) for x, y in rows])
             if abs(y - (a_all + b_all * x)) <= 3 * sig_all]
    _, _, _, a_fit, b_fit = fit(clean)
    sig_fit = sigma(a_fit, b_fit, clean)
    bad_weeks = [x for (x, y), r in zip(rows, [(y - (a_all + b_all * x)) for x, y in rows])
                 if abs(y - (a_all + b_all * x)) > 3 * sig_all]
    assert len(clean) == 37 and bad_weeks == [12, 25, 38], (len(clean), bad_weeks)

    # ---- run the vertical ---------------------------------------------------
    import shutil
    shutil.rmtree(OUT, ignore_errors=True)
    t0 = time.monotonic()
    r = subprocess.run([str(FPR), 'sol', str(ROOT / 'sol' / 'examples' / 'csvplot.sol')],
                       capture_output=True, env=ENV, cwd=str(ROOT), timeout=120)
    elapsed = (time.monotonic() - t0) * 1000
    assert r.returncode == 0, (r.returncode, r.stdout, r.stderr[-400:])
    lines = r.stdout.decode().splitlines()
    assert len(lines) == 5, lines

    want = [
        re.compile(r'^readings: header \[week, reading\], n = 40, mean\(x\) = 19\.5, '
                   rf'mean\(y\) = {re.escape(repr(81.975))}$'),
        re.compile(rf'^all-data fit: y = {re.escape(repr(a_all))} \+ {re.escape(repr(b_all))} x '
                   rf'\(sigma {re.escape(repr(sig_all))}\)$'),
        re.compile(rf'^clean fit: y = {re.escape(repr(a_fit))} \+ {re.escape(repr(b_fit))} x '
                   rf'\(sigma {re.escape(repr(sig_fit))}\)$'),
        re.compile(r'^rejected 3 outlier\(s\) at weeks \[12, 25, 38\]$'),
        re.compile(r'^wrote /tmp/sol-csvplot/sensor\.svg$'),
    ]
    for pattern, (i, got) in zip(want, list(enumerate(lines))):
        assert pattern.match(got), (i, got, pattern.pattern)

    # ---- the transactional outputs -----------------------------------------
    csv_lines = (OUT / 'readings.csv').read_text().splitlines()
    assert csv_lines[0] == 'week,reading' and len(csv_lines) == 41, csv_lines[:3]
    assert csv_lines[1] == f'0,{rows[0][1]}'
    assert csv_lines[13] == f'12,{rows[12][1]}'  # an injected outlier week
    assert csv_lines[2] == f'1,{rows[1][1]}'

    svg = (OUT / 'sensor.svg').read_text()
    assert svg.count('<polyline') == 2, svg.count('<polyline')  # the two fit lines
    assert svg.count('<circle') == 40, svg.count('<circle')     # 37 clean + 3 rejected
    for title in ('readings', 'fit (all data)', 'rejected', 'fit (clean)'):
        assert title in svg, title
    print(f'science vertical: exact statistics, CSV round-trip, mixed-series SVG '
          f'({len(svg)} bytes) — {elapsed:.0f} ms end to end')
    print('sol science vertical: OK')


if __name__ == '__main__':
    main()
