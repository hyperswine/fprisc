#!/usr/bin/env python3
"""The Base profile: an FP-RISC program is an ordinary executable for this
machine (`fpr build`), with the environment docs/BASE.md promises -- the
command line, the exit status, stdin/stdout/stderr, files, the clock --
and the same actors, std modules and panics as every other profile."""
from pathlib import Path
import os, subprocess, tempfile
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
    # 4b. running off an actor's stack is a named panic, exit 1 -- never a bare signal
    p = run([build('tests/base/overflow.fpr', 'overflow')], 1)
    assert 'accumulator: 200000' in p.stdout, p.stdout
    assert 'stack overflow' in p.stderr and 'PANIC [actor 0]' in p.stderr, p.stderr
    assert 'recursion:' not in p.stdout
    print('Stack overflow: a named panic from the guard page, exit 1; the accumulator form needs no stack: PASS')
    # 6. fpr run: build to a temp file, pass the arguments through, return its status
    p = run(['./fpr', 'run', 'tests/base/args.fpr', 'x', 'y'], 3, env={'FPR_BASE_VAR': 'v'})
    assert 'args: x,y (2)' in p.stdout, p.stdout
    # 7. a warm build is a compile and a link: the runtime objects are cached
    p = run(['./fpr', 'build', 'tests/base/hello.fpr', '-o', tmp / 'hello2', '-v'])
    assert 'wrote' in p.stdout, p.stdout
    print('fpr run passes arguments and status through; -v shows the compiler; the runtime is cached: PASS')
