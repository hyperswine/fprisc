#!/usr/bin/env python3
"""run.py -- the application workloads against C and peers (SPEC.md).

  python3 gen.py                       inputs into data/ (once)
  sh build_peers.sh                    bin/<w>.{c,rust,go,ocaml,java}
  python3 run.py --build               bin-fpr/<w>.fpr (and variants) with $FPR or `fpr`
  python3 run.py [--runs 5] [--out results/X.json] [w ...]
  python3 run.py --ceilings            the FP-RISC binaries once each: output, and
                                       peak RSS at most ceilings.json (exit 1 above)

One warm-up round, then --runs rounds in shuffled interleaved order. Every run's
stdout must equal expected/<w>.out (a wrong answer is a failure, not a time).
Wall time is the median; peak RSS is the median maximum resident set size
(the child's rusage from wait4). Peers are informational, as in the
reference audit: C is unchecked. The ceilings gate only FP-RISC (decision 6,
docs/2026-11-11-COPY-OUT-DECISIONS.md)."""
import argparse, json, os, platform, random, re, shutil, statistics, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
BIN, FBIN, DATA, EXP = HERE / 'bin', HERE / 'bin-fpr', HERE / 'data', HERE / 'expected'
WORKLOADS = ['csv', 'wordfreq', 'format', 'records', 'treemap', 'sim']
PEERS = ['c', 'rust', 'go', 'ocaml', 'java']
# FP-RISC variants beyond the plain program: label -> source
VARIANTS = {'wordfreq': {'fpr-mutmap': 'wordfreq_mutmap.fpr'}, 'treemap': {'fpr-mutmap': 'treemap_mutmap.fpr'}}
ARGS = {'csv': [str(DATA / 'sales.csv')], 'wordfreq': [str(DATA / 'corpus.txt')]}

def build(fpr, ws, env_extra):
    FBIN.mkdir(exist_ok=True)
    env = dict(os.environ, **env_extra)
    for w in ws:
        srcs = {'fpr': f'{w}.fpr', **VARIANTS.get(w, {})}
        for label, src in srcs.items():
            out = FBIN / f'{w}.{label}'
            t0 = time.time()
            p = subprocess.run([fpr, 'build', '-o', str(out), str(HERE / src)], cwd=HERE, env=env,
                               capture_output=True, text=True)
            if p.returncode != 0:
                sys.exit(f'build {src} failed:\n{p.stdout}\n{p.stderr}')
            print(f'built {out.name} in {time.time() - t0:.1f} s', flush=True)

def timed(cmd):
    """exit code, stdout, wall seconds, peak RSS in MB of this one child"""
    with tempfile.TemporaryFile() as out:
        t0 = time.perf_counter()
        p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.DEVNULL)
        _, status, usage = os.wait4(p.pid, 0)
        dt = time.perf_counter() - t0
        p.returncode = os.waitstatus_to_exitcode(status)
        out.seek(0)
        stdout = out.read()
    # ru_maxrss is bytes on macOS, KiB on Linux
    rss = usage.ru_maxrss / (2**20 if platform.system() == 'Darwin' else 1024)
    return p.returncode, stdout, dt, rss

def ceilings(ws):
    limits = json.load(open(HERE / 'ceilings.json'))['ceilings_mb']
    failed = 0
    for w in ws:
        for label in ['fpr', *VARIANTS.get(w, {})]:
            exe = FBIN / f'{w}.{label}'
            key = w if label == 'fpr' else f'{w}.{label}'
            if key not in limits:
                continue
            if not exe.exists():
                sys.exit(f'{exe.name}: not built (run.py --build)')
            rc, out, dt, rss = timed([str(exe)] + ARGS.get(w, []))
            ok = rc == 0 and out == (EXP / f'{w}.out').read_bytes() and rss <= limits[key]
            failed += not ok
            print(f'{key:22s} {rss:7.0f} MB (ceiling {limits[key]}) {dt:6.2f} s  {"PASS" if ok else "FAIL" if rc == 0 and out == (EXP / f"{w}.out").read_bytes() else "WRONG OUTPUT"}')
    if failed:
        sys.exit(f'app ceilings: {failed} over their ceiling or wrong')
    print('app ceilings: every FP-RISC workload within its peak-RSS ceiling PASS')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('workloads', nargs='*')
    ap.add_argument('--runs', type=int, default=5)
    ap.add_argument('--build', action='store_true')
    ap.add_argument('--out')
    ap.add_argument('--env', action='append', default=[], help='NAME=VALUE for fpr build')
    ap.add_argument('--ceilings', action='store_true', help='gate peak RSS against ceilings.json')
    a = ap.parse_args()
    ws = a.workloads or WORKLOADS
    if a.ceilings:
        ceilings(ws)
        return
    if a.build:
        build(os.environ.get('FPR', 'fpr'), ws, dict(e.split('=', 1) for e in a.env))
        return
    jobs = {}
    for w in ws:
        for exe in sorted([*BIN.glob(f'{w}.*'), *FBIN.glob(f'{w}.*')]):
            lang = exe.name[len(w) + 1:]
            if exe.is_file() and os.access(exe, os.X_OK):
                jobs[(w, lang)] = [str(exe)] + ARGS.get(w, [])
    expected = {w: (EXP / f'{w}.out').read_bytes() for w in ws}
    res = {k: [] for k in jobs}
    keys = list(jobs)
    def one(k):
        rc, out, dt, rss = timed(jobs[k])
        if rc != 0 or out != expected[k[0]]:
            sys.exit(f'{k[0]}.{k[1]}: exit {rc}, output {"matches" if out == expected[k[0]] else "DIFFERS"}')
        return dt, rss
    for k in keys: one(k)
    for r in range(a.runs):
        random.shuffle(keys)
        for k in keys: res[k].append(one(k))
        print(f'round {r + 1}/{a.runs}', flush=True)
    rows = {}
    for (w, lang), v in res.items():
        rows.setdefault(w, {})[lang] = {'wall_med': statistics.median(x[0] for x in v), 'wall_min': min(x[0] for x in v),
                                        'rss_mb_med': statistics.median(x[1] for x in v), 'raw': v}
    meta = {'host': f'{platform.system()}-{platform.machine()}-{platform.node().split(".")[0]}',
            'date': time.strftime('%Y-%m-%d %H:%M %Z'), 'runs': a.runs,
            'fpr_rev': subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=HERE, capture_output=True, text=True).stdout.strip()}
    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        json.dump({'meta': meta, 'rows': rows}, open(a.out, 'w'), indent=1)
    report(rows)

def report(rows):
    langs = ['fpr'] + sorted({l for r in rows.values() for l in r if l.startswith('fpr-')}) + PEERS
    print('\n| workload | ' + ' | '.join(langs) + ' | fpr/C | fpr/peer median |')
    print('|---|' + '---:|' * (len(langs) + 2))
    gc, gp = [], []
    for w, r in rows.items():
        cells = [f"{r[l]['wall_med']:.3f} s / {r[l]['rss_mb_med']:.0f} MB" if l in r else '-' for l in langs]
        f = r.get('fpr', {}).get('wall_med')
        peers = [r[l]['wall_med'] for l in PEERS if l in r]
        rc = f / r['c']['wall_med'] if f and 'c' in r else None
        rp = f / statistics.median(peers) if f and peers else None
        if rc: gc.append(rc)
        if rp: gp.append(rp)
        print(f'| {w} | ' + ' | '.join(cells) + f" | {rc:.1f}x | {rp:.1f}x |" if rc and rp else f'| {w} | ' + ' | '.join(cells) + ' | - | - |')
    g = lambda xs: statistics.geometric_mean(xs) if xs else float('nan')
    print(f'\ngeomean: fpr/C {g(gc):.1f}x, fpr/peer median {g(gp):.1f}x')

if __name__ == '__main__':
    main()
