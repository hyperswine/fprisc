#!/usr/bin/env python3
"""Stage 0 of docs/2026-10-23-COST-SIZED-REGIONS.md: measure before changing anything.

A. The per-frame model copy against the model's size.  A `Sys.loop` whose state
   is the logbook's Model with n sessions (examples/logbook.fpr), and one whose
   state is a store shard's `Map Int Entry` with n entries (std/store.fpr), each
   stepped K times changing one Int.  The plain build gives ns per turn (timed
   inside the program with Sys.mtime, so process start and exit are excluded);
   the FPR_COST_PROBE build gives bytes copied across the boundary per turn.
B. The real logbook driven by tests/std/logbook_ws.py (two tabs, 25 entries),
   with the probe ledger written at exit: turns, state bytes, allocation.
C. State size against turn allocation across turn-running programs of
   tests/base, tests/ and tests/bench: each built with FPR_COST_PROBE and run
   with FPR_COST_REPORT, giving per turn the bytes the turn allocated and the
   bytes its next state cost to copy out.

    python3 tools/regions-stage0.py --home <fprisc checkout with ./fpr> --out stage0.json

Nothing here updates a baseline; the page docs/2026-10-24-REGIONS-STAGE0.md
records the numbers."""
import argparse, json, os, re, resource, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
HEADER = 'Cost.begin : Unit -> Unit .\nCost.report : Unit -> String .\n'
MODEL_PROGRAM = HEADER + '''unsafe base.
M = use "std/map".
Ord = use "std/order".
Sess = {sid : Int, q : String, page : Int, editing : Int, toast : String}.
Model = {nextId : Int, rev : Int, sessions : List Sess}.
Entry = {id : Int, at : Int, text : String, tags : List String}.
mkSess : Int -> List Sess -> List Sess .
mkSess n acc = if n == 0 then acc else mkSess (n - 1) ({sid = n, q = "search {n}", page = n, editing = 0, toast = ""} :: acc).
mkEntries : Int -> M.Map Int Entry -> M.Map Int Entry .
mkEntries n acc = if n == 0 then acc else mkEntries (n - 1) (M.insert n {id = n, at = 1700000000 + n, text = "entry {n}: the quick brown fox jumps over the lazy dog", tags = "ops" :: "note" :: Nil} acc).
stepModel : Model -> (Bool, Model) .
stepModel m = (m.rev + 1 < K, {m | rev = m.rev + 1}).
stepStore : (Int, M.Map Int Entry) -> (Bool, (Int, M.Map Int Entry)) .
stepStore st = (ver, entries) = st; (ver + 1 < K, (ver + 1, entries)).
main =
  m0 = {nextId = 1, rev = 0, sessions = mkSess N Nil};
  _ = Cost.begin Unit;
  t0 = Sys.mtime Unit;
  m = Sys.loop m0 stepModel;
  t1 = Sys.mtime Unit;
  r1 = Cost.report Unit;
  e0 = (0, mkEntries N (M.empty Ord.int));
  _ = Cost.begin Unit;
  t2 = Sys.mtime Unit;
  e = Sys.loop e0 stepStore;
  t3 = Sys.mtime Unit;
  (ver, entries) = e;
  _ = print "model sessions={N} turns={m.rev} ticks={t1 - t0} {r1}";
  print "store entries={M.size entries} turns={ver} ticks={t3 - t2} {Cost.report Unit}".
'''
SIZES = [(0, 20000), (10, 20000), (100, 20000), (1000, 4000), (10000, 400)]
# C: programs that run turns, as their suites run them
PROGRAMS = [
    ('tests/base/receiveturns.fpr', {'FPR_HEAP_MB': '64'}, []),
    ('tests/base/receivecoverage.fpr', {'FPR_HEAP_MB': '64'}, []),
    ('tests/base/loopstate.fpr', {'FPR_HEAP_MB': '64'}, []),
    ('tests/base/loopwith.fpr', {}, []),
    ('tests/base/mvueventports.fpr', {'FPR_HEAP_MB': '64'}, []),
    ('tests/base/autodrop2.fpr', {}, []),
    ('tests/base/autodrop3.fpr', {}, ['--with', 'tests/arc_churn/arcprobe.c']),
    ('tests/base/deadmail.fpr', {}, []),
    ('tests/base/sendmem.fpr', {}, []),
    ('tests/msgpack.fpr', {}, []),
    ('tests/frames.fpr', {}, []),
    ('tests/fanin.fpr', {}, []),
    ('tests/bench/pingpong.fpr', {}, []),
    ('tests/bench/xpingpong.fpr', {'FPR_HARTS': '4'}, []),
]

def sh(args, env=None, cwd=None, timeout=600, stdin=None):
    return subprocess.run([str(a) for a in args], env=env, cwd=cwd, capture_output=True, text=True, timeout=timeout, input=stdin)

def ledger(text):
    m = re.search(r'\{"alloc_requests".*?\}', text)
    return json.loads(m.group(0)) if m else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--home', default=str(HERE), help='the fprisc checkout whose ./fpr, runtime and std are measured')
    ap.add_argument('--out', default='-')
    ap.add_argument('--runs', type=int, default=3)
    ap.add_argument('--skip', default='', help='comma list of parts to skip: A,B,C')
    a = ap.parse_args()
    home = Path(a.home).resolve()
    fpr = home / 'fpr'
    skip = set(a.skip.split(',')) if a.skip else set()
    base_env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    base_env['XDG_CACHE_HOME'] = str(Path(tempfile.mkdtemp(prefix='stage0-cache-')))
    out = {'home': str(home), 'host': os.uname().sysname + ' ' + os.uname().machine, 'date': time.strftime('%Y-%m-%d %H:%M'),
           'mtime_hz': None, 'A': [], 'B': None, 'C': []}
    tmp = Path(tempfile.mkdtemp(prefix='stage0-'))
    # Sys.mtime's rate: read it off the first program (ticks per second)
    def build(src, exe, probe, extra=()):
        env = dict(base_env, FPR_COST_PROBE='1') if probe else dict(base_env)
        p = sh([fpr, 'build', src, *extra, '-o', exe], env=env, cwd=home, timeout=900)
        if p.returncode != 0:
            return p.stdout + p.stderr
        return None
    if 'A' not in skip:
        for n, k in SIZES:
            src = tmp / f'model{n}.fpr'
            src.write_text(MODEL_PROGRAM.replace(' N ', f' {n} ').replace(' K,', f' {k},').replace('={N}', f'={n}'))
            row = {'n': n, 'k': k}
            for probe in (False, True):
                exe = tmp / f'model{n}{"-probe" if probe else ""}'
                err = build(src, exe, probe, ['--with', home / 'tests/bench/costprobe.c'])
                if err:
                    row['error'] = err[-2000:]; break
                best = None
                for _ in range(1 if probe else a.runs):
                    p = sh([exe], env=dict(base_env, FPR_HARTS='1'), timeout=900)
                    if p.returncode != 0:
                        row['error'] = (p.stdout + p.stderr)[-2000:]; break
                    lines = p.stdout.strip().splitlines()
                    parsed = {}
                    for line in lines:
                        kind = line.split()[0]
                        ticks = int(re.search(r'ticks=(\d+)', line).group(1))
                        turns = int(re.search(r'turns=(\d+)', line).group(1))
                        parsed[kind] = {'ticks': ticks, 'turns': turns, 'ledger': ledger(line)}
                    if best is None or sum(v['ticks'] for v in parsed.values()) < sum(v['ticks'] for v in best.values()):
                        best = parsed
                if best is None: break
                row['probe' if probe else 'plain'] = best
            out['A'].append(row)
            print(json.dumps(row)[:400], file=sys.stderr)
    if 'B' not in skip:
        report = tmp / 'logbook-ledger.txt'
        store = tmp / 'log.kvlog'
        env = dict(base_env, FPR_COST_PROBE='1', FPR_COST_REPORT=str(report))
        t0 = time.time()
        p = sh([sys.executable, home / 'tests/std/logbook_ws.py', fpr, home / 'examples/logbook.fpr', store], env=env, cwd=home, timeout=1200)
        lines = report.read_text().splitlines() if report.exists() else []
        out['B'] = {'ok': p.returncode == 0 and p.stdout.strip().endswith('ok'), 'seconds': round(time.time() - t0, 1),
                    'ledgers': [ledger(l) for l in lines], 'tail': (p.stdout + p.stderr)[-1500:]}
        print(json.dumps(out['B'])[:600], file=sys.stderr)
    if 'C' not in skip:
        for src, env_extra, extra in PROGRAMS:
            exe = tmp / (Path(src).stem + '-probe')
            row = {'program': src, 'env': env_extra}
            err = build(home / src, exe, True, [home / e if e.endswith('.c') else e for e in extra])
            if err:
                row['error'] = err[-1500:]
            else:
                env = dict(base_env, FPR_COST_REPORT='1', **env_extra)
                t0 = time.time()
                try:
                    p = sh([exe], env=env, cwd=home, timeout=600)
                    row.update(exit=p.returncode, seconds=round(time.time() - t0, 2), ledger=ledger(p.stderr),
                               stdout=p.stdout.strip()[-400:])
                except subprocess.TimeoutExpired:
                    row['error'] = 'timeout'
            out['C'].append(row)
            print(json.dumps(row)[:400], file=sys.stderr)
    text = json.dumps(out, indent=1)
    if a.out == '-': print(text)
    else: Path(a.out).write_text(text); print('wrote', a.out, file=sys.stderr)

if __name__ == '__main__':
    main()
