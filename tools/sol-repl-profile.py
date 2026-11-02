#!/usr/bin/env python3
"""Attribute Sol REPL compilation time with SOL_TIMINGS and validated PTY output.

These are instrumented timings, not a substitute for sol-repl-benchmark.py.
Additional phase labels can be obtained with the documented temporary probe
patch. Keep the binary, source identity and raw command transcripts together.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import pty
import re
import select
import statistics
import subprocess
import termios
import time

ROOT = Path(__file__).resolve().parents[1]


class Session:
    def __init__(self, binary, home, output, tag):
        self.fd, slave = pty.openpty()
        attrs = termios.tcgetattr(slave)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        self.buffer = b''
        env = {k: v for k, v in os.environ.items() if not k.startswith(('SOL_', 'FPR_', 'GHCRTS'))}
        env.update(FPR_HOME=str(home), SOL_GPU='0', SOL_TIMINGS='1', SOL_REPL_INCREMENTAL='trace',
                   SOL_CACHE_DIR=str(output / ('cache-' + tag)))
        self.proc = subprocess.Popen([str(binary), 'sol', '--repl'], cwd=output, env=env,
                                     stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        self.read_prompt()

    def read_prompt(self):
        deadline = time.monotonic() + 60
        while b'sol> ' not in self.buffer:
            if time.monotonic() >= deadline:
                raise TimeoutError(self.buffer[-2000:])
            if select.select([self.fd], [], [], 1)[0]:
                chunk = os.read(self.fd, 65536)
                if not chunk:
                    raise RuntimeError('REPL closed before its prompt')
                self.buffer += chunk
        data, self.buffer = self.buffer.split(b'sol> ', 1)
        return data.decode().replace('\r\n', '\n')

    def send(self, command, expected):
        start = time.perf_counter_ns()
        data = (command + '\n').encode()
        while data:
            written = os.write(self.fd, data)
            data = data[written:]
        text = self.read_prompt()
        elapsed = (time.perf_counter_ns() - start) / 1e6
        actual = ''.join(line for line in text.splitlines(keepends=True)
                         if not line.startswith(('[sol timing]', '[sol repl-check]')))
        assert actual == expected, (command, expected, text)
        return dict(wall_ms=elapsed,
                    phases={m.group(1): float(m.group(2)) for m in
                            re.finditer(r'\[sol timing\] ([^:]+): ([\d.]+) ms', text)},
                    reused=re.findall(r'reused (\d+)/(\d+)', text), transcript=text)

    def close(self):
        try:
            os.write(self.fd, b'\x04')
            assert self.proc.wait(timeout=10) == 0
        finally:
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait()
            os.close(self.fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'fpr')
    parser.add_argument('--home', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sessions', type=int, default=3)
    parser.add_argument('--queries', type=int, default=15)
    parser.add_argument('--sizes', type=int, nargs='+', default=[0, 100, 500])
    args = parser.parse_args()
    if args.sessions < 1 or args.queries < 2 or any(n < 0 for n in args.sizes):
        parser.error('sessions must be positive, queries at least two, sizes nonnegative')
    binary, home, output = args.binary.resolve(), args.home.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    rows = []
    for trial in range(args.sessions):
        cases = [(f'defs-{n}', n) for n in args.sizes] + [('json-csv', None)]
        for name, count in cases:
            session = Session(binary, home, output, name)
            try:
                if count is None:
                    session.send(f'J = use "{home}/sol/lib/json". C = use "{home}/sol/lib/csv".', '')
                    command = '> u = print (J.render (J.strs ["a", "b"])); print (C.render [["c", "d"]]).'
                    expected = '["a","b"]\nc,d\n\n'
                else:
                    for start in range(0, count, 50):
                        session.send(' '.join(f'v{i} = {i}.' for i in range(start, min(start + 50, count))), '')
                    command = f'> print (v{count-1} + 1).' if count else '> print (41 + 1).'
                    expected = str(count if count else 42) + '\n'
                for ordinal in range(args.queries):
                    rows.append(dict(case=name, trial=trial, ordinal=ordinal, **session.send(command, expected)))
            finally:
                session.close()
    metadata = dict(binary=str(binary), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    driver_head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    platform=platform.platform(), sessions=args.sessions, queries=args.queries, sizes=args.sizes,
                    method='Instrumented PTY round trips; SOL_TIMINGS forces boundaries; GPU off, default JIT. '
                           'Exclude ordinal zero from summaries; phase totals are nested and add instrumentation overhead.',
                    rows=rows)
    (output / 'profile.json').write_text(json.dumps(metadata, indent=2) + '\n')
    for name, _ in cases:
        samples = [row for row in rows if row['case'] == name and row['ordinal'] > 0]
        labels = sorted({label for row in samples for label in row['phases']})
        summary = {label: round(statistics.median(row['phases'].get(label, 0) for row in samples), 3)
                   for label in labels}
        print(name, 'wall_ms', round(statistics.median(row['wall_ms'] for row in samples), 3), summary)


if __name__ == '__main__':
    main()
