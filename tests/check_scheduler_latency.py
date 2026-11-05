#!/usr/bin/env python3
"""Qualify competing-actor progress and sample native request/reply latency.

Probe runs prove each competitor exhausts fuel during the measurement window.
Separate ordinary-runtime runs measure latency. Neither sampled maxima nor
per-function instruction reports are a worst-case elapsed-time certificate.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HAL = ROOT / 'tests/base/scheduler_probe.c'
WORK = {
    'scalar': ('work n x = if n <= 0 then x else work (n - 1) (x + 1).\n', 'work 10000 x', 10000),
    'wrapper': ('Cell = Type (Cell Int).\n'
                'work n c = case c of Cell x -> if n <= 0 then x else work (n - 1) (Cell (x + 1)).\n',
                'work 10000 (Cell x)', 10000),
    'product': ('work n c = case c of (a,b,c,d) -> if n <= 0 then a + b + c + d '
                'else work (n - 1) (a + 1,b + 1,c + 1,d + 1).\n',
                'work 10000 (x,0,0,0)', 40000),
    'list': ('List = use "std/list".\n', 'x + List.sum (List.range 1 10000)', 50005000),
}
# A nonrecursive helper above the normal inlining budget exercises the new
# checked parameter worker under the same actor contention/fuel probes.
WORK['helper'] = (
    'Cell = Type (Cell Int).\nbumpCell c = case c of Cell x -> ' +
    '; '.join(f'y{i} = ' + ('x' if i == 0 else f'y{i-1}') + ' + 1' for i in range(32)) +
    '; y31.\nwork n x = if n <= 0 then x else work (n - 1) (bumpCell (Cell x)).\n',
    'work 10000 x', 320000)

WORK['helper-tree'] = (
    'Cell = Type (Cell Int).\nNest = Type (Nest Cell).\n'
    'bumpTree a b = case a of Nest innerA -> case innerA of Cell x -> '
    'case b of Nest innerB -> case innerB of Cell y -> ' +
    '; '.join(f'y{i} = ' + ('x + y' if i == 0 else f'y{i-1}') + ' + 1' for i in range(32)) +
    '; y31.\nwork n x = if n <= 0 then x else work (n - 1) (bumpTree (Nest (Cell x)) (Nest (Cell 0))).\n',
    'work 10000 x', 320000)

WORK['helper-return'] = (
    'Cell = Type (Cell Int).\nemitPayload x = ' +
    '; '.join(f'y{i} = ' + ('x' if i == 0 else f'y{i-1}') + ' + 1' for i in range(32)) +
    '; Cell y31.\nwork n x = if n <= 0 then x else '
    '(case emitPayload x of Cell y -> work (n - 1) y).\n',
    'work 10000 x', 320000)

# Cross both former hosted cutoffs under contention. One workload traverses
# the complete mutually recursive group and the other allocates a nominal
# result at every iteration when the return-worker rollback is selected.
SCALAR_GROUP_SIZE = 131
WORK['scalar-group'] = (
    '\n'.join(f'cycle{i} n x = if n <= 0 then x else cycle{(i + 1) % SCALAR_GROUP_SIZE} (n - 1) (x + 1).'
              for i in range(SCALAR_GROUP_SIZE)) + '\n', 'cycle0 10000 x', 10000)
import check_imported_carriers as imported_carrier
WORK['imported-carrier'] = (imported_carrier.bundled(imported_carrier.workload("api")).removeprefix("unsafe base.\n"),
                            'x + check 128', 128*129)
from check_base_carrier import workload as carrier_workload
WORK['base-carrier'] = (carrier_workload().removeprefix("unsafe base.\n"), 'x + check 128', 128*129)
from check_base_stored_fields import DECL as TREE_TYPES, TREE as TREE_FUNCTIONS, oracle as tree_score
WORK['base-fields'] = (
    TREE_TYPES.removeprefix("unsafe base.\n")+TREE_FUNCTIONS+
    'work d x = t = make d 1; a = score t; x - a - score t.\n',
    'work 11 x', -2 * tree_score(11, 1))
WORK['base-storage'] = (
    'Choice = Type (Plus Int | Minus Int).\n'
    'buildCells n = if n <= 0 then [] else (if n % 2 == 0 then Plus n else Minus n) :: buildCells (n - 1).\n'
    'readCells xs a = case xs of [] -> a | h :: tail -> case h of Plus v -> readCells tail (a+v) '
    '| Minus v -> readCells tail (a - v).\n'
    'work n x = xs = buildCells n; a = readCells xs x; readCells xs a.\n',
    'work 2000 x', 2000)
WORK['base-variant'] = (
    'Choice = Type (LeftCell Int | RightCell Int).\n'
    'choose n = if n < 0 then choose (0 - n) else if n % 2 == 0 then LeftCell n else RightCell (n+1).\n'
    'work n x = if n <= 0 then x else case choose n of LeftCell y -> work (n - 1) (x+y) '
    '| RightCell y -> work (n - 1) (x - y).\n', 'work 10000 x', 0)
WORK['base-transport'] = (
    'walk n p = if n <= 0 then p else walk (n - 1) p.\n'
    'work n x = if n <= 0 then x else case walk 3 (x,1) of (a,b) -> work (n - 1) (a+b).\n',
    'work 10000 x', 10000)
WORK['nested-return'] = (
    'emitNested x = '+ '; '.join(f'y{i} = '+('x' if i == 0 else f'y{i-1}')+' + 1' for i in range(32))+
    '; ((y31,1),(2,3)).\nwork n x = if n <= 0 then x else (case emitNested x of (a,b) -> '
    'case a of (p,q) -> case b of (r,s) -> work (n - 1) (p+q+r+s)).\n',
    'work 10000 x', 380000)
WORK['wide-return'] = (
    'Cell = Type (Cell Int).\nwidePayload x = ' +
    '; '.join(f'y{i} = ' + ('x' if i == 0 else f'y{i-1}') + ' + 1' for i in range(300)) +
    '; Cell y299.\nwork n x = if n <= 0 then x else '
    '(case widePayload x of Cell y -> work (n - 1) y).\n',
    'work 1000 x', 300000)

# A full native argument frame of rotating raw integers and Booleans keeps
# spill cells live across competing actors and observed entry-fuel resets.
from check_wide_scalar_workers import definition as wide_scalar_definition, call_arguments as wide_scalar_args, answer as wide_scalar_answer
WORK['wide-scalar'] = (wide_scalar_definition(64)+'\n', 'x + wide64 4051 '+wide_scalar_args(64,1), wide_scalar_answer(64,4051,1))

# Eight nested parameters require more than the former four expansion rounds.
_deep_body = '; '.join(f'y{i} = ' + ('x7' if i == 0 else f'y{i-1}') + ' + 1' for i in range(32)) + '; y31'
for _i in reversed(range(8)):
    _deep_body = f'case '+('a' if _i == 0 else f'x{_i-1}')+f' of Cell x{_i} -> '+_deep_body
_deep_value = 'x'
for _ in range(8):
    _deep_value = '(Cell '+_deep_value+')'
WORK['helper-deep'] = (
    'Cell a = Type (Cell a).\nbumpDeep a = '+_deep_body+'.\n'
    'work n x = if n <= 0 then x else work (n - 1) (bumpDeep '+_deep_value+').\n',
    'work 10000 x', 320000)

# Alternate a known constructor call with an opaque function call. The latter
# must enter the coalesced public guard while its sixteen arguments remain
# live across fuel ticks, including values beyond the register argument bank.
_guard_value = ' + '.join(f'x{i}' for i in range(16))
_guard_body = '; '.join(f'y{i} = ' + (_guard_value if i == 0 else f'y{i-1}') + ' + 1' for i in range(32)) + '; y31'
for _i in reversed(range(16)):
    _guard_body = f'case c{_i} of Cell x{_i} -> '+_guard_body
_guard_args = '(Cell x)'+' (Cell 0)'*15
WORK['helper-guard'] = (
    'Cell a = Type (Cell a).\nbumpGuard '+' '.join(f'c{i}' for i in range(16))+' = '+_guard_body+'.\n'
    'work n x = if n <= 0 then x else work (n - 1) '
    '(if n % 2 == 0 then bumpGuard '+_guard_args+' else (schedProbeOpaque bumpGuard) '+_guard_args+').\n',
    'work 10000 x', 320000)

VARIANTS = (
    ('scalar', 'default', {}),
    ('scalar-group', 'default', {}), ('scalar-group', 'boxed', {'FPR_NO_SCALAR_WORKERS': '1'}),
    ('wide-scalar', 'default', {}), ('wide-scalar', 'boxed', {'FPR_NO_SCALAR_WORKERS': '1'}),
    ('imported-carrier', 'default', {}), ('imported-carrier', 'boxed', {'FPR_NO_TYPE_SPEC': '1'}),
    ('base-carrier', 'default', {}), ('base-carrier', 'boxed', {'FPR_NO_TYPE_SPEC': '1'}),
    ('base-fields', 'default', {}), ('base-fields', 'boxed', {'FPR_NO_TYPE_SPEC': '1'}),
    ('base-storage', 'default', {}), ('base-storage', 'boxed', {'FPR_NO_TYPE_SPEC': '1'}),
    ('base-variant', 'default', {}), ('base-variant', 'boxed', {'FPR_NO_TYPE_SPEC': '1'}),
    ('base-transport', 'default', {}), ('base-transport', 'boxed', {'FPR_NO_TYPE_SPEC': '1'}),
    ('nested-return', 'default', {}), ('nested-return', 'boxed', {'FPR_NO_PAIR_RETURNS': '1'}),
    ('wide-return', 'default', {}), ('wide-return', 'boxed', {'FPR_NO_PAIR_RETURNS': '1'}),
    ('helper-guard', 'default', {}), ('helper-guard', 'boxed', {'FPR_NO_FIELD_WORKERS': '1'}),
    ('helper-deep', 'default', {}), ('helper-deep', 'boxed', {'FPR_NO_FIELD_WORKERS': '1'}),
    ('helper-return', 'default', {}), ('helper-return', 'boxed', {'FPR_NO_PAIR_RETURNS': '1'}),
    ('helper-tree', 'default', {}), ('helper-tree', 'boxed', {'FPR_NO_FIELD_WORKERS': '1'}),
    ('helper', 'default', {}), ('helper', 'boxed', {'FPR_NO_FIELD_WORKERS': '1'}),
    ('wrapper', 'default', {}), ('wrapper', 'boxed', {'FPR_NO_FIELD_WORKERS': '1'}),
    ('product', 'default', {}), ('product', 'boxed', {'FPR_NO_FIELD_WORKERS': '1'}),
    ('list', 'default', {}), ('list', 'unfused', {'FPR_NO_LIST_FUSE': '1'}),
    ('list', 'unbatched', {'FPR_NO_TICK_BATCH': '1'}),
    ('copy', 'default', {}),
)


def source(shape, rounds):
    code, work, result = WORK['scalar' if shape == 'copy' else shape]
    copy = shape == 'copy'
    payload = 'List.range 1 4096' if copy else '0'
    pong = ('case receive self of (who,n,payload) -> _ = send who (n + 1,payload); pong self.'
            if copy else 'case receive self of (who,n,payload) -> _ = send who (n + 1); pong self.')
    receive = ('case receiveFrom me p of (r,returned) -> (r,returned)' if copy
               else '(receiveFrom me p,0)')
    check = 'List.length returned == 4096 and List.sum returned == 8390656' if copy else 'True'
    return f'''unsafe base.
{('List = use "std/list".' if copy else '')}
{code}
schedProbeOpaque : a -> a.
schedProbeRole : Int -> Unit.
schedProbeBegin : Unit -> Unit.
schedProbeEnd : Unit -> Unit.
schedProbeReport : Unit -> Unit.
schedProbeStall : Unit -> Unit.
spin x = y = {work}; spin (y - {result}).
hog parent self = _ = schedProbeRole 1; x = 0; ready = {work};
  _ = send parent ready; spin (ready - {result}).
ponger self = _ = schedProbeRole 2; pong self.
pong self = {pong}
ping me p k acc samples payload = if k == 0 then (acc,samples) else
  start = Sys.timeUs Unit; _ = send p (me,k,payload); (r,returned) = {receive};
  elapsed = Sys.timeUs Unit - start;
  _ = if r == k + 1 and {check} then Unit else error "bad reply";
  ping me p (k - 1) (acc + r) (elapsed :: samples) payload.
start me n remote = if n == 0 then [] else
  spawnOn (if remote then n % 2 else 0) (hog me) :: start me (n - 1) remote.
ready me actors = case actors of [] -> Unit | a :: rest ->
  value = receiveFrom me a; _ = if value == {result} then Unit else error "bad warmup";
  ready me rest.
stop actors = case actors of [] -> Unit | a :: rest -> _ = kill a; stop rest.
dump samples = case samples of [] -> Unit | x :: rest -> _ = print x; dump rest.
run route load = _ = schedProbeRole 3; me = myself 0;
  remote = route == "remote"; count = if load == "eight" then 8 else if load == "one" then 1 else 0;
  actors = start me count remote; _ = ready me actors;
  p = spawnOn (if remote then 1 else 0) ponger; payload = {payload};
  _ = ping me p 16 0 [] payload;
  _ = schedProbeBegin Unit; result = ping me p {rounds} 0 [] payload;
  _ = schedProbeEnd Unit; _ = stop actors; _ = kill p; _ = schedProbeReport Unit;
  case result of (acc,samples) -> print acc >> dump samples.
staller self = schedProbeStall Unit.
main = case Sys.args Unit of
  ["stall"] -> me = myself 0; a = spawnOn 0 staller; print (receiveFrom me a)
  | [route,load] -> run route load
  | _ -> error "scheduler fixture arguments".
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stats(values, deadline):
    ordered = sorted(values)
    return dict(count=len(values), p50_us=ordered[math.ceil(len(values)*.5)-1],
                p95_us=ordered[math.ceil(len(values)*.95)-1], p99_us=ordered[math.ceil(len(values)*.99)-1],
                max_us=max(values), deadline_us=deadline,
                deadline_exceedances=sum(v > deadline for v in values))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--rounds', type=int, default=128)
    ap.add_argument('--repetitions', type=int, default=1)
    ap.add_argument('--deadline-us', type=int, default=1000,
                    help='observational threshold only; never a certified deadline or CI timing gate')
    ap.add_argument('--record', type=Path)
    args = ap.parse_args()
    assert args.rounds >= 64 and args.repetitions >= 1 and args.deadline_us > 0
    spec = importlib.util.spec_from_file_location('native_insns', ROOT/'tools/native-insns-ratchet.py')
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    rows, reports, controls = [], [], []
    with tempfile.TemporaryDirectory(prefix='fpr-sched-latency-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'))
        cc = shlex.split(os.environ.get('CC', 'cc'))
        wrapper = tmp/'probe-cc'
        wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\n'
                           f'cc = {cc!r}\nos.execvp(cc[0], cc + ["-DFPR_SCHED_PROBE"] + sys.argv[1:])\n')
        wrapper.chmod(0o755)

        def checked(command, env, timeout=180):
            p = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True, timeout=timeout)
            assert p.returncode == 0, (list(map(str, command)), p.stdout[-2000:], p.stderr[-5000:])
            return p

        # Build everything before measurement, keeping compile activity out of
        # each latency sample. The cache key includes the distinct CC wrapper.
        builds = []
        for shape, variant, switches in VARIANTS:
            name = shape+'-'+variant
            src = tmp/(name+'.fpr')
            src.write_text(source(shape, args.rounds))
            env = dict(base, **switches)
            exes = {}
            for probe in (False, True):
                exe = tmp/(name+('-probe' if probe else '-plain'))
                checked([ROOT/'fpr', 'build', src, '--harts', '4', '--with', HAL,
                         *(['--cc', wrapper] if probe else []), '-o', exe], env)
                symbols = checked(['nm', exe], env).stdout
                assert bool(re.search(r'\b_?fpr_sched_probe$', symbols, re.M)) == probe
                exes[probe] = exe
            asm = tmp/(name+'.s')
            checked([ROOT/'fpr', 'compile', '--system=posix', '--target=rv64', src, asm], env)
            report = audit.audit(asm, 'rv64')
            emission = '\n'.join(Path(f['path']).read_text() for f in report['files'])
            fuel_sites = emission.count('call fpr_fuel_save_local')
            assert fuel_sites > 0
            if shape in ('wrapper', 'product'):
                assert ('# fn $worker.fields.work' in emission) == (variant == 'default')
            if shape == 'scalar-group':
                workers = re.findall(r'^# fn \$worker\.scalar\.cycle[0-9]+\b', emission, re.M)
                assert len(workers) == (SCALAR_GROUP_SIZE if variant == 'default' else 0), (variant, len(workers))
            if shape == 'wide-scalar':
                assert ('# fn $worker.scalar.wide64 ' in emission) == (variant == 'default')
            if shape == 'imported-carrier':
                copies = re.findall(r'^# fn \$carrier\.\S+\.pack@\S+\.\$at\.root\.',emission,re.M)
                assert len(copies)==int(variant=='default'),(variant,copies)
            if shape == 'base-carrier':
                assert ('# fn $carrier.6.Meters.fill ' in emission) == (variant=='default')
            if shape == 'base-fields':
                assert ('# fn $worker.storage.aggregate.make ' in emission) == (variant=='default')
            if shape == 'base-storage':
                assert ('# fn $worker.storage.list.buildCells ' in emission) == (variant=='default')
            if shape == 'base-variant':
                assert ('# fn $worker.ret2.$variant.choose ' in emission) == (variant=='default')
            if shape == 'base-transport':
                assert ('# fn walk$typespec$type$' in emission) == (variant=='default')
            if shape == 'nested-return':
                assert ('# fn $worker.ret4.$nested.result.emitNested ' in emission) == (variant=='default')
            if shape == 'wide-return':
                assert ('# fn $worker.ret1.widePayload' in emission) == (variant == 'default')
            if shape == 'helper-guard':
                assert ('# fn '+('$worker.fields.'*16)+'bumpGuard' in emission) == (variant == 'default')
                public=re.search(r'^# fn bumpGuard\b.*?(?=^# fn |\Z)',emission,re.M|re.S)
                assert public and ((public[0].count('call fpr_fuel_save_local')>1) == (variant=='default'))
            if shape == 'helper-deep':
                assert ('# fn '+('$worker.fields.'*8)+'bumpDeep' in emission) == (variant == 'default')
            if shape == 'helper-return':
                assert ('# fn $worker.ret1.emitPayload' in emission) == (variant == 'default')
            if shape == 'helper-tree':
                assert ('# fn $worker.fields.$worker.fields.$worker.fields.$worker.fields.bumpTree' in emission) == (variant == 'default')
            if shape == 'helper':
                assert ('# fn $worker.fields.bumpCell' in emission) == (variant == 'default')
            reports.append(dict(shape=shape, variant=variant, source_sha256=digest(src),
                                switches=switches, static_fuel_call_sites=fuel_sites, report=report))
            builds.append((shape, variant, env, exes))
            print(f'{name}: plain/probe builds, hook absence and full RV64 report coverage PASS', flush=True)

        list_sites = {r['variant']: r['static_fuel_call_sites'] for r in reports if r['shape'] == 'list'}
        assert list_sites['unbatched'] > list_sites['default'], list_sites

        for shape, variant, env, exes in builds:
            for harts, route in ((1, 'local'), (4, 'local'), (4, 'remote')):
                for count, load in ((0, 'zero'), (1, 'one'), (8, 'eight')):
                    runenv = dict(env, FPR_HARTS=str(harts), FPR_BLOCK_SPIN_NS='0')
                    identity = dict(shape=shape, variant=variant, harts=harts, route=route, competitors=count)
                    probe_rows, samples = [], []
                    for probe in (True, False):
                        for repetition in range(1 if probe else args.repetitions):
                            p = checked([exes[probe], route, load], runenv, timeout=60)
                            result, *times = [int(line) for line in p.stdout.splitlines()]
                            assert result == args.rounds*(args.rounds+3)//2
                            assert len(times) == args.rounds and all(type(x) is int and x >= 0 for x in times)
                            if probe:
                                probe_rows = [json.loads(line[len('[fpr sched] '):]) for line in p.stderr.splitlines()
                                              if line.startswith('[fpr sched] ')]
                                assert len(probe_rows) == len(p.stderr.splitlines()), p.stderr
                                assert len(probe_rows) == count+2, (identity, p.stderr)
                                assert len({r['actor'] for r in probe_rows}) == len(probe_rows)
                                hogs = [r for r in probe_rows if r['role'] == 1]
                                assert len(hogs) == count
                                assert all(r['fuel'] > 0 and r['slots'] > 0 for r in hogs), (identity, hogs)
                                for role, mask in ((2, 2 if route == 'remote' else 1), (3, 1)):
                                    actors = [r for r in probe_rows if r['role'] == role]
                                    assert len(actors) == 1 and actors[0]['hart_mask'] == mask, (identity, actors)
                                assert all(r['hart_mask'] in (1, 2) for r in hogs)
                                if route == 'local':
                                    assert all(r['hart_mask'] == 1 for r in hogs)
                            else:
                                assert not p.stderr, (identity, p.stderr)
                                samples.append(dict(repetition=repetition, samples_us=times,
                                                    **stats(times, args.deadline_us)))
                    flat = [v for sample in samples for v in sample['samples_us']]
                    rows.append(dict(**identity, probe_actors=probe_rows, plain_runs=samples,
                                     summary=stats(flat, args.deadline_us)))
                print(f'{shape}-{variant}, {harts} harts {route}: 0/1/8 competitors, fuel/progress/latency PASS', flush=True)

        # A known unbounded C call must starve a same-hart requester. A process
        # timeout kills and reaps it; the entry marker distinguishes this from
        # slow startup. This is a negative control, never an admitted workload.
        _, _, env, exes = builds[0]
        for harts in (1, 4):
            try:
                p = subprocess.run([exes[False], 'stall'], cwd=ROOT,
                                   env=dict(env, FPR_HARTS=str(harts), FPR_BLOCK_SPIN_NS='0'),
                                   text=True, capture_output=True, timeout=3)
                raise AssertionError(('unbounded C unexpectedly returned', p))
            except subprocess.TimeoutExpired as exc:
                stderr = exc.stderr or b''
                if isinstance(stderr, str):
                    stderr = stderr.encode()
                assert b'scheduler stall entered\n' in stderr, stderr
                controls.append(dict(harts=harts, entered=True, watchdog_seconds=3, killed_and_reaped=True))
        print('Unbounded runtime C negative control: watchdog detected starvation, killed/reaped on 1/4 harts PASS', flush=True)

    record = dict(schema='scheduler-latency-v1', host=dict(system=platform.system(), machine=platform.machine(),
                  release=platform.release()), compiler_sha256=digest(ROOT/'fpr'),
                  runtime_sha256=digest(ROOT/'runtime/actors.c'), probe_sha256=digest(HAL),
                  harness_sha256=digest(Path(__file__)), rounds=args.rounds, repetitions=args.repetitions,
                  receive_spin_ns=0, fuel_quantum=2000, rows=rows, native_reports=reports, negative_controls=controls,
                  limitations=['Host samples, not a maximum elapsed-time guarantee or physical-board qualification.',
                               'Probe slot durations are instrumented and are not plain-runtime response latencies.',
                               'Per-actor fuel proof applies to probe executions; ordinary executions use the same workload and warmup protocol.',
                               'All competitors must exhaust fuel after the begin marker and before the end closes observer admission.',
                               'Slots include only completed dispatches starting after begin; boundary-straddling slots are excluded.',
                               'RV64 reports cover every emitted function but not interprocedural composition or runtime C cost.',
                               'The deadline threshold counts observations; it is not a timing-admission contract.'])
    if args.record:
        args.record.write_text(json.dumps(record, indent=2)+'\n')
    print(f'Scheduler latency qualification: {len(rows)} configurations PASS; no WCET claim', flush=True)


if __name__ == '__main__':
    main()
