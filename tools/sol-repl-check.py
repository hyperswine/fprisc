#!/usr/bin/env python3
"""REPL contract for the Sol script runner (`fpr sol --repl`).

docs/2026-10-29-SOL-REPL-DESIGN.md: one command, one transaction; the
accumulated program is the environment. Checked here: definition
persistence (including definitions over earlier definitions), per-command
commit visibility, panic and type-error isolation, multi-line
continuation with blank-line escape, redefinition refusal, and session
versus process-per-command latency.
"""
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()
ENV = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')} | {'SOL_GPU': '0'}


def session(lines, cwd):
    return subprocess.run([str(FPR), 'sol', '--repl'], input=''.join(lines),
                          capture_output=True, env=ENV, cwd=cwd, timeout=120,
                          text=True)


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-repl-') as tmp:
        work = Path(tmp)

        def check(name, lines, stdout, code=0, stderr_has=None):
            nonlocal count
            r = session(lines, work)
            assert r.returncode == code, (name, r.returncode, r.stderr[-400:])
            assert r.stdout == stdout, (name, r.stdout, stdout, r.stderr[-400:])
            if stderr_has is not None:
                assert stderr_has in r.stderr, (name, r.stderr[-400:])
            count += 1

        # definitions persist; later definitions build on earlier ones
        check('persist', ['inc x = x + 1.\n',
                          '> print "{inc 41}".\n',
                          'double x = inc (inc x).\n',
                          '> print "{double 10}".\n'], '42\n12\n')

        # each command's commit is visible to the next command
        target = work / 'committed.txt'
        check('per_command_commit',
              [f'> writePath "{target}" "saved".\n',
               f'> p = "{target}"; print "{{readPath p}}".\n'], 'saved\n')
        assert target.read_text() == 'saved'
        count += 1

        # a panic aborts only its command's transaction; the session continues
        check('panic_isolation',
              ['> parseInt "boom".\n',
               '> print "still alive".\n'], 'still alive\n',
              stderr_has='SOL PANIC: parseInt')

        # a type error rejects the line; the session (and later lines) continue
        check('type_error_isolation',
              ['broken = 1 + "x".\n',
               '> print "after".\n'], 'after\n', stderr_has='TYPE ERRORS')

        # a parse error rejects the line; nothing of it persists
        check('parse_error_isolation',
              ['> ).\n', '> print "ok".\n'], 'ok\n')

        # multi-line definitions continue until the '.' completes
        check('multiline_continuation',
              ['poly x =\n', '  x * 2.\n', '> print "{poly 21}".\n'], '42\n')

        # a blank line escapes a stuck continuation without touching the session
        check('blank_line_escape',
              ['stuck =\n', '\n', '> print "ok".\n'], 'ok\n',
              stderr_has='incomplete input discarded')

        # names are session-final: redefinition is refused, the original stays
        check('redefinition_refused',
              ['x = 5.\n', '> print "first {x}".\n', 'x = 6.\n',
               '> print "second {x}".\n'],
              'first 5\nsecond 5\n', stderr_has='already defined this session: x')

        # EOF after a clean session exits 0; the last command committed
        check('eof_exit', ['> print "bye".\n'], 'bye\n')

        # ---- latency: session commands vs process-per-command -----------
        lines = ['> print "tick".\n'] * 50

        t0 = time.monotonic()
        r = session(lines, work)
        session_ms = (time.monotonic() - t0) * 1000
        assert r.returncode == 0 and r.stdout == 'tick\n' * 50, r.stderr[-300:]
        count += 1

        # Baseline: each REPL line is NEW source, so compare against 50
        # distinct one-shot scripts (compile-cache misses). Re-running one
        # script would measure cache hits (~7 ms startup, no typecheck) —
        # the REPL bypasses that cache, so that baseline is not comparable.
        # docs/2026-10-29-SOL-REPL-LATENCY.md
        nonce = os.urandom(6).hex()  # never a cache hit from an earlier run
        scripts = []
        for i in range(50):
            s = work / f'tick{i}.sol'
            s.write_text(f'> print "tick {i} {nonce}".\n')
            scripts.append(s)
        t0 = time.monotonic()
        for s in scripts:
            subprocess.run([str(FPR), 'sol', str(s)], capture_output=True,
                           env=ENV, cwd=work, timeout=30)
        processes_ms = (time.monotonic() - t0) * 1000
        per_cmd_session = session_ms / 50
        per_cmd_process = processes_ms / 50
        print(f'repl latency (50 trivial commands): session {per_cmd_session:.2f} ms/command, '
              f'process-per-command (distinct, uncached) {per_cmd_process:.2f} ms/command '
              f'({per_cmd_process / per_cmd_session:.1f}x)')

        # responsive-session bar (human-perception threshold), and no worse
        # than spawning: per-command cost is dominated by whole-program
        # typecheck incl. the prelude (~30 ms); the commit itself is ~0.1 ms
        # (see the design record). Incremental compilation is the unlock.
        assert per_cmd_session < 50.0, per_cmd_session
        assert per_cmd_session <= per_cmd_process * 1.5, (per_cmd_session, per_cmd_process)

    print(f'sol repl contract: {count} checks passed')


if __name__ == '__main__':
    main()
