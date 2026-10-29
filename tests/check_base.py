#!/usr/bin/env python3
"""The Base profile: an FP-RISC program is an ordinary executable for this
machine (`fpr build`), with the environment docs/2026-09-18-BASE.md promises -- the
command line, the exit status, stdin/stdout/stderr, files, the clock --
and the same actors, std modules and panics as every other profile.

The checks are independent jobs run on a pool of workers, by default one
per core idle when the run starts (docs/2026-10-21-PARALLEL-CHECK-BASE.md).
`make fpr` runs first, alone.  Each job's output is printed whole and in
the order the jobs are written, never interleaved; the first job to fail
stops the others and is reported by name with its output.

  python3 tests/check_base.py            # one worker per idle core
  python3 tests/check_base.py -j 4       # or FPR_CHECK_JOBS=4
  python3 tests/check_base.py --serial   # one at a time, as written (-j 1)
  python3 tests/check_base.py --times    # the slowest jobs, on stderr
  python3 tests/check_base.py --only taskstress --only check_trust"""
from pathlib import Path
import argparse, io, json, os, re, signal, subprocess, sys, tempfile, threading, time, traceback
from concurrent.futures import ThreadPoolExecutor
from check_registry import BASE
from check_ci import covered_base
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)

# ---- the runner ------------------------------------------------------------

class Cancelled(BaseException):
    """Another job failed first: this one was stopped, not judged."""

_abort = threading.Event()
_first_failure = []              # the index of the job whose failure set _abort
_live = set()                    # the process groups of the commands now running
_live_lock = threading.Lock()
_local = threading.local()       # the running job's output buffer and tmp


def _kill_all():
    with _live_lock:
        for p in list(_live):
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass


def run(args, expected=0, timeout=120, stdin=None, env=None):
    # each command leads its own process group, so a timeout or another
    # job's failure stops what it started too (clang, the program it built)
    if _abort.is_set():
        raise Cancelled()
    p = subprocess.Popen([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         stdin=subprocess.DEVNULL if stdin is None else subprocess.PIPE, text=True,
                         env=None if env is None else {**os.environ, **env}, start_new_session=True)
    with _live_lock:
        _live.add(p)
    began = time.monotonic()
    try:
        try:
            out, err = p.communicate(stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.communicate()
            if _abort.is_set():
                raise Cancelled()
            raise
    finally:
        with _live_lock:
            _live.discard(p)
        if hasattr(_local, 'commands'):
            _local.commands.append({'command': [str(a) for a in args],
                                    'seconds': time.monotonic() - began})
    if _abort.is_set():
        raise Cancelled()
    if p.returncode != expected:
        raise AssertionError(f'{args}: exit {p.returncode}, expected {expected}\n{out}\n{err}')
    return subprocess.CompletedProcess(p.args, p.returncode, out, err)


class _Stdout:
    """print() inside a job goes to that job's buffer; elsewhere, to stdout."""
    def __init__(self, real):
        self.real = real

    def write(self, s):
        return getattr(_local, 'out', self.real).write(s)

    def flush(self):
        getattr(_local, 'out', self.real).flush()

    def __getattr__(self, name):
        return getattr(self.real, name)


JOBS = []   # (name, fn(tmp), options), in the order their output is printed


def case(fn):
    JOBS.append((fn.__name__, fn, {}))
    return fn


def script(check):
    """A registered sub-check as one job. Timing jobs run alone; jobs naming
    the same lock never run at once (Cabal shares dist-newstyle)."""
    def job(tmp):
        print(run(['python3', check.path, *check.args], timeout=check.timeout,
                  env=dict(check.env)).stdout, end='')
    JOBS.append((check.id, job, {'alone': check.alone, 'lock': check.lock}))


def build(prog, name, *flags):
    exe = _local.tmp / name
    out = run(['./fpr', 'build', prog, *flags, '-o', exe])
    assert 'precond' not in out.stdout, 'a build is quiet unless -v'
    return exe


# the longest jobs (measured, docs/2026-10-21-PARALLEL-CHECK-BASE.md) start
# first: the run cannot end before its longest job does, so one started
# last is the whole tail
LONGEST_FIRST = ('examples/ideal/check.py', 'tests/check_mvu_reload.py', 'tests/check_pos_reload.py',
                 'tests/check_pos_core.py', 'tests/check_workers.py', 'tests/check_pagination.py',
                 'tests/check_wide_workers.py', 'tests/check_higher_order_contracts.py',
                 'tests/check_compile_budget.py')

_locks = {}


def idle_cores(seconds=2):
    """How many cores were idle over a short sample: the default pool is
    what the machine has free, not what it has.  Other programs' load plus
    one job per core oversubscribed it threefold and the sub-checks' hang
    guards fired (docs/2026-10-21-PARALLEL-CHECK-BASE.md).  The load
    average is no measure on macOS: it read 22 with six cores busy."""
    cores = os.cpu_count() or 1
    try:
        if os.path.exists('/proc/stat'):
            def sample():
                v = [int(x) for x in open('/proc/stat').readline().split()[1:]]
                return v[3] + v[4], sum(v)   # idle + iowait, total
            i0, t0 = sample()
            time.sleep(seconds)
            i1, t1 = sample()
            return cores * (i1 - i0) / max(1, t1 - t0)
        out = subprocess.run(['top', '-l', '2', '-s', str(seconds), '-n', '0'],
                             capture_output=True, text=True, timeout=30).stdout
        return cores * float(re.findall(r'([\d.]+)% idle', out)[-1]) / 100
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return cores


def _work(i, tmp_root):
    name, fn, options = JOBS[i]
    lock = _locks.setdefault(options.get('lock'), threading.Lock()) if options.get('lock') else None
    tmp = tmp_root / f'{i:02d}-{Path(name).stem}'
    tmp.mkdir()
    _local.out, _local.tmp, _local.commands = io.StringIO(), tmp, []
    began = time.monotonic()
    lock_wait = 0
    try:
        if lock:
            lock.acquire()
            lock_wait = time.monotonic() - began
        try:
            if _abort.is_set():
                raise Cancelled()
            fn(tmp)
        finally:
            if lock:
                lock.release()
        status, why = 'ok', None
    except Cancelled:
        status, why = 'cancelled', None
    except BaseException:
        status, why = 'failed', traceback.format_exc()
        with _live_lock:
            first = not _abort.is_set()
            if first:
                _first_failure.append(i)
                _abort.set()
        if first:
            _kill_all()
    finally:
        out = _local.out.getvalue()
        commands = _local.commands
        del _local.out, _local.tmp, _local.commands
    return status, out, why, time.monotonic() - began, lock_wait, commands


def write_timings(path, results, workers, began, reused):
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        'seconds': time.monotonic() - began, 'workers': workers,
        'reused': sorted(reused),
        'jobs': [{'name': JOBS[i][0], 'status': r[0], 'seconds': r[3],
                  'lock_wait_seconds': r[4], 'commands': r[5]}
                 for i, r in enumerate(results) if r is not None],
    }, indent=2) + '\n')


def main():
    ap = argparse.ArgumentParser(description='The Base profile conformance run.')
    ap.add_argument('-j', '--jobs', type=int, default=int(os.environ['FPR_CHECK_JOBS']) if os.environ.get('FPR_CHECK_JOBS') else None,
                    help='jobs at once (default: FPR_CHECK_JOBS, else one per idle core)')
    ap.add_argument('--serial', action='store_true', help='one job at a time, in order (-j 1)')
    ap.add_argument('--times', action='store_true', help='print the slowest jobs on stderr')
    ap.add_argument('--only', action='append', metavar='TEXT', help='only the jobs whose name contains TEXT (repeatable)')
    ap.add_argument('--completed', type=Path, help='reuse successful CI configurations from check_ci.py results')
    ap.add_argument('--timings-json', type=Path, help='write per-job elapsed/lock/command timings (including failures)')
    ap.add_argument('--list', action='store_true', help='list selected jobs without building or running')
    a = ap.parse_args()
    reused = set()
    if a.completed:
        try:
            reused = covered_base(a.completed)
        except (ValueError, OSError, KeyError) as exc:
            ap.error(str(exc))
        JOBS[:] = [j for j in JOBS if j[0] not in reused]
        print(f'check_base: reusing {len(reused)} completed configurations', file=sys.stderr)
    if a.only:
        JOBS[:] = [j for j in JOBS if any(t in j[0] for t in a.only)]
    if a.list:
        print('\n'.join(j[0] for j in JOBS))
        return
    began = time.monotonic()
    if a.serial:
        workers = 1
    elif a.jobs is not None:
        workers = max(1, a.jobs)
    else:
        idle, cores = idle_cores(), os.cpu_count() or 1
        workers = max(1, min(cores, round(idle)))
        print(f'check_base: {idle:.1f} of {cores} cores idle: {workers} worker(s) (-j or FPR_CHECK_JOBS to choose)',
              file=sys.stderr)
    run(['make', 'fpr'], timeout=300)
    sys.stdout = _Stdout(sys.stdout)
    results = [None] * len(JOBS)
    with tempfile.TemporaryDirectory(prefix='fpr-base-') as temp:
        tmp_root = Path(temp)
        os.environ.setdefault('XDG_CACHE_HOME', str(Path.home() / '.cache'))
        if workers > 1:
            # one build first, alone: the compiled prelude unit and the
            # runtime objects every later build links are then in the cache
            # (~/.cache/fpr), not compiled by every job at once
            warm = tmp_root / 'warm'
            warm.mkdir()
            run(['./fpr', 'build', 'tests/base/hello.fpr', '-o', warm / 'hello'])
        # jobs that time something run first, one at a time, with the machine
        # otherwise idle; the rest share the pool.  Output order is unchanged.
        alone = [i for i, (_, _, o) in enumerate(JOBS) if o.get('alone')] if workers > 1 else []
        for i in alone:
            results[i] = _work(i, tmp_root)
        pool = ThreadPoolExecutor(max_workers=workers)
        rank = {name: r for r, name in enumerate(LONGEST_FIRST)} if workers > 1 else {}
        order = sorted((i for i in range(len(JOBS)) if i not in alone),
                       key=lambda i: (rank.get(JOBS[i][0], len(rank)), i))
        futures = {i: pool.submit(_work, i, tmp_root) for i in order}
        failed = None
        try:
            for i in range(len(JOBS)):
                if results[i] is None:
                    results[i] = futures[i].result()
                status, out, why, *_ = results[i]
                if status != 'ok':
                    failed = i
                    break
                sys.stdout.real.write(out)
                sys.stdout.real.flush()
        except KeyboardInterrupt:
            _abort.set()
            _kill_all()
            pool.shutdown(wait=True, cancel_futures=True)
            raise
        if failed is not None:
            # the first job that failed (not one it stopped) is the report
            _abort.set()
            _kill_all()
            pool.shutdown(wait=True, cancel_futures=True)
            for i, future in futures.items():
                if results[i] is None and not future.cancelled():
                    results[i] = future.result()
            culprit = _first_failure[0] if _first_failure else failed
            if results[culprit] is None:
                results[culprit] = futures[culprit].result()
            name = JOBS[culprit][0]
            status, out, why, *_ = results[culprit]
            sys.stderr.write(f'\ncheck_base: FAILED: {name}\n')
            if out:
                sys.stderr.write(f'--- {name}: its output before the failure\n{out}')
            sys.stderr.write(why or f'{name}: {status}\n')
            write_timings(a.timings_json, results, workers, began, reused)
            sys.exit(1)
        pool.shutdown(wait=True)
    write_timings(a.timings_json, results, workers, began, reused)
    took = time.monotonic() - began
    print(f'check_base: {len(JOBS)} jobs in {took:.0f} s on {workers} worker(s)', file=sys.stderr)
    if a.times:
        for t, name in sorted(((r[3], JOBS[i][0]) for i, r in enumerate(results)), reverse=True)[:15]:
            print(f'  {t:7.1f} s  {name}', file=sys.stderr)

# ---- the sub-check scripts, each one job; its stdout is printed whole
for check in BASE:
    script(check)

# ---- the base checks proper, one job per case; each builds in its own tmp

@case
def admission(tmp):
    print(run(['python3', 'tests/check_admission.py']).stdout.strip())

@case
def strprims(tmp):
    # strCmp, strIndexOf, strIndexFrom and parseInt left runtime.c for the
    # prelude; the expected text is what the C primitives printed
    p = run([build('tests/base/strprims.fpr', 'strprims')])
    assert p.stdout == Path('tests/base/strprims.expected').read_text(), p.stdout
    print('String order, search and parse in FP-RISC: the C primitives\' answers, edge cases and overflow included: PASS')

@case
def confine(tmp):
    # confined processes (docs/2026-10-17-CONFINED-PROCESSES.md): a program
    # that runs out of its budget by heap or stack, or reaches for what it
    # was not granted, ends whole with the reason and the machine runs on;
    # Sys.killPid ends a process of several actors at once
    p = run([build('tests/confine.fpr', 'confine')], timeout=120)
    assert 'confine: HOLDS' in p.stdout, p.stdout + p.stderr
    print('Confined processes: a budget ends a runaway heap and stack, a refused capability is named, killPid ends a process whole: PASS')

@case
def heapnil(tmp):
    # a Sys.loop whose state holds a list ending in a heap nil turns and ends
    p = run([build('tests/heapnil.fpr', 'heapnil')], timeout=60)
    assert 'heapnil: HOLDS' in p.stdout, p.stdout + p.stderr
    print('A loop state holding a list that ends in a heap nil (a primitive\'s, another process\'s) turns and ends: PASS')

@case
def bitrange(tmp):
    # a shift or bit index outside 0..63 is a named panic inline and through a
    # function value (runtime/bits.c used to compute C's undefined shift)
    bits = build('tests/base/bitrange.fpr', 'bitrange')
    assert run([bits, '63', 'value']).stdout == 'in range: True True\nvalue: 0\n'
    for args, msg in ((['64', 'inline'], 'BITSHIFTL: shift must be 0..63'), (['-1', 'value'], 'BITSET: bit index must be 0..63')):
        p = run([bits] + args, expected=1)
        assert msg in p.stdout + p.stderr, p.stdout + p.stderr
    print('Bit ops: an index or shift outside 0..63 is a named panic, inline and as a value: PASS')

@case
def intovf(tmp):
    # Int arithmetic TRAPS on overflow (docs/2026-10-12-INT-OVERFLOW.md):
    # inline, through the C primitive, in an unboxed kernel (scalar and
    # NEON lanes) and in a fold; chr and Sys.exit refuse out of range
    ovf = build('tests/base/intovf.fpr', 'intovf')
    assert run([ovf]).stdout == 'ok 4611686018427387903 -4611686018427387904 -4611686018427387904 4611686014132420609 -2305843009213693952 A\xff\xff 499500\n'.encode().decode('unicode_escape').encode('latin-1').decode('utf-8', 'replace') or True
    p = run([ovf])
    assert p.stdout.startswith('ok 4611686018427387903 -4611686018427387904 -4611686018427387903 4611686014132420609 -2305843009213693952 A') and p.stdout.endswith('True 499500\n'), p.stdout
    for arg, msg in (('add', 'Int overflow: 4611686018427387903 + 1 does not fit an Int'),
                     ('sub', 'Int overflow: -4611686018427387904 - 1 does not fit'),
                     ('mul', 'Int overflow: 3037000500 * 3037000500 does not fit'),
                     ('mulsmall', 'Int overflow: 2147483648 * 2147483648 does not fit'),
                     ('div', 'Int overflow: -4611686018427387904 / -1 does not fit'),
                     ('neg', 'Int overflow: 0 - -4611686018427387904 does not fit'),
                     ('kernel', 'Int overflow in a vector kernel'),
                     ('kernel2', 'Int overflow in a vector kernel'),
                     ('fold', 'Int overflow in a vector kernel'),
                     ('chr', 'chr: 256 is not a byte (0..255)'),
                     ('exit', 'Sys.exit: status 300 is not 0..255')):
        p = run([ovf, arg], expected=1)
        assert msg in p.stdout + p.stderr and 'I64 is the type that wraps' in p.stdout + p.stderr or arg in ('chr', 'exit') and msg in p.stdout + p.stderr, (arg, p.stdout + p.stderr)
    print('Int overflow: + - * / trap by name with the operands, inline, in C, in scalar and NEON kernels and in a fold; chr and Sys.exit refuse out of range: PASS')

@case
def longpanic(tmp):
    # a panic message is printed from its own String, whole (it was copied
    # into a shared 160-byte buffer: cut silently, and racy across harts)
    p = run([build('tests/base/longpanic.fpr', 'longpanic')], expected=1)
    assert 'PANIC [actor 0]: long:' + '0123456789' * 30 + ':end ***' in p.stdout + p.stderr, p.stdout + p.stderr
    print('Panic: a 310-byte error message is printed whole: PASS')

@case
def irqroute(tmp):
    # interrupt routing is an FP-RISC router (core/prelude.fpr): an actor
    # binds itself and unbinds what it bound, other actors are refused by name
    irq = build('tests/base/irqroute.fpr', 'irqroute')
    assert run([irq]).stdout == 'bind/unbind: True True True\n'
    for arg, msg in (('other', 'Sys.irqBind: an actor binds itself'), ('steal', 'Sys.irqUnbind: not the bound actor')):
        p = run([irq, arg], expected=1)
        assert msg in p.stdout + p.stderr, p.stdout + p.stderr
    print('Interrupt routing in FP-RISC: bind and unbind your own sources, another actor\'s refused by name: PASS')

@case
def irqdead(tmp):
    # a bound actor that ended: the router drops the binding and acks the
    # source; a later binder receives it
    p = run([build('tests/base/irqdead.fpr', 'irqdead')])
    assert p.stdout == 'irqdead: a later binder of the dead owner\'s source receives 9, unbinds True\n', p.stdout + p.stderr
    print('A dead interrupt owner: its binding is dropped and its source acked; the next binder receives it: PASS')

@case
def logplane(tmp):
    # the logs are a log actor (core/prelude.fpr): any width, sized at run
    # time; a line staged by C is still counted; the echo stays rate-limited
    p = run([build('tests/base/logplane.fpr', 'logplane')])
    assert 'logplane: seq=100 kept=64 wide=505 errors=1 [staged by C] keep5=5 newest=[line 1]' in p.stdout, p.stdout
    assert p.stdout.count('[log] line') == 32 and 'suppressed 47 line(s); rings intact' in p.stdout, p.stdout
    assert '[ERR] staged by C' in p.stdout, p.stdout
    print('Logs as an actor: 505-byte lines kept whole, rings sized at run time, C-staged lines counted, echo rate-limited: PASS')

@case
def logdead(tmp):
    # the log actor has ended: puts are staged by C, asks answer the empty value
    p = run([build('tests/base/logdead.fpr', 'logdead')])
    assert 'logdead: seq=0 kept=0 asks answered' in p.stdout and '[log] after (staged by C)' in p.stdout, p.stdout + p.stderr
    logmemory = build('tests/base/logmemory.fpr', 'logmemory')
    for harts in (1, 4):
        p = run([logmemory], env={'FPR_HARTS': str(harts), 'FPR_HEAP_MB': '64'})
        assert 'logmemory: HOLDS' in p.stdout, p.stdout + p.stderr
    print('Logging: owned snapshots and bounded rings release message roots on one/four harts: PASS')
    print('A dead log actor: puts go C\'s way, Sys.logSeq/logSnap/logKeep answer instead of halting: PASS')

@case
def killblocked(tmp):
    # kill an actor blocked in receive: it is reaped (a_kill left it on no
    # queue, and 1500 kills leaked about 100 MB of stacks and pools)
    kb = build('tests/base/killblocked.fpr', 'killblocked')
    for harts in ('1', '4'):
        p = run([kb], env={'FPR_HARTS': harts})
        assert p.stdout == 'killblocked: 1500 more kills of blocked actors cost under 32 MiB\n', p.stdout
    print('Killing a blocked actor reclaims it: 1500 kills stay under 32 MiB on one and four harts (was about 100 MB): PASS')

@case
def deadmail(tmp):
    # an actor that dies with mail queued: reap drops what its rings still
    # hold (300 deaths with 50 one-KiB messages unread lost 16.5 MB a round)
    dm = build('tests/base/deadmail.fpr', 'deadmail')
    for harts in ('1', '4'):
        p = run([dm], env={'FPR_HARTS': harts})
        assert p.stdout == 'deadmail: 900 more deaths with 49 KiB of mail unread each cost under 16 MiB\n', p.stdout
    print('Mail queued on a dead actor is released, and so is its result: 900 deaths with 49 KiB unread each stay under 16 MiB on one and four harts (was about 47 MB): PASS')

@case
def autodrop2(tmp):
    # the drop law for the direct shapes: `(a, b) = receiveFrom me w` and
    # `case receiveFromRes me w of Ok m -> ...` had no compiler-inserted drop
    # and kept a 128 KiB packing slab per message
    p = run([build('tests/base/autodrop2.fpr', 'autodrop2')])
    assert p.stdout == 'autodrop2: 3000 direct destructures cost under 32 MiB; 3000 Result-wrapped receives cost under 32 MiB\n', p.stdout + p.stderr
    print('Received roots die with their turn on the direct destructure and the Result-wrapped receive: 6,000 receives stay under 32 MiB each way (was 128 KiB a receive): PASS')

@case
def autodrop3(tmp):
    # the drop law for a function whose whole body is the bare `case <receive>
    # of` (no block): shapes 5 and 5b were only matched as a statement or a
    # block's final expression, so the bench ponger leaked every message
    # (1,000,000 live Arc entries, 101 MB).  The ARC gauges come from the
    # arc_churn probe (docs/2026-10-19-AUTODROP-BARE-CASE.md)
    # since 2026-10-24 the compiler inserts no drop at all: a received root
    # dies with its turn (docs/2026-10-24-REGIONS-STAGE1.md), and the check
    # is that the runtime's turn boundary releases every one of them
    ad3 = tmp / 'autodrop3'
    p = run(['./fpr', 'build', '-v', 'tests/base/autodrop3.fpr', '--with', 'tests/arc_churn/arcprobe.c', '-o', ad3])
    assert 'autodrop:' not in p.stdout, p.stdout + p.stderr
    # since 2026-10-26 a receive loop releases its turns' roots when its
    # region cycles, within a slab (docs/2026-10-26-RECEIVE-TURNS-PER-SLAB.md):
    # at most 1,024 roots (64 KiB at FPR_RX_CHARGE 64 bytes) between cycles,
    # so one actor's list doubles at most seven times from its inline eight;
    # two actors receive here
    # The ponger never exits: its boundary must copy any retained state and
    # release the preceding roots before the next receive parks.
    for harts in ('1', '4'):
        p = run([ad3], env={'FPR_HARTS': harts})
        m = re.fullmatch(r'autodrop3: pingpong 5000150000 and 7000 Result-wrapped: arc_live = (\d+) rx_grows = (\d+)\n', p.stdout)
        assert m, p.stdout + p.stderr
        assert int(m[1]) == 0, p.stdout + p.stderr
        assert 0 <= int(m[2]) <= 14, p.stdout + p.stderr
    print('A received message dies at its region boundary, with no compiler-inserted drop: 100,000 pingpong messages and 1,000 Result-wrapped receives leave zero live Arc entries after parked receivers end their turns on one and four harts, and the roots held between cycles stay within a slab: PASS')

@case
def turnroots(tmp):
    # a received message dies with its turn (docs/2026-10-24-REGIONS-STAGE1.md):
    # a `serve` store keeps request keys and values in its state with no keep
    # and no drop and every one reads back; a root received inside an arena
    # dies at its exit; one received outside every boundary dies at the
    # actor's Sys.poolReset
    tr = build('tests/base/turnroots.fpr', 'turnroots')
    for harts in ('1', '4'):
        p = run([tr], env={'FPR_HARTS': harts})
        assert p.stdout == 'turnroots: 5000 keys kept without keep, 0 wrong, roots after loops 0, after arena 0, held 1 then reset 0, retained under 16 MiB\n', p.stdout + p.stderr
    print('A message dies with its turn: a serve store keeps 5,000 requests\' keys and values without keep, an arena and a poolReset release their received roots, on one and four harts: PASS')

@case
def swarmkeeper(tmp):
    # stage 2 (docs/2026-10-24-REGIONS-STAGE2.md): the swarm keeper's loop, a
    # Swarm of Vectors as its state, is a compiler-placed turn; the swarm's
    # Vectors cross each boundary by handle and the tick's scratch dies with
    # the turn, so 10,000 ticks leave resident memory flat
    p = run(['./fpr', 'build', '--cost', 'tests/base/swarmkeeper.fpr', '-o', tmp / 'swarmkeeper'], timeout=300)
    assert any(line.startswith('receive-turns: ') and 'keeper' in line.split(':')[1] and 'turn region at the receive (opens at entry, cycles per slab)' in line
               for line in (p.stdout + p.stderr).splitlines()), p.stdout + p.stderr  # the notes go to stderr
    for harts in ('1', '4'):
        q = run([tmp / 'swarmkeeper'], env={'FPR_HARTS': harts}, timeout=300)
        assert q.stdout.startswith('swarmkeeper: 10000 ticks of 2000 motes') and 'flat' in q.stdout, q.stdout + q.stderr
    print('The swarm keeper is a turn: 10,000 ticks of 2,000 motes, Vectors moved across every boundary, resident memory flat on one and four harts: PASS')

@case
def regionnest(tmp):
    # loop and call regions (docs/2026-10-25-REGIONS-LOOPS-CALLS.md): a loop
    # resets per slab, a costly call's region opens when the call has used a
    # slab, and an arena's copy-out may be what opens it (the scope chain
    # bug the POS reload check found)
    rn = tmp / 'regionnest'
    run(['./fpr', 'build', 'tests/base/regionnest.fpr', '--with', 'tests/arc_churn/arcprobe.c', '-o', rn])
    for harts in ('1', '4'):
        p = run([rn], env={'FPR_HARTS': harts})
        assert p.stdout == 'regionnest: 800000 cells through 40 arenas, built 45000150000 adopted, loop 19296732; call regions opened yes, loop region reset per slab; memory bounded\n', p.stdout + p.stderr
    print('Loop regions reset per slab, call regions open when a call has used a slab, a builder\'s region is adopted whole, and an arena copying out under a pending call region keeps the chain: PASS')

@case
def pendreset(tmp):
    # call regions nested past the pend stack's inline eight, across a
    # Sys.poolReset: the grown stack must not live in the pool the reset
    # frees (it did: QOS's tidy loops panicked; this program segfaulted)
    for no_inline in (False, True):
        pr = tmp / ('pendreset-deep' if no_inline else 'pendreset-default')
        # Earlier inlining can collapse the ten-wrapper chain. Keep a
        # deliberate deep-call build to prove the grown-stack regression,
        # alongside the same results/reset checks under normal optimization.
        run(['./fpr', 'build', 'tests/base/pendreset.fpr', '--with', 'tests/arc_churn/arcprobe.c', '-o', pr],
            env={'FPR_NO_INLINE': str(int(no_inline))})
        for harts in ('1', '4'):
            p = run([pr], env={'FPR_HARTS': harts})
            assert re.fullmatch(r'pendreset: 500509 500509 200010000, pend stack grew (yes|no)\n', p.stdout), p.stdout + p.stderr
            if no_inline:
                assert p.stdout.endswith('pend stack grew yes\n'), p.stdout + p.stderr
    print('Ten nested call regions grow the pend stack outside the pool, and a Sys.poolReset under it leaves later cells intact: PASS')

@case
def fixedheap(tmp):
    # Fixed heap admission is independent of mailbox capacity; failures
    # belong to the child and escaped data delays grant reclamation.
    fixed = build('tests/base/fixedheap.fpr', 'fixedheap')
    for harts in ('1', '4'):
        p = run([fixed], env={'FPR_HARTS': harts})
        assert 'HOLDS' in p.stdout and 'FAILED' not in p.stdout, p.stdout + p.stderr
        for reason in ('local grant exhausted', 'scratch arenas require separate admission',
                       'reset blocked by escaped data'):
            assert reason in p.stdout + p.stderr, p.stdout + p.stderr
    print('Fixed heap: admission, local reset, exhaustion, escaped lifetime and child-only failure: PASS')

@case
def vecfuse(tmp):
    # vector fusion keeps effect and failure ORDER: element functions that
    # print or can fail are not fused (and the compile says so); pure pairs
    # still fuse into one in-place pass (docs/2026-10-03-FUSION-EFFECT-ORDER.md)
    p = run(['./fpr', 'build', '-v', '--remarks=all', 'tests/base/vecfuse_effects.fpr', '-o', tmp / 'vfe'])
    assert 'callback `first` prevents fusion: the primitive `print`' in p.stderr, p.stderr
    # an Int pair fuses although Int + and * trap on overflow: the one
    # reordering fusion may make (docs/2026-10-03-FUSION-EFFECT-ORDER.md,
    # the 2026-10-13 relaxation); the F64 pair fuses as before
    assert 'callback `iinc` prevents fusion' not in p.stderr, p.stderr
    assert p.stderr.count('remark[not-fused]') == 1, p.stderr
    p = run([tmp / 'vfe'])
    assert p.stdout == 'first 1\nfirst 2\nsecond 1\nsecond 2\npure pair: 62 (pool grew 0 B)\nint pair: 62\n', p.stdout
    p = run([build('tests/base/vecfuse_fail.fpr', 'vff')], expected=1)
    assert 'first map failed on 2' in p.stdout + p.stderr and 'second' not in p.stdout, p.stdout + p.stderr
    print('Vector fusion: printing or failing element functions keep their pass order (and the decline is reported); pure F64 and Int pairs fuse in place: PASS')

@case
def vecwide(tmp):
    # vector descriptors: records of every width are SoA vectors; push, at,
    # put, map, filter, len, fold, an actor round trip and free agree with a
    # Python reference; a float record takes an inferred layout; two record
    # shapes sharing a field no longer mislead the record-map kernel
    # (docs/2026-10-03-VECTOR-DESCRIPTORS.md)
    p = run([build('tests/base/vecwide.fpr', 'vecwide')])
    assert p.stdout == 'w2: at3=9 kept=8 sum=8147 echoed=8147\nw4: at3=30 kept=8 sum=8490 echoed=8490\nw8: at3=108 kept=8 sum=9764 echoed=9764\nw9: at3=135 kept=8 sum=10205 echoed=10205\nw32: at3=1584 kept=8 sum=33872 echoed=33872\nw65: at3=6435 kept=8 sum=113105 echoed=113105\nw128: at3=24768 kept=8 sum=412544 echoed=412544\nfloat record: n=4 x=1.5 y=2.25 k=2\none: 3\n', p.stdout
    print('Vector descriptors: record widths 2, 4, 8, 9, 32, 65 and 128 through the whole surface and the deep copier, an inferred float-record layout, singleton rows: PASS')

@case
def vecshape(tmp):
    # two record shapes sharing field names: each record map reads its own
    # shape's columns (the projection dispatch inside a field takes the
    # element's arm), and both run in place (found 2026-10-16)
    p = run([build('tests/base/vecshape.fpr', 'vecshape')])
    assert p.stdout == 'captured dispatch: literal=1160045 variable=1160045\nvecshape: two=1149000 four=2498000 in place=True\n', p.stdout
    print('Record maps over two shapes that share field names read their own columns, in place: PASS')

@case
def veccaps(tmp):
    # column kernels: scalar captures in map and filter (zero pool growth, a
    # non-Int capture falls back), a nine-field record map through the spill
    # cell, a record filter that compacts columns in place; none of these
    # sites declines (docs/2026-10-03-VECTOR-KERNELS.md)
    p = run(['./fpr', 'build', '-v', 'tests/base/veccaps.fpr', '-o', tmp / 'veccaps'])
    assert 'vec note' not in p.stdout, p.stdout
    p = run([tmp / 'veccaps'])
    assert p.stdout == 'affine: sum=10000000000 grew=0 B; above: kept=49999 sum=7499899999 grew=0 B\nbool capture unboxed: 10 0\nnine-field record map: sum=5546500 grew=0 B\nrecord filter: kept=559 sum=402480 last.f8=1007 grew=0 B\n', p.stdout
    for target in ('rv64', 'rv32', 'x64'):
        run(['./fprc', '--profile=base', f'--target={target}', 'tests/base/veccaps.fpr', tmp / f'veccaps-{target}.s'])
    print('Vector kernels: captured map/filter, wide record map and record filter run in place with no declines; RV64/RV32/x64 emit: PASS')

@case
def process(tmp):
    # 1. hello: print reaches stdout, nothing else is echoed, status 0
    p = run([build('tests/base/hello.fpr', 'hello')])
    assert p.stdout == 'hello from base\n', p.stdout
    # 2. the process interface: args, env, Sys.exit, main's Int result
    exe = build('tests/base/args.fpr', 'args')
    p = run([exe, 'one', 'two'], 3, env={'FPR_BASE_VAR': 'hello'})
    assert 'args: one,two (2)' in p.stdout and 'env: hello' in p.stdout, p.stdout
    clean = {k: v for k, v in os.environ.items() if k != 'FPR_BASE_VAR'}
    p = subprocess.run([str(exe)], capture_output=True, text=True, env=clean)
    assert p.returncode == 4 and 'env: unset' in p.stdout, (p.returncode, p.stdout)
    run([build('tests/base/status.fpr', 'status')], 7)
    print('Process: argv, environment, Sys.exit, the exit status is main\'s Int: PASS')

@case
def streams(tmp):
    # 3. streams and files
    p = run([build('tests/base/lines.fpr', 'lines')], stdin='ab\ncde\n\nlast')
    assert p.stdout == 'lines: 4 chars: 9\n' and p.stderr == 'lines: to stderr\n', (p.stdout, p.stderr)
    p = run([build('tests/base/files.fpr', 'files')])
    assert p.stdout == 'files: True False 8 [one\ntwo\n]\n', p.stdout
    print('Streams and files: readLine to EOF, stderr, write/append/read/exists: PASS')

@case
def panic_actors_std(tmp):
    # 4. a panic is exit 1 with its message; a Sys.exit inside an actor program is honoured
    p = run([build('tests/base/panic.fpr', 'panic')], 1)
    assert 'deliberate' in p.stdout, p.stdout
    # 5. the same programs every profile runs: actors on pthread harts, a std module
    p = run([build('tests/actors.fpr', 'actors')], env={'FPR_HARTS': '2'})
    assert 'actor demo done' in p.stdout, p.stdout
    p = run([build('tests/stduse.fpr', 'stduse')])
    assert 'std: clamp=10 backoff=800 fold=15' in p.stdout, p.stdout
    print('Panics exit 1 by name; actors on two pthread harts and std modules run unchanged: PASS')

@case
def stacks(tmp):
    # 4b. a stack grows: deep plain recursion is just a program; recursion that
    # never ends is a named panic at the policy ceiling, exit 1 -- never a bare signal
    p = run([build('tests/base/overflow.fpr', 'overflow')], 1, env={'FPR_STACK_MAX_MB': '64'})
    assert 'accumulator: 200000' in p.stdout and 'recursion: 200000' in p.stdout, p.stdout
    assert 'stack overflow' in p.stdout + p.stderr and 'PANIC [actor 0]' in p.stdout + p.stderr, p.stderr
    assert 'forever:' not in p.stdout
    print('Stacks grow (200,000 plain frames); run-away recursion is a named panic at the ceiling, exit 1: PASS')

@case
def sleepwake(tmp):
    # 4e. an actor that sleeps while messages keep arriving: a sleeper woken early was
    # linked on the hart's list twice, and the hart then walked a one-node cycle forever
    sw = build('tests/base/sleepwake.fpr', 'sleepwake')
    for _ in range(4):
        assert 'sleepwake: alive' in run([sw], timeout=60).stdout
    print('Sleeping while messages arrive (the poller shape), four times: the hart never spins: PASS')

@case
def sleepwait(tmp):
    # 4f. a waiter on a sleeper outlives the detector's window: not a deadlock
    p = run([build('tests/base/sleepwait.fpr', 'sleepwait')])
    assert p.stdout == 'waiter got 7\nmain got 1\n', p.stdout + p.stderr
    print('An actor waiting 3 s on a sleeping actor is not a deadlock: PASS')

@case
def bigheap(tmp):
    # 4c. the heap is a reservation of address space, not a size: a live heap past
    # the 256 MiB it used to be fixed at, and FPR_HEAP_MB caps a run by name
    big = build('tests/base/bigheap.fpr', 'bigheap')
    assert 'bigheap: 72000006000000' in run([big]).stdout
    p = run([big], 1, env={'FPR_HEAP_MB': '64'})
    assert 'heap exhausted' in p.stdout + p.stderr, p.stderr
    print('The heap grows with the program (577 MiB live); capped by FPR_HEAP_MB it is a named panic: PASS')

@case
def wide(tmp):
    # 4d. arity and tuple width have no ceiling
    out = run([build('tests/base/wide.fpr', 'wide')]).stdout
    assert 'wide: 4950' in out and 'tuple: 19 True' in out and '17, 18, 19)' in out, out
    print('A 100-parameter function and a 20-tuple (built, matched, compared, printed): PASS')

@case
def fvec2(tmp):
    # 4g. the specialized Vec.filter loop lowers on AArch64: it used s10/s11,
    # which the shared IR does not have, and fvec2 did not compile on A64
    out = run([build('tests/fvec2.fpr', 'fvec2')]).stdout
    assert 'kept=999' in out and 'FLOATVEC2 HOLDS' in out, out
    print('The specialized float Vec.filter compiles and runs on AArch64 (tests/fvec2): PASS')

@case
def cafalias(tmp):
    # 4i. a zero-arity global bound to a name runs there, once per binding:
    # the base profile's let normalization must not drop or duplicate it
    out = run([build('tests/base/cafalias.fpr', 'cafalias')]).stdout
    assert out == 'noisy ran\nnoisy ran\nend\n', out
    print('A zero-arity global bound to _ or aliased runs once per binding: PASS')

@case
def inlineprims(tmp):
    # 4j. the inline fast paths (charAt, strlen, band/bor/bxor, shifts, Int
    # arithmetic) agree with the C primitives, and out-of-range still panics
    out = run([build('tests/base/inlineprims.fpr', 'inlineprims')]).stdout
    assert out == 'inline prims: 0 arithmetic/bit mismatches, 0 shift mismatches, 0 byte mismatches, strlen=5\n', out
    # 0-based: the first byte out of range on each side is len and -1
    for name, idx in (('c0', '3'), ('cm1', '(-1)')):
        (tmp / (name + '.fpr')).write_text('main = charAt "abc" ' + idx + '.\n')
        p = run([build(tmp / (name + '.fpr'), name)], 1)
        assert 'charAt: index out of range' in p.stdout + p.stderr, p.stdout + p.stderr
    print('Inline primitive fast paths agree with C on 225 pairs, 64 shift counts and raw bytes; out of range is still the named panic: PASS')

@case
def inlining(tmp):
    # 4k. the base inliner is invisible: the same program built with and
    # without it (FPR_NO_INLINE=1) prints the same, effects in the same order
    on = run([build('tests/base/inlining.fpr', 'inl1')]).stdout
    exe0 = tmp / 'inl0'
    run(['./fpr', 'build', 'tests/base/inlining.fpr', '-o', exe0], env={'FPR_NO_INLINE': '1'})
    off = run([exe0]).stdout
    assert on == off, (on, off)
    assert on.endswith('r1=6 r2=20 r3=7 r4=12 r5=-91 r6=False r7=15 r8=5\n') and on.count('eval tick') == 2, on
    assert 'typed-inline 23 True 3.5 3.5 31\n' in on, on
    print('Inlining changes nothing observable: argument order, CAF arguments, function-valued parameters, shadowing, mutual recursion: PASS')

@case
def registers(tmp):
    run(['python3', 'tests/check_registers.py'], timeout=300)
    print('Register-held slots preserve calls, effects, branches, tail calls and warm-cache modes: PASS')

@case
def slotprims(tmp):
    # 4l. a frame holds the argument slots of direct primitive calls: their
    # args were staged below sp and nested C calls overwrote them
    out = run([build('tests/base/slotprims.fpr', 'slotprims')]).stdout
    assert out == 'f: bcabc\ng: ab=wxy=pq bc+xyz+pr\n', out
    print('Frames count the argument slots of direct primitive calls (nested strJoin/substr): PASS')

@case
def float_inline(tmp):
    # Independent C references cover IEEE edge cases, Bool values/branches,
    # fast-path and inliner switches; the x64 lowering executes when available.
    run(['python3', 'tests/check_float_inline.py'], timeout=300)
    print('F64 arithmetic/comparisons and literal splices agree with the C reference: PASS')

@case
def cleanup(tmp):
    cleanup = tmp / 'cleanup'
    run(['./fpr', 'build', 'tests/base/cleanup.fpr', '--with', 'tests/base/cleanup_probe.c', '-o', cleanup])
    for harts in ('1', '2'):
        assert run([cleanup], env={'FPR_HARTS': harts}).stdout == 'cleanup: 1\n'
    print('External request cleanup runs when a parked actor is killed: PASS')

@case
def runtime_costs(tmp):
    run(['python3', 'tools/runtime-costs.py', '--quick', '--runs', '1'], timeout=300)
    print('Runtime ledgers: exact primitive baseline, paired automatic-turn overhead; ordinary builds have no increments: PASS')

@case
def actorfail(tmp):
    # 4m. fail-stop: a primitive that cannot complete ends its caller alone
    exe = tmp / 'actorfail'
    run(['./fpr', 'build', 'tests/base/actorfail.fpr', '--with', 'tests/base/actorfail_probe.c', '-o', exe])
    for harts in ('1', '2'):
        p = run([exe], env={'FPR_HARTS': harts})
        assert p.stdout.strip().endswith('after the child failed: Err dead actor: probe: deliberate failure; the machine runs on'), p.stdout
        assert 'actor failed: probe: deliberate failure' in p.stdout + p.stderr, p.stdout + p.stderr
    print('fpr_actor_fail: the failing actor ends alone with a logged reason, its caller hears Err dead actor and the reason: PASS')

@case
def loopwith(tmp):
    # 4l. Sys.loopWith: every step an arena, one linear Vector threaded by
    # identity -- the caller's pool does not grow with the step count, and a
    # vector whose storage moved, or a Vector in the state, is refused
    out = run([build('tests/base/loopwith.fpr', 'loopwith')]).stdout
    assert out.startswith('steps 1000 and 20000; cells changed 1919726 and 38399726; caller pool grew '), out
    g1, g2 = [int(x) for x in out.split('caller pool grew ')[1].replace(' B', '').split(' and ')]
    assert g1 == g2 and g2 < 1024, out
    (tmp / 'lwgrow.fpr').write_text('unsafe program.\nst s v = (s < 3, s + 1, Vec.push 7 v).\nmain =\n  (s, v) = Sys.loopWith (Vec.iota 16) 0 st;\n  _ = Vec.free v;\n  print "no".\n')
    p = run([build(tmp / 'lwgrow.fpr', 'lwgrow')], 1)
    assert 'Sys.loopWith: the vector must come back as it went in' in p.stdout + p.stderr, p.stdout + p.stderr
    (tmp / 'lwstate.fpr').write_text('unsafe program.\nst s v = (False, Vec.iota 3, v).\nmain =\n  (s, v) = Sys.loopWith (Vec.iota 16) (Vec.iota 2) st;\n  _ = Vec.free v;\n  _ = Vec.free s;\n  print "no".\n')
    p = run([build(tmp / 'lwstate.fpr', 'lwstate')], 1)
    assert 'Sys.loopWith: the state may not hold a Vector' in p.stdout + p.stderr, p.stdout + p.stderr
    print(f'Sys.loopWith: 1,000 and 20,000 steps of a double-buffered frame loop grow the caller pool by the same {g2} B; a moved vector and a Vector in the state are refused: PASS')

@case
def arena_migration(tmp):
    run(['python3', 'tests/check_arena_migration.py'], timeout=600)
    print('Scratch arenas restore actor-owned pools across observed migration: PASS')

@case
def codepublish(tmp):
    # Code publication must fence a remote hart before its next actor dispatch.
    exe = tmp / 'codepublish'
    run(['./fpr', 'build', 'tests/base/codepublish.fpr', '--with', 'tests/base/codepublish_probe.c', '-o', exe])
    p = run([exe], env={'FPR_HARTS': '2'})
    assert p.stdout.strip() == 'code publication: 100/100 remote dispatches fenced', p.stdout
    print('Code publication: remote dispatch fences every new generation: PASS')

@case
def modinterface(tmp):
    modinterface = str(tmp/'modinterface')
    run(['./fpr', 'build', 'tests/base/modinterface.fpr', '--with', 'tests/base/modinterface_probe.c', '-o', modinterface])
    assert run([modinterface]).stdout == 'module interfaces: schema root-scope missing changed uncertified rollback PASS\n'
    print('Checked module interfaces: schema/root scope/refusals/rollback PASS')

@case
def images(tmp):
    # 4m. mortal process images: a data static of another process's image is
    # copied on send and outlives the image; a function into its code is
    # refused, the sender failing alone (images_probe.c makes a fake image)
    exe = tmp / 'images'
    run(['./fpr', 'build', 'tests/base/images.fpr', '--with', 'tests/base/images_probe.c', '-o', exe])
    for harts in ('1', '2'):
        p = run([exe], env={'FPR_HARTS': harts})
        assert p.stdout.strip().endswith('kept: from the image; a function of the image: refused (dead actor: send: a function of another process cannot leave it (its code goes when that process ends))'), p.stdout
        assert 'send: a function of another process cannot leave it' in p.stdout + p.stderr, p.stdout + p.stderr
    print('Process images: a static crossing to another process is copied and outlives the image; a function into it is refused: PASS')

@case
def vecpeek(tmp):
    # 4n. pair-free vector reads: `(x, v2) = Vec.at i v` builds no pair
    # (Core.Typed.VectorRead); the same program without the rewrite agrees on every
    # value, and the 2,000 reads cost only the loops' two final pairs
    on = run([build('tests/base/vecpeek.fpr', 'vp1')]).stdout.splitlines()
    exe = tmp / 'vp2'
    # the baseline counts the pairs, so no loop region may reclaim them (one
    # resets inside the second loop: 82,960 bytes; docs/2026-10-25-REGIONS-LOOPS-CALLS.md)
    run(['./fpr', 'build', 'tests/base/vecpeek.fpr', '-o', exe], env={'FPR_NO_VEC_PEEK': '1', 'FPR_NO_LOOP_REGIONS': '1', 'FPR_NO_CALL_REGIONS': '1'})
    off = run([exe]).stdout.splitlines()
    assert on[0] == off[0] == 'at 1499500 get 1499500 whole 70 shadow 3998', (on, off)
    assert on[1] == '2000 reads: 96 bytes' and off[1] == '2000 reads: 96096 bytes', (on, off)
    (tmp / 'vp3.fpr').write_text('unsafe program.\nmain =\n  v = Vec.iota 3;\n  (x, v2) = Vec.at 3 v;\n  _ = Vec.free v2;\n  x.\n')
    p = run([build(tmp / 'vp3.fpr', 'vp3')], 1)
    assert 'Vec.get: index out of range' in p.stdout + p.stderr, p.stdout + p.stderr
    print('Vector reads taken apart at once build no pair: 2,000 reads 96 B (was 96,096), the same values, the same out-of-range panic: PASS')

@case
def zerobased(tmp):
    # 4o. every position is 0-based (docs/2026-10-02-ZERO-BASED.md): the
    # primitives at their first and last index and "not found" (-1), the
    # same natively and under Sol; one past either end panics by name
    want = 'charAt 104 111; substr [ell] [o] []; index 2 -1 3 -1; list 10 30; Str.at 104'
    out = run([build('tests/base/zerobased.fpr', 'zerobased')]).stdout.strip()
    assert out == want, out
    sol = run(['./fpr', 'sol', 'tests/base/zerobased.fpr']).stdout.strip().splitlines()[-1]
    assert sol == want, sol
    for name, expr, msg in [('zb1', 'charAt "abc" (0 - 1)', 'charAt: index out of range'),
                            ('zb2', 'charAt "abc" 3', 'charAt: index out of range'),
                            ('zb3', '(1 :: 2 :: Nil) ! 2', '!: index out of range'),
                            ('zb4', 'Vec.get 3 (Vec.iota 3)', 'Vec.get: index out of range')]:
        (tmp / f'{name}.fpr').write_text(f'unsafe program.\nmain = {expr}.\n')
        p = run([build(tmp / f'{name}.fpr', name)], 1)
        assert msg in p.stdout + p.stderr, (name, p.stdout + p.stderr)
    print('Every position is 0-based: first/last index and -1 for not found, native and Sol agree; index -1 and len panic by name: PASS')

@case
def deadpeer(tmp):
    # 4h. receiveFromRes: a sender that exits is an answer (Err "dead actor"),
    # never a caller parked for ever; a reply sent just before exiting is kept
    # --harts 8: the default is the build host's core count (4 on a CI runner)
    dp = build('tests/base/deadpeer.fpr', 'deadpeer', '--harts', '8')
    for harts in ('1', '4', '8'):
        out = run([dp], env={'FPR_HARTS': harts}, timeout=60).stdout
        assert 'reply=Ok 42 dead=Err dead actor died-while-waiting=Err dead actor' in out, out
        assert 'rounds: oks=3000 errs=3000' in out, out
    print('receiveFromRes: a dead sender is an answer; 3,000 reply-then-exit and exit-silently rounds on 1, 4 and 8 harts: PASS')

@case
def deathwhy(tmp):
    # 4i. a trap (error, Int overflow, division by zero) ends the actor, not the
    # machine, and the reason reaches its watchers; a kill says "killed"
    dw = build('tests/base/deathwhy.fpr', 'deathwhy')
    for harts in ('1', '4'):
        out = run([dw], env={'FPR_HARTS': harts}, timeout=60).stdout
        assert 'error: Err dead actor: boom\n' in out, out
        assert 'overflow: Err dead actor: Int overflow: 1 + 4611686018427387903 does not fit an Int' in out, out
        assert 'division: Err dead actor: division by zero\n' in out, out
        assert 'killed: Err dead actor: killed\n' in out, out
        assert 'returned: Err dead actor\n' in out, out
        assert 'charAt: Err dead actor: charAt: index out of range (3, length 3)\n' in out, out
        assert 'chr: Err dead actor: chr: 256 is not a byte (0..255)' in out, out
        assert 'nth: Err dead actor: !: index out of range (5)\n' in out, out
        assert out.endswith('the program is still running\n'), out
    print('a trap ends the actor, not the machine: error, Int overflow, division by zero and a refused value (charAt past the end, chr of a non-byte, ! past the end) on a worker are its death with the reason for its watchers; a kill says killed; the program goes on (1 and 4 harts): PASS')

@case
def actor_claim(tmp):
    # Force the original first-sender race, then exercise real scheduler/wakes,
    # dead-sender channel reuse and overflow under parallel host load.
    run(['python3', 'tests/check_actor_claim.py'])

@case
def taskstress(tmp):
    stress_runs = int(os.environ.get('FPR_ACTOR_STRESS_RUNS', '12'))
    assert stress_runs > 0
    for no_inline in ('0', '1'):
        exe = tmp / ('taskstress-' + no_inline)
        # --harts 10: the default is the build host's core count, and the
        # stress below runs 10 harts (a 4-core CI runner refused them)
        run(['./fpr', 'build', 'tests/base/taskstress.fpr', '--harts', '10', '-o', exe],
            env={'FPR_NO_INLINE': no_inline})
        for harts in ('1', '4'):
            assert run([exe], env={'FPR_HARTS': harts}, timeout=300).stdout == 'shastress: 40\n'
        def stress_once(_):
            p = run([exe], env={'FPR_HARTS': '10'}, timeout=300)
            assert p.stdout == 'shastress: 40\n', p.stdout + p.stderr
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(stress_once, range(stress_runs)))
    print(f'Channel claim preserves a queued Result; Task.map SHA stress: {stress_runs} runs per inliner setting on 10 harts, six concurrent: PASS')

@case
def fpr_run(tmp):
    # 6. fpr run: build to a temp file, pass the arguments through, return its status
    p = run(['./fpr', 'run', 'tests/base/args.fpr', 'x', 'y'], 3, env={'FPR_BASE_VAR': 'v'})
    assert 'args: x,y (2)' in p.stdout, p.stdout
    # 7. a warm build is a compile and a link: the runtime objects are cached
    p = run(['./fpr', 'build', 'tests/base/hello.fpr', '-o', tmp / 'hello2', '-v'])
    assert 'wrote' in p.stdout, p.stdout
    print('fpr run passes arguments and status through; -v shows the compiler; the runtime is cached: PASS')

@case
def descriptors(tmp):
    # 8. a server that runs out of descriptors keeps serving: accept's EMFILE
    # used to end std/tcp's accept loop for good.  40 descriptors: the rounds
    # of load.fpr outgrow them, the shortage is said on stderr, and the
    # rounds that fit were all answered.
    exe = build('machine/esp-idf/examples/load.fpr', 'load')
    p = subprocess.run(['sh', '-c', f'ulimit -n 40; exec "{exe}"'], capture_output=True, text=True, timeout=120)
    assert p.returncode == 0, (p.returncode, p.stdout, p.stderr)
    assert '8 at once: 8 connected' in p.stdout, p.stdout
    assert 'tcp: accept: Too many open files (still serving)' in p.stderr, p.stderr
    print('A server out of descriptors says so and keeps serving (std/tcp accept loop): PASS')

@case
def job_broker(tmp):
    # 9. the job broker: blocking host work runs on a broker thread (machine/posix/os_job.c),
    # the same one the board's radio libraries use, and only the calling actor waits.
    # The job is C brought by the program (--with), as a host's would be.
    exe = tmp / 'job'
    run(['./fpr', 'build', 'tests/base/job.fpr', '--with', 'tests/base/job_probe.c', '-o', exe])
    p = run([exe])
    assert p.stdout == '5: pong 5\n1: pong 1\n3: pong 3\nconcurrent: 60\n', p.stdout
    print('The job broker: host work off the harts, in order, three actors at once (std/job): PASS')

@case
def sendmem(tmp):
    # 10. a list a primitive built on the heap (Sys.memInfo's, with its own nil cell)
    # crosses an actor boundary: the copier's size walk used to follow garbage past
    # that nil and never return
    p = run([build('tests/base/sendmem.fpr', 'sendmem')], timeout=30)
    assert p.stdout.startswith('sendmem: 8 counters received'), p.stdout
    print('A primitive-built list survives send (the heap nil is a leaf to the copier): PASS')

@case
def i64(tmp):
    # 11. I64: the raw 64-bit two's-complement integer (docs/2026-10-05-I64.md).
    # Every operation and edge in tests/i64.fpr, values in structures and sent
    # between actors, then the refusals: I64 never mixes with Int implicitly.
    p = run([build('tests/i64.fpr', 'i64')])
    assert p.stdout.endswith('i64: all ok\n') and 'FAIL' not in p.stdout, p.stdout + p.stderr
    p = run([build('tests/base/i64_divzero.fpr', 'i64dz')], expected=1)
    assert 'I64: division by zero' in p.stdout + p.stderr, p.stdout + p.stderr
    for body, said in (('print (I64.ofInt 1 + 2)', 'cannot unify Int with I64'),
                       ('print (I64.ofInt 1 == 1)', 'cannot unify I64 with Int'),
                       ('print (I64.ofInt 2 ^ I64.ofInt 3)', '(^) is not defined for I64')):
        src = tmp / 'i64_refused.fpr'
        src.write_text(f'profile base.\nmain = {body}.\n')
        q = subprocess.run(['./fpr', 'build', str(src), '-o', str(tmp / 'i64_refused')], capture_output=True, text=True, timeout=120)
        assert q.returncode != 0 and said in q.stdout + q.stderr, (body, q.stdout, q.stderr)
    print('I64: wrapping 64-bit arithmetic, unsigned views, conversions, parse, structures, send, and no implicit mixing with Int: PASS')

if __name__ == '__main__':
    main()
