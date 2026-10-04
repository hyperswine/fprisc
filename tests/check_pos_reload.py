#!/usr/bin/env python3
"""Real browser POS: keep two register sockets and carts across pricing commits."""
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path
from check_live_wire import Client, has

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'


def command(args, cwd, ok=True):
    p = subprocess.run([FPR, *args], cwd=cwd, capture_output=True, text=True, timeout=180)
    assert (p.returncode == 0) == ok, p.stdout + p.stderr


def wait_for(predicate, proc, log):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if predicate():
            return
        assert proc.poll() is None, log.read_text()
        time.sleep(.1)
    raise AssertionError(log.read_text()[-6000:])


def html(client):
    return ''.join(s + (client.state['d'][i] if i < len(client.state['d']) else '')
                   for i, s in enumerate(client.state['s']))


def mirror(client, quantities):
    client.send('ClientState', json.dumps({'tab': '1', **quantities}))


with tempfile.TemporaryDirectory(prefix='reload notice-') as tmp:
    exe = Path(tmp) / 'notice'
    command(['build', str(ROOT / 'tests/livenotice.fpr'), '-o', str(exe)], ROOT)
    result = subprocess.run([exe], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    print(result.stdout, end='')

for harts in ('1', '4'):
    notices = harts == '1'

    with tempfile.TemporaryDirectory(prefix='real POS reload-') as tmp:
        d = Path(tmp)
        module = d / 'pos1_pricing.fpr'
        module.write_text((ROOT / 'examples/pos1_pricing.fpr').read_text())
        (d / 'pos1.fpr').write_text((ROOT / 'examples/pos1.fpr').read_text())
        command(['commit', str(module)], d)
        log = d / 'server.log'
        receipt_log = d / 'receipts.log'
        clients = []
        with log.open('w') as output:
            proc = subprocess.Popen([FPR, 'watch', 'pos1.fpr', '--module', 'pos1_pricing'], cwd=d,
                                    env={**os.environ, 'FPR_HARTS': harts, 'POS1_PORT': '0',
                                         'POS1_STORE': str(receipt_log), 'POS1_VIEW_VERIFY': '1',
                                         **({'POS1_RELOAD_NOTICE': 'true'} if notices else {})},
                                    stdout=output, stderr=output)
            try:
                wait_for(lambda: re.search(r'ready (\d+)', log.read_text()), proc, log)
                port = int(re.search(r'ready (\d+)', log.read_text())[1])
                a = Client(port, 3); b = Client(port, False); clients = [a, b]
                assert not any(has(c.state, 'Live Reload new') for c in clients), 'startup is not adoption'
                a.send('Login', 'ana|1234'); a.until(lambda st: has(st, 'standard pricing'))
                b.send('Login', 'ben|2222'); b.until(lambda st: has(st, 'standard pricing'))
                mirror(a, {'q_FW': '1'})
                a.send('Card')
                a.until(lambda st: has(st, 'receipt #1 for 5.50'))
                # Keep both cashiers logged in with their own mirrored carts.
                mirror(a, {'q_FW': '2'}); mirror(b, {'q_BR': '1'})
                assert len(re.findall(r'^sale ', receipt_log.read_text(), re.M)) == 1
                initial = receipt_log.read_bytes()
                original_sockets = (a.s.fileno(), b.s.fileno())
                journal = next((d / '.fpr').glob('publications.*.tsv'))
                old_journal = journal.read_bytes()
                module.write_text('rate configured = missing configured.\nlabel unit = "invalid".\n')
                command(['commit', str(module)], d, ok=False)
                time.sleep(.7)
                assert journal.read_bytes() == old_journal
                assert receipt_log.read_bytes() == initial
                module.write_text('rate : Int -> Int .\nrate configured = configured * 2.\nlabel : Unit -> String .\nlabel unit = "double pricing".\n')
                command(['commit', str(module)], d)
                for c in clients:
                    c.until(lambda st: has(st, 'double pricing'))
                    assert 'data-tax="2000"' in html(c), html(c)[-2000:]
                assert receipt_log.read_bytes() == initial, 'adoption changed committed receipts'
                adopted_hash = re.search(r'pricing adopted: double pricing#([0-9a-f]+)', log.read_text())[1]
                for c in clients:
                    notice = next((v for v in c.state['d'] if v.startswith('Live Reload new ')), '')
                    if notices:
                        assert re.fullmatch(r'Live Reload new pos1_pricing#' + adopted_hash +
                                           r' \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', notice), notice
                        c.send('NoticeTick')  # external messages cannot expire server-owned status
                    else:
                        assert notice == '', notice
                if notices:
                    begun = time.monotonic()
                    shape = list(a.state['s'])
                    for c in clients: c.until(lambda st: not has(st, 'Live Reload new'))
                    assert time.monotonic() - begun >= 1.5, 'notice disappeared early'
                    assert a.state['s'] == shape, 'expiry reshaped the page'

                # No client state is resent: checkout must use the retained carts.
                a.send('Card'); a.until(lambda st: has(st, 'receipt #2 for 12.00'))
                b.send('Card'); b.until(lambda st: has(st, 'receipt #3 for 7.20'))
                sales = [l.split() for l in receipt_log.read_text().splitlines() if l.startswith('sale ')]
                assert [int(l[6]) for l in sales] == [550, 1200, 720], sales
                assert [int(l[7]) for l in sales] == [50, 200, 120], sales
                assert [l[2] for l in sales] == ['ana', 'ana', 'ben'], sales
                # Explicit incompatible major version is refused while sockets live.
                module.write_text('rate : String -> Int .\nrate configured = strlen configured.\nlabel : Unit -> String .\nlabel unit = "incompatible pricing".\n')
                command(['commit', str(module), '--major'], d)
                wait_for(lambda: 'pricing refused: reload: incompatible' in log.read_text(), proc, log)
                # Force a projection update so both sockets observe the refused state.
                a.send('Theme')
                for c in clients:
                    c.until(lambda st: ' day' not in html(c))
                    assert has(c.state, 'double pricing') and not has(c.state, 'Live Reload new')
                    assert not has(c.state, 'incompatible pricing')

                module.write_text('rate : Int -> Int .\nrate configured = configured * 3.\nlabel : Unit -> String .\nlabel unit = "triple pricing".\n')
                command(['commit', str(module), '--major'], d)
                for c in clients:
                    c.until(lambda st: has(st, 'triple pricing'))
                    assert has(c.state, 'Live Reload new') == notices
                mirror(a, {'q_LB': '1'})
                a.send('Card'); a.until(lambda st: has(st, 'receipt #4 for 5.20'))
                assert (a.s.fileno(), b.s.fileno()) == original_sockets
                assert len(re.findall(r'watch: app pid=', log.read_text())) == 1
                sales = [l.split() for l in receipt_log.read_text().splitlines() if l.startswith('sale ')]
                assert [int(l[6]) for l in sales] == [550, 1200, 720, 520], sales
                a.send('Rebuild'); a.until(lambda st: has(st, 'stock matches the log'))
                a.send('Quit')
                try:
                    proc.wait(timeout=20)
                except subprocess.TimeoutExpired as exc:
                    raise AssertionError('POS did not quit:\n' + log.read_text()[-6000:]) from exc
                assert proc.returncode == 0, log.read_text()[-6000:]
                assert not list((d / '.fpr').glob('.watch-app*'))
            finally:
                for c in clients:
                    try: c.close()
                    except OSError: pass
                if proc.poll() is None:
                    proc.terminate(); proc.wait(timeout=20)
        print(f'POS reload: {harts} hart(s), two live sockets/cashiers/carts, checkout policy changes, receipt history, invalid/incompatible refusal, recovery, reload notice enabled={notices} and log rebuild PASS')

# Ordinary run remains useful without a publication session or local version DB.
with tempfile.TemporaryDirectory(prefix='static POS-') as tmp:
    d = Path(tmp)
    exe = d / 'pos1'
    command(['build', str(ROOT / 'examples/pos1.fpr'), '-o', str(exe)], d)
    log = d / 'server.log'
    env = {k: v for k, v in os.environ.items() if k != 'FPR_RELOAD_JOURNAL'}
    env.update(POS1_PORT='0', POS1_STORE=str(d / 'receipts.log'))
    client = None
    with log.open('w') as output:
        proc = subprocess.Popen([exe], cwd=d, env=env, stdout=output, stderr=output)
        try:
            wait_for(lambda: re.search(r'ready (\d+)', log.read_text()), proc, log)
            port = int(re.search(r'ready (\d+)', log.read_text())[1])
            client = Client(port, 3)
            client.send('Login', 'ana|1234')
            client.until(lambda st: has(st, 'standard pricing'))
            mirror(client, {'q_FW': '1'})
            client.send('Card')
            client.until(lambda st: has(st, 'receipt #1 for 5.50'))
            client.send('Quit')
            proc.wait(timeout=20)
            assert proc.returncode == 0 and 'pricing adopted' not in log.read_text(), log.read_text()
        finally:
            if client:
                try: client.close()
                except OSError: pass
            if proc.poll() is None:
                proc.terminate(); proc.wait(timeout=20)
print('POS ordinary run: static pricing works without a publication journal PASS')
