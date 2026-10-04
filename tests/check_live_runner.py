#!/usr/bin/env python3
"""Interactive input, declarative host bindings, rollback and checked cold restart."""
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'


def command(args, cwd, ok=True):
    p = subprocess.run([FPR, *args], cwd=cwd, capture_output=True, text=True, timeout=180)
    assert (p.returncode == 0) == ok, p.stdout + p.stderr


def wait_for(predicate, proc, log):
    import time
    until = time.monotonic() + 90
    while time.monotonic() < until:
        if predicate():
            return
        assert proc.poll() is None, log.read_text()
        time.sleep(.1)
    raise AssertionError(log.read_text())


def send(proc, text):
    proc.stdin.write(text)
    proc.stdin.flush()


for harts in ('1', '4'):
    with tempfile.TemporaryDirectory(prefix='interactive reload-') as tmp:
        d = Path(tmp)
        module = d / 'math.fpr'
        module.write_text((ROOT / 'examples/livereload/math.fpr').read_text())
        source = (ROOT / 'examples/livereload/interactive.fpr').read_text()
        source = source.replace('bindings table =', 'bindings table =\n  _ = print "bindings: tables={Mod.plugs 0}";\n  case O.readFile "deny-binding" of\n    Ok text -> Err "binding injection"\n  | Err why -> exported table.\nexported table =', 1)
        app = d / 'interactive.fpr'
        app.write_text(source)
        command(['commit', 'math.fpr'], d)
        log = d / 'watch.log'
        with log.open('w') as output:
            proc = subprocess.Popen([FPR, 'watch', 'interactive.fpr', '--module', 'math', '--restart-on-change'],
                                    cwd=d, env={**os.environ, 'FPR_HARTS': harts},
                                    stdin=subprocess.PIPE, stdout=output, stderr=output, text=True)
            try:
                wait_for(lambda: 'step=2 total=0' in log.read_text(), proc, log)
                initial_pid = int(re.findall(r'watch: app pid=(\d+)', log.read_text())[0])
                send(proc, '+\n')
                wait_for(lambda: 'added: step=2 total=2' in log.read_text(), proc, log)
                # The app waits for user input without blocking a one-hart reload.
                (d / 'deny-binding').write_text('refuse candidate environment\n')
                module.write_text('mathOp : Int -> Int .\nmathOp value = value * 3.\n')
                command(['commit', 'math.fpr'], d)
                wait_for(lambda: 'refused: binding injection' in log.read_text(), proc, log)
                (d / 'deny-binding').unlink()
                module.write_text('mathOp : Int -> Int .\nmathOp value = value * 4.\n')
                command(['commit', 'math.fpr'], d)
                wait_for(lambda: 'step=4 total=2' in log.read_text(), proc, log)
                counts = list(map(int, re.findall(r'bindings: tables=(\d+)', log.read_text())))
                assert len(counts) == 3 and counts[1] == counts[2] == counts[0] + 1, counts
                send(proc, '+\n')
                wait_for(lambda: 'added: step=4 total=6' in log.read_text(), proc, log)
                assert re.findall(r'watch: app pid=(\d+)', log.read_text()) == [str(initial_pid)]
                # An invalid root edit cannot stop the working process.
                app.write_text('main = missing Unit.\n')
                wait_for(lambda: 'app rebuild refused' in log.read_text(), proc, log)
                send(proc, '+\n')
                wait_for(lambda: 'added: step=4 total=10' in log.read_text(), proc, log)
                assert re.findall(r'watch: app pid=(\d+)', log.read_text()) == [str(initial_pid)]
                # Major module changes stay refused until a checked new app opts in.
                module.write_text('mathOp : String -> Int .\nmathOp value = strlen value.\n')
                command(['commit', 'math.fpr', '--major'], d)
                wait_for(lambda: 'refused: reload: incompatible' in log.read_text(), proc, log)
                new_source = source.replace('Ok op -> Ok {op = op}', 'Ok op -> Ok {op = stringOp op}')
                new_source += '\nstringOp op value = op "{value}".\n'
                app.write_text(new_source)
                wait_for(lambda: 'step=1 total=0' in log.read_text(), proc, log)
                pids = re.findall(r'watch: app pid=(\d+)', log.read_text())
                assert len(pids) == 2 and pids[0] != pids[1], pids
                try:
                    os.kill(initial_pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError('old app survived checked restart')
                send(proc, '+\n')
                wait_for(lambda: 'added: step=1 total=1' in log.read_text(), proc, log)
                send(proc, 'q\n')
                proc.wait(timeout=20)
                assert proc.returncode == 0 and 'calculator: total=1 refused=0' in log.read_text(), log.read_text()
                assert not list((d / '.fpr').glob('.watch-app*'))
                assert not list((d / '.fpr').glob('.watch-restart*'))
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=20)
                proc.stdin.close()
        print(f'Live runner: {harts} hart(s), interactive input, binding rollback, compatible state retention, invalid root refusal, checked cold restart PASS')

# Startup binding failure removes its table; a missing export is a Result error.
with tempfile.TemporaryDirectory(prefix='live binding refusal-') as tmp:
    d = Path(tmp)
    (d / 'math.fpr').write_text((ROOT / 'examples/livereload/math.fpr').read_text())
    command(['publish', 'math.fpr'], d)
    journal = next((d / '.fpr').glob('publications.*.tsv'))
    probe = d / 'probe.fpr'
    probe.write_text('''unsafe base.
Live = use "std/livereload".
bindings : Int -> Result {op : Int -> Int} String .
bindings table = case Live.function table "missing" of
    Err why -> Err why
  | Ok op -> Ok {op = op}.
main =
  before = Mod.plugs 0;
  result = Live.open {name = "math", bind = bindings};
  _ = case result of Err why -> print why | Ok env -> error "missing export accepted";
  _ = case Mod.plugs 0 == before of True -> Unit | False -> error "initial binding leaked table";
  print "initial binding rollback PASS".
''')
    command(['build', str(probe), '-o', str(d / 'probe')], d)
    result = subprocess.run([d / 'probe'], cwd=d, env={**os.environ, 'FPR_RELOAD_JOURNAL': str(journal)},
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0 and 'reload: missing export missing' in result.stdout and 'initial binding rollback PASS' in result.stdout, result.stdout + result.stderr
print('Live runner startup: missing export refuses binding and removes initial table PASS')
