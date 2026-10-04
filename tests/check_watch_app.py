#!/usr/bin/env python3
"""A supervised MVU stays alive while plain store commits become publications."""
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'


def command(args, cwd, ok=True, env=None):
    result = subprocess.run([str(FPR), *args], cwd=cwd, env=env,
                            capture_output=True, text=True, timeout=180)
    assert (result.returncode == 0) == ok, result.stdout + result.stderr
    return result


def wait_for(predicate, proc, log):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if predicate():
            return
        assert proc.poll() is None, log.read_text()
        time.sleep(.1)
    raise AssertionError('watch app timeout: ' + log.read_text())


for harts in ('1', '4'):
    with tempfile.TemporaryDirectory(prefix='fpr watch app space-') as tmp:
        workspace = Path(tmp)
        module = workspace / 'math.fpr'
        module.write_text('mathOp : Int -> Int .\nmathOp value = value * 2.\n')
        (workspace / 'app.fpr').write_text((ROOT / 'examples/livereload/app.fpr').read_text())
        command(['commit', str(module)], workspace)
        log = workspace / 'watch.log'
        compiler = workspace / 'cc-wrapper'
        compiler.write_text('#!/bin/sh\nfor arg in "$@"; do\n  if [ "$arg" = "-dynamiclib" ] || [ "$arg" = "-shared" ]; then\n    if [ -f fail-link ]; then exit 1; fi\n  fi\ndone\nexec cc "$@"\n')
        compiler.chmod(0o755)
        env = {**os.environ, 'FPR_HARTS': harts, 'FPR_CC': str(compiler)}
        with log.open('w') as output:
            proc = subprocess.Popen([FPR, 'watch', 'app.fpr', '--module', 'math'],
                                    cwd=workspace, env=env, stdout=output, stderr=output)
            try:
                wait_for(lambda: 'live: factor=2' in log.read_text(), proc, log)
                journal = next((workspace / '.fpr').glob('publications.*.tsv'))
                initial = journal.read_bytes()
                before = int(re.findall(r'live: factor=2 acc=(\d+)', log.read_text())[-1])
                # A scratch save alone is not a committed store subscription.
                module.write_text('mathOp value = missing value.\n')
                command(['commit', str(module)], workspace, ok=False)
                time.sleep(.7)
                assert journal.read_bytes() == initial
                assert proc.poll() is None
                # The ordinary workflow needs no major override or scratch watcher.
                module.write_text('mathOp : Int -> Int .\nmathOp value = value * 3.\n')
                command(['commit', str(module)], workspace)
                wait_for(lambda: 'live: factor=3' in log.read_text(), proc, log)
                first_adopted = int(re.findall(r'live: factor=3 acc=(\d+)', log.read_text())[0])
                assert first_adopted > before, log.read_text()
                assert journal.read_text().count('\n') == 2
                # Explicit major commit reaches the runtime, which refuses it.
                module.write_text('mathOp : String -> Int .\nmathOp value = strlen value.\n')
                command(['commit', str(module), '--major'], workspace)
                wait_for(lambda: 'refused:' in log.read_text(), proc, log)
                assert 'factor=4' not in log.read_text()
                # Failed host build advertises no image; same binding retries.
                (workspace / 'fail-link').write_text('inject link refusal\n')
                module.write_text('mathOp : Int -> Int .\nmathOp value = value * 4.\n')
                command(['commit', str(module), '--major'], workspace)
                wait_for(lambda: 'retrying committed version' in log.read_text(), proc, log)
                assert journal.read_text().count('\n') == 3
                assert 'live: factor=4' not in log.read_text()
                (workspace / 'fail-link').unlink()
                wait_for(lambda: 'live: factor=4' in log.read_text(), proc, log)
                after = int(re.findall(r'live: factor=4 acc=(\d+)', log.read_text())[0])
                assert after > first_adopted, log.read_text()
                assert 'old=20' in log.read_text()
                assert journal.read_text().count('\n') == 4
                (workspace / 'stop').write_text('quit\n')
                proc.wait(timeout=20)
                assert proc.returncode == 0, log.read_text()
                assert 'finished:' in log.read_text() and 'refused=1' in log.read_text()
                ticks = [tuple(map(int, match)) for match in
                         re.findall(r'live: factor=(\d+) acc=(\d+) old=(\d+)', log.read_text())]
                assert ticks and ticks[0] == (2, 9, 20), ticks
                assert all(old == 20 for factor, acc, old in ticks), ticks
                assert all(current[1] == previous[1] + current[0]
                           for previous, current in zip(ticks, ticks[1:])), ticks
                assert not list((workspace / '.fpr').glob('.watch-app*'))
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=20)
        print(f'Watch app: {harts} hart(s), store commit -> publication -> live MVU, refusal/recovery/state/old closure/exit PASS')

# Stopping the supervisor must not leave its still-running application behind.
with tempfile.TemporaryDirectory(prefix='watch termination-') as tmp:
    workspace = Path(tmp)
    (workspace / 'math.fpr').write_text((ROOT / 'examples/livereload/math.fpr').read_text())
    (workspace / 'app.fpr').write_text((ROOT / 'examples/livereload/app.fpr').read_text())
    command(['commit', 'math.fpr'], workspace)
    log = workspace / 'watch.log'
    with log.open('w') as output:
        proc = subprocess.Popen([FPR, 'watch', 'app.fpr', '--module', 'math'],
                                cwd=workspace, stdout=output, stderr=output)
        try:
            wait_for(lambda: 'live: factor=2' in log.read_text(), proc, log)
            app_pid = int(re.search(r'watch: app pid=(\d+)', log.read_text())[1])
        finally:
            proc.terminate()
            proc.wait(timeout=20)
    try:
        os.kill(app_pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError('supervised application survived termination')
    assert not list((workspace / '.fpr').glob('.watch-app*'))
print('Watch app termination: application reaped and temporary executable removed PASS')

with tempfile.TemporaryDirectory(prefix='watch startup refusal-') as tmp:
    workspace = Path(tmp)
    (workspace / 'math.fpr').write_text((ROOT / 'examples/livereload/math.fpr').read_text())
    (workspace / 'broken.fpr').write_text('main = missing Unit.\n')
    command(['commit', 'math.fpr'], workspace)
    missing = command(['watch', 'broken.fpr', '--module', 'absent'], workspace, ok=False)
    assert 'no committed binding' in missing.stderr
    command(['watch', 'broken.fpr', '--module', 'math'], workspace, ok=False)
    assert not list((workspace / '.fpr').glob('.watch-app*'))
    assert not (workspace / '.fpr/publication.lock').exists()
print('Watch app startup: missing subscription and invalid app refused without temporary executable/lock leaks PASS')
