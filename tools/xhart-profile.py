#!/usr/bin/env python3
"""Cross-hart message profile (docs/2026-10-01-XHART.md).

Three workloads, each built twice: an ordinary build for timing and an
FPR_COST_PROBE build for the breakdown (mailbox scan, copy, ARC promotion,
ring push, ship, doorbell, ship->drain->run latency, parking):

  rt       Int round trips between an actor on hart 0 and one on hart H
           (H = 0 for the same-hart reference), with a latency histogram
  stream   one-way Ints into a growable mailbox on hart H: throughput
  fanin    three senders flooding one receiver on hart 0 for a fixed
           window: per-sender counts and Jain's fairness index -- on four
           harts (one sender each), and contended on two (the receiver
           shares hart 0 with a sender)

plus the C floors (tests/bench/xhart/floor.c): a spin hand-off through one
cache line, and a condition-variable hand-off (an OS wake per hop).

Writes JSON to stdout.  Timing figures are the fastest of --runs."""
import argparse, json, os, statistics, subprocess, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
HDR = '''XH.now : Unit -> Int .
XH.lat : Int -> Unit .
XH.begin : Unit -> Unit .
XH.report : Unit -> String .
'''
def prog_rt(n, h):
    return HDR + f'''worker : unsafe Int -> Int -> Unit .
worker boss self = m = receive self; _ = send boss m; worker boss self.
loop : unsafe Int -> Int -> Int -> Int -> Int .
loop me w n acc = if n == 0 then acc else
  t = XH.now Unit;
  _ = send w n;
  m = receiveFrom me w;
  _ = XH.lat (XH.now Unit - t);
  loop me w (n - 1) (acc + m).
main = me = myself 0; w = spawnOn {h} (worker me); _ = XH.begin Unit; s = loop me w {n} 0;
  r = XH.report Unit; _ = kill w; _ = print "check: {{s}}"; print r.
'''
def prog_stream(n, h):
    return HDR + f'''sink : unsafe Int -> Int -> Int -> Int -> Unit .
sink boss n acc self = if n == 0 then send boss acc >> Unit else
  m = receive self;
  sink boss (n - 1) (acc + m) self.
pump : unsafe Int -> Int -> Unit .
pump w n = if n == 0 then Unit else send w n >> pump w (n - 1).
main = me = myself 0; w = spawnCapOn {h} 1 1024 (sink me {n} 0); _ = XH.begin Unit;
  t0 = XH.now Unit; _ = pump w {n}; s = receiveFrom me w; dt = XH.now Unit - t0;
  r = XH.report Unit; _ = print "check: {{s}}"; _ = print "ns: {{dt}}"; print r.
'''
def prog_fanin(ms, harts):
    return HDR + f'''flood : unsafe Int -> Int -> Int -> Unit .
flood boss id self = case receiveNow self of
    Ok m -> Unit
  | Err e -> (case send boss id of Ok u -> flood boss id self | Err f -> yield self >> flood boss id self).
collect : unsafe Int -> Int -> Int -> Int -> Int -> (Int, Int, Int) .
collect me deadline a b c = if XH.now Unit > deadline then (a, b, c) else
  m = receive me;
  if m == 1 then collect me deadline (a + 1) b c else if m == 2 then collect me deadline a (b + 1) c else collect me deadline a b (c + 1).
main = me = myself 0;
  s1 = spawnOn {1 % harts} (flood me 1); s2 = spawnOn {2 % harts} (flood me 2); s3 = spawnOn {3 % harts} (flood me 3);
  _ = XH.begin Unit;
  r = collect me (XH.now Unit + {ms * 1000000}) 0 0 0;
  rep = XH.report Unit;
  _ = kill s1; _ = kill s2; _ = kill s3;
  (a, b, c) = r;
  _ = print "check: {{a}} {{b}} {{c}}"; print rep.
'''
def run(args, env, timeout=300):
    p = subprocess.run([str(x) for x in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, f'{args}: {p.returncode}\n{p.stdout}{p.stderr}'
    return p.stdout

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--runs', type=int, default=5)
    ap.add_argument('--n', type=int, default=200000)
    ap.add_argument('--window-ms', type=int, default=500)
    ap.add_argument('--quick', action='store_true')
    a = ap.parse_args()
    n = 2000 if a.quick else a.n
    base = {**os.environ, 'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT)}
    base.pop('FPR_FOREIGN', None)
    run(['make', 'fpr'], base)
    out = {'n': n, 'results': []}
    with tempfile.TemporaryDirectory(prefix='fpr-xhart-') as d:
        tmp = Path(d)
        floor = tmp / 'floor'
        run(['cc', '-O2', ROOT / 'tests/bench/xhart/floor.c', '-lpthread', '-o', floor], base)
        out['floor'] = json.loads(run([floor, str(n)], base).strip())
        cases = [('rt', 0, prog_rt(n, 0), 1), ('rt', 1, prog_rt(n, 1), 2),
                 ('stream', 0, prog_stream(n, 0), 1), ('stream', 1, prog_stream(n, 1), 2),
                 ('fanin', 0, prog_fanin(a.window_ms, 4), 4),
                 # contended: two harts, the receiver shares hart 0 with sender 2
                 ('fanin', 0, prog_fanin(a.window_ms, 2), 2)]
        for kind, h, src, harts in cases:
            f = tmp / f'{kind}{h}.fpr'; f.write_text(src)
            rec = {'kind': kind, 'target_hart': h, 'harts': harts}
            for probe in (False, True):
                exe = tmp / f'{kind}{h}-{int(probe)}'
                env = {**base, 'FPR_HARTS': str(harts), 'FPR_COST_PROBE': '1' if probe else '0'}
                run(['./fpr', 'build', f, '--harts', '4', '--with', ROOT / 'tests/bench/xhart/probe.c', '-o', exe], env)
                walls, last = [], None
                for _ in range(a.runs if not probe else 1):
                    t0 = time.perf_counter(); o = run([exe], env); walls.append(time.perf_counter() - t0); last = o
                lines = last.splitlines()
                led = json.loads(lines[-1])
                if probe:
                    rec['probe'] = led
                else:
                    rec['best_wall_ms'] = round(min(walls) * 1000, 3)
                    rec['median_wall_ms'] = round(statistics.median(walls) * 1000, 3)
                    rec['latency'] = {k: led[k] for k in ('lat_n', 'lat_p50_ns', 'lat_p99_ns', 'lat_p999_ns')}
                    if kind == 'stream':
                        ns = int([l for l in lines if l.startswith('ns: ')][0][4:])
                        rec['msgs_per_s'] = round(n / (ns / 1e9))
                    if kind == 'fanin':
                        counts = [int(x) for x in lines[0].split()[1:]]
                        tot = sum(counts)
                        rec['counts'] = counts
                        rec['msgs_per_s'] = round(tot / (a.window_ms / 1000))
                        rec['jain'] = round(tot * tot / (len(counts) * sum(c * c for c in counts)), 4) if tot else 0
                        rec['min_over_max'] = round(min(counts) / max(counts), 4) if max(counts) else 0
            out['results'].append(rec)
    print(json.dumps(out, indent=1))

main()
