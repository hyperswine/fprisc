#!/usr/bin/env python3
"""The Base profile: an FP-RISC program is an ordinary executable for this
machine (`fpr build`), with the environment docs/2026-09-18-BASE.md promises -- the
command line, the exit status, stdin/stdout/stderr, files, the clock --
and the same actors, std modules and panics as every other profile."""
from pathlib import Path
import os, subprocess, tempfile
from concurrent.futures import ThreadPoolExecutor
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
def run(args, expected=0, timeout=120, stdin=None, env=None):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout, input=stdin,
                       env=None if env is None else {**os.environ, **env})
    if p.returncode != expected:
        raise AssertionError(f'{args}: exit {p.returncode}, expected {expected}\n{p.stdout}\n{p.stderr}')
    return p
run(['make', 'fpr'], timeout=300)
with tempfile.TemporaryDirectory(prefix='fpr-base-') as temp:
    tmp = Path(temp)
    def build(prog, name):
        exe = tmp / name
        out = run(['./fpr', 'build', prog, '-o', exe])
        assert 'precond' not in out.stdout, 'a build is quiet unless -v'
        return exe
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
    # 3. streams and files
    p = run([build('tests/base/lines.fpr', 'lines')], stdin='ab\ncde\n\nlast')
    assert p.stdout == 'lines: 4 chars: 9\n' and p.stderr == 'lines: to stderr\n', (p.stdout, p.stderr)
    p = run([build('tests/base/files.fpr', 'files')])
    assert p.stdout == 'files: True False 8 [one\ntwo\n]\n', p.stdout
    print('Streams and files: readLine to EOF, stderr, write/append/read/exists: PASS')
    # 4. a panic is exit 1 with its message; a Sys.exit inside an actor program is honoured
    p = run([build('tests/base/panic.fpr', 'panic')], 1)
    assert 'deliberate' in p.stdout, p.stdout
    # 5. the same programs every profile runs: actors on pthread harts, a std module
    p = run([build('tests/actors.fpr', 'actors')], env={'FPR_HARTS': '2'})
    assert 'actor demo done' in p.stdout, p.stdout
    p = run([build('tests/stduse.fpr', 'stduse')])
    assert 'std: clamp=10 backoff=800 fold=15' in p.stdout, p.stdout
    print('Panics exit 1 by name; actors on two pthread harts and std modules run unchanged: PASS')
    # 4b. a stack grows: deep plain recursion is just a program; recursion that
    # never ends is a named panic at the policy ceiling, exit 1 -- never a bare signal
    p = run([build('tests/base/overflow.fpr', 'overflow')], 1, env={'FPR_STACK_MAX_MB': '64'})
    assert 'accumulator: 200000' in p.stdout and 'recursion: 200000' in p.stdout, p.stdout
    assert 'stack overflow' in p.stdout + p.stderr and 'PANIC [actor 0]' in p.stdout + p.stderr, p.stderr
    assert 'forever:' not in p.stdout
    print('Stacks grow (200,000 plain frames); run-away recursion is a named panic at the ceiling, exit 1: PASS')
    # 4e. an actor that sleeps while messages keep arriving: a sleeper woken early was
    # linked on the hart's list twice, and the hart then walked a one-node cycle forever
    sw = build('tests/base/sleepwake.fpr', 'sleepwake')
    for _ in range(4):
        assert 'sleepwake: alive' in run([sw], timeout=60).stdout
    print('Sleeping while messages arrive (the poller shape), four times: the hart never spins: PASS')
    # 4f. a waiter on a sleeper outlives the detector's window: not a deadlock
    p = run([build('tests/base/sleepwait.fpr', 'sleepwait')])
    assert p.stdout == 'waiter got 7\nmain got 1\n', p.stdout + p.stderr
    print('An actor waiting 3 s on a sleeping actor is not a deadlock: PASS')
    # 4c. the heap is a reservation of address space, not a size: a live heap past
    # the 256 MiB it used to be fixed at, and FPR_HEAP_MB caps a run by name
    big = build('tests/base/bigheap.fpr', 'bigheap')
    assert 'bigheap: 72000006000000' in run([big]).stdout
    p = run([big], 1, env={'FPR_HEAP_MB': '64'})
    assert 'heap exhausted' in p.stdout + p.stderr, p.stderr
    print('The heap grows with the program (577 MiB live); capped by FPR_HEAP_MB it is a named panic: PASS')
    # 4d. arity and tuple width have no ceiling
    out = run([build('tests/base/wide.fpr', 'wide')]).stdout
    assert 'wide: 4950' in out and 'tuple: 19 True' in out and '17, 18, 19)' in out, out
    print('A 100-parameter function and a 20-tuple (built, matched, compared, printed): PASS')
    # 4g. the specialized Vec.filter loop lowers on AArch64: it used s10/s11,
    # which the shared IR does not have, and fvec2 did not compile on A64
    out = run([build('tests/fvec2.fpr', 'fvec2')]).stdout
    assert 'kept=999' in out and 'FLOATVEC2 HOLDS' in out, out
    print('The specialized float Vec.filter compiles and runs on AArch64 (tests/fvec2): PASS')
    # 4i. a zero-arity global bound to a name runs there, once per binding:
    # the base profile's let normalization must not drop or duplicate it
    out = run([build('tests/base/cafalias.fpr', 'cafalias')]).stdout
    assert out == 'noisy ran\nnoisy ran\nend\n', out
    print('A zero-arity global bound to _ or aliased runs once per binding: PASS')
    # 4j. the inline fast paths (charAt, strlen, band/bor/bxor, shifts, Int
    # arithmetic) agree with the C primitives, and out-of-range still panics
    out = run([build('tests/base/inlineprims.fpr', 'inlineprims')]).stdout
    assert out == 'inline prims: 0 arithmetic/bit mismatches, 0 shift mismatches, 0 byte mismatches, strlen=5\n', out
    (tmp / 'c0.fpr').write_text('main = charAt "abc" 0.\n')
    p = run([build(tmp / 'c0.fpr', 'c0')], 1)
    assert 'charAt: index out of range' in p.stdout + p.stderr, p.stdout + p.stderr
    print('Inline primitive fast paths agree with C on 225 pairs, 64 shift counts and raw bytes; out of range is still the named panic: PASS')
    # 4k. the base inliner is invisible: the same program built with and
    # without it (FPR_NO_INLINE=1) prints the same, effects in the same order
    on = run([build('tests/base/inlining.fpr', 'inl1')]).stdout
    exe0 = tmp / 'inl0'
    run(['./fpr', 'build', 'tests/base/inlining.fpr', '-o', exe0], env={'FPR_NO_INLINE': '1'})
    off = run([exe0]).stdout
    assert on == off, (on, off)
    assert on.endswith('r1=6 r2=20 r3=7 r4=12 r5=-91 r6=False r7=15 r8=5\n') and on.count('eval tick') == 2, on
    print('Inlining changes nothing observable: argument order, CAF arguments, function-valued parameters, shadowing, mutual recursion: PASS')
    run(['python3', 'tests/check_registers.py'], timeout=300)
    print('Register-held slots preserve calls, effects, branches, tail calls and warm-cache modes: PASS')
    # 4l. a frame holds the argument slots of direct primitive calls: their
    # args were staged below sp and nested C calls overwrote them
    out = run([build('tests/base/slotprims.fpr', 'slotprims')]).stdout
    assert out == 'f: bcabc\ng: ab=wxy=pq bc+xyz+pr\n', out
    print('Frames count the argument slots of direct primitive calls (nested strJoin/substr): PASS')
    # Independent C references cover IEEE edge cases, Bool values/branches,
    # fast-path and inliner switches; the x64 lowering executes when available.
    run(['python3', 'tests/check_float_inline.py'], timeout=300)
    print('F64 arithmetic/comparisons and literal splices agree with the C reference: PASS')
    cleanup = tmp / 'cleanup'
    run(['./fpr', 'build', 'tests/base/cleanup.fpr', '--with', 'tests/base/cleanup_probe.c', '-o', cleanup])
    for harts in ('1', '2'):
        assert run([cleanup], env={'FPR_HARTS': harts}).stdout == 'cleanup: 1\n'
    print('External request cleanup runs when a parked actor is killed: PASS')
    run(['python3', 'tools/runtime-costs.py', '--quick', '--runs', '1'], timeout=300)
    print('Opt-in allocation/copy ledgers match exact workloads; ordinary builds have no increments: PASS')
    # 4h. receiveFromRes: a sender that exits is an answer (Err "dead actor"),
    # never a caller parked for ever; a reply sent just before exiting is kept
    dp = build('tests/base/deadpeer.fpr', 'deadpeer')
    for harts in ('1', '4', '8'):
        out = run([dp], env={'FPR_HARTS': harts}, timeout=60).stdout
        assert 'reply=Ok 42 dead=Err dead actor died-while-waiting=Err dead actor' in out, out
        assert 'rounds: oks=3000 errs=3000' in out, out
    print('receiveFromRes: a dead sender is an answer; 3,000 reply-then-exit and exit-silently rounds on 1, 4 and 8 harts: PASS')
    # Force the original first-sender race, then exercise real scheduler/wakes,
    # dead-sender channel reuse and overflow under parallel host load.
    run(['python3', 'tests/check_actor_claim.py'])
    stress_runs = int(os.environ.get('FPR_ACTOR_STRESS_RUNS', '12'))
    assert stress_runs > 0
    for no_inline in ('0', '1'):
        exe = tmp / ('taskstress-' + no_inline)
        run(['./fpr', 'build', 'tests/base/taskstress.fpr', '-o', exe],
            env={'FPR_NO_INLINE': no_inline})
        for harts in ('1', '4'):
            assert run([exe], env={'FPR_HARTS': harts}, timeout=300).stdout == 'shastress: 40\n'
        def stress_once(_):
            p = run([exe], env={'FPR_HARTS': '10'}, timeout=300)
            assert p.stdout == 'shastress: 40\n', p.stdout + p.stderr
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(stress_once, range(stress_runs)))
    print(f'Channel claim preserves a queued Result; Task.map SHA stress: {stress_runs} runs per inliner setting on 10 harts, six concurrent: PASS')
    # 6. fpr run: build to a temp file, pass the arguments through, return its status
    p = run(['./fpr', 'run', 'tests/base/args.fpr', 'x', 'y'], 3, env={'FPR_BASE_VAR': 'v'})
    assert 'args: x,y (2)' in p.stdout, p.stdout
    # 7. a warm build is a compile and a link: the runtime objects are cached
    p = run(['./fpr', 'build', 'tests/base/hello.fpr', '-o', tmp / 'hello2', '-v'])
    assert 'wrote' in p.stdout, p.stdout
    print('fpr run passes arguments and status through; -v shows the compiler; the runtime is cached: PASS')
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
    # 9. the job broker: blocking host work runs on a broker thread (machine/posix/os_job.c),
    # the same one the board's radio libraries use, and only the calling actor waits.
    # The job is C brought by the program (--with), as a host's would be.
    exe = tmp / 'job'
    run(['./fpr', 'build', 'tests/base/job.fpr', '--with', 'tests/base/job_probe.c', '-o', exe])
    p = run([exe])
    assert p.stdout == '5: pong 5\n1: pong 1\n3: pong 3\nconcurrent: 60\n', p.stdout
    print('The job broker: host work off the harts, in order, three actors at once (std/job): PASS')
    # 10. a list a primitive built on the heap (Sys.memInfo's, with its own nil cell)
    # crosses an actor boundary: the copier's size walk used to follow garbage past
    # that nil and never return
    p = run([build('tests/base/sendmem.fpr', 'sendmem')], timeout=30)
    assert p.stdout.startswith('sendmem: 8 counters received'), p.stdout
    print('A primitive-built list survives send (the heap nil is a leaf to the copier): PASS')
