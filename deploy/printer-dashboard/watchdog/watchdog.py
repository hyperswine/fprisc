#!/usr/bin/env python3
"""Bounded HTTP recovery for the existing, same-user Printer Host launchd job.
No credentials, printer commands, app-data writes, or independent app launch.
"""
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

LABEL = 'system/cloud.cswine.printer-host'
ROOT = Path.home() / 'printer-host'
STATE = ROOT / 'diagnostics/watchdog-state.json'


def command(args, timeout=8):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)


def service_pid():
    result = command(['/bin/launchctl', 'print', LABEL])
    match = re.search(r'^\s*pid = (\d+)\s*$', result.stdout, re.M)
    return int(match.group(1)) if result.returncode == 0 and match else None


def identity_matches(pid):
    uid = command(['/bin/ps', '-p', str(pid), '-o', 'uid='])
    exe = command(['/bin/ps', '-p', str(pid), '-o', 'comm='])
    return (uid.returncode == 0 and uid.stdout.strip() == str(os.getuid())
            and exe.returncode == 0
            and Path(exe.stdout.strip()).resolve() == (ROOT / 'current/printer-host').resolve())


def health():
    connection = http.client.HTTPConnection('100.107.153.43', 6730, timeout=4)
    try:
        connection.request('GET', '/health', headers={'Host': '3dprint.cswine.cloud', 'Connection': 'close'})
        response = connection.getresponse()
        return response.status == 200 and response.read(16) == b'ok\n'
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()


def log(message):
    path = ROOT / 'logs/watchdog.log'
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.stat().st_size > 1048576:
        path.replace(path.with_suffix('.log.previous'))
    with path.open('a') as out:
        out.write(time.strftime('%Y-%m-%dT%H:%M:%S%z') + ' ' + message + '\n')


def evidence(pid, now):
    directory = ROOT / 'diagnostics' / ('watchdog-' + time.strftime('%Y%m%dT%H%M%S', time.localtime(now)))
    directory.mkdir(mode=0o700)
    # Never read config, authentication, credentials, environments, or memory dumps.
    for name in ['host.stdout.log', 'host.stderr.log']:
        source = ROOT / 'logs' / name
        if source.exists():
            with source.open('rb') as src:
                src.seek(max(0, source.stat().st_size - 16384))
                (directory / name).write_bytes(src.read(16384))
    for name, args in [
        ('process.txt', ['/bin/ps', '-p', str(pid), '-o', 'pid,lstart,etime,%cpu,rss,stat']),
        ('sockets.txt', ['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), '-iTCP']),
        ('sample.txt', ['/usr/bin/sample', str(pid), '2'])]:
        try:
            result = command(args, timeout=8)
            (directory / name).write_text(result.stdout[-262144:] + result.stderr[-4096:])
        except subprocess.TimeoutExpired:
            (directory / name).write_text('Diagnostic timed out\n')
    care = ROOT / 'data/native-view.kvlog.care.json'
    if care.exists():
        (directory / 'maintenance.sha256').write_text(hashlib.sha256(care.read_bytes()).hexdigest() + '\n')
    previous = sorted(p for p in (ROOT / 'diagnostics').glob('watchdog-20*') if p.is_dir())
    for old in previous[:-10]:
        shutil.rmtree(old)
    return directory


def check(state, now):
    pid = service_pid()
    if pid is None or not identity_matches(pid):
        # Respect intentionally stopped/unloaded services and unrelated listeners.
        return {'pid': None, 'failures': 0, 'first_seen': now,
                'last_restart': state.get('last_restart', 0)}
    if state.get('pid') != pid:
        state = {'pid': pid, 'first_seen': now, 'failures': 0,
                 'last_restart': state.get('last_restart', 0)}
    if health():
        if state.get('failures', 0):
            log('HTTP recovered for pid=%d without restart' % pid)
        return dict(state, failures=0)
    state = dict(state, failures=state.get('failures', 0) + 1)
    log('HTTP health failure %d for pid=%d' % (state['failures'], pid))
    if state['failures'] < 3 or now - state['first_seen'] < 120 or now - state.get('last_restart', 0) < 600:
        return state
    directory = evidence(pid, now)
    # Recheck health and identity after diagnostics. A replacement process gets grace.
    if health():
        log('HTTP recovered during diagnostics; restart cancelled')
        return dict(state, failures=0)
    if service_pid() != pid or not identity_matches(pid):
        log('Service identity changed; restart cancelled')
        return dict(state, failures=0)
    # Record intent before signaling so a watchdog interruption cannot cause a loop.
    state = dict(state, failures=0, last_restart=now)
    save(state)
    os.kill(pid, signal.SIGTERM)
    log('SIGTERM sent to unhealthy dashboard pid=%d; launchd owns restart; evidence=%s' % (pid, directory.name))
    return state


def save(state):
    temporary = STATE.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    temporary.replace(STATE)


def main():
    os.umask(0o077)
    STATE.parent.mkdir(parents=True, exist_ok=True)
    with (STATE.parent / 'watchdog.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        try:
            state = json.loads(STATE.read_text()) if STATE.exists() else {}
            if not isinstance(state, dict):
                state = {}
        except (OSError, ValueError):
            state = {}
        try:
            save(check(state, time.time()))
        except Exception as error:
            # Class only: avoid accidentally logging connection/auth material.
            log('Watchdog check failed: ' + type(error).__name__)
            raise


if __name__ == '__main__':
    main()
