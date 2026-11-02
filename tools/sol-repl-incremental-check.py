#!/usr/bin/env python3
"""Differential REPL contract: checked-definition reuse vs full rechecking.

Compares exact output, diagnostics, exit status and committed data. Also edits
imports between prompts with unchanged stat metadata, and asserts actual reuse.
"""
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()
TRACE = '[sol repl-check] '


def environment(work, mode, jit):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('SOL_', 'FPR_'))}
    return env | dict(FPR_HOME=str(ROOT), SOL_GPU='0', SOL_JIT=jit,
                      SOL_CACHE_DIR=str(work / ('cache-' + mode)), SOL_REPL_INCREMENTAL=mode)


def strip_trace(text):
    return ''.join(line for line in text.splitlines(keepends=True) if not line.startswith(TRACE))


class Session:
    def __init__(self, work, mode, jit):
        self.master, slave = pty.openpty()
        attrs = termios.tcgetattr(slave)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        self.buffer = b''
        self.proc = subprocess.Popen([str(FPR), 'sol', '--repl'], cwd=work,
                                     env=environment(work, mode, jit), stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        self.read_prompt()

    def read_prompt(self):
        deadline = time.monotonic() + 60
        while b'sol> ' not in self.buffer:
            assert time.monotonic() < deadline, self.buffer[-2000:]
            if select.select([self.master], [], [], 1)[0]:
                self.buffer += os.read(self.master, 65536)
        out, self.buffer = self.buffer.split(b'sol> ', 1)
        return out.decode().replace('\r\n', '\n')

    def send(self, line):
        os.write(self.master, (line + '\n').encode())
        return self.read_prompt()

    def close(self):
        os.write(self.master, b'\x04')
        code = self.proc.wait(timeout=10)
        os.close(self.master)
        assert code == 0, code


def main():
    count = 0
    cases = {
        'polymorphism': 'identity x = x.\n> print (identity "hello").\n> print "{identity 42}".\n> print (identity True).\n',
        'new-definition': 'inc x = x + 1.\n> print "{inc 1}".\ntwice x = inc (inc x).\n> print "{twice 2}".\n> print "{twice 3}".\n',
        'safety': 'inc x = x + 1.\n> print "{inc 1}".\nspin x = spin x.\n> print "{inc 4}".\n',
        'linearity': 'Token 1 = Type (Token Int). consume : Token -> Int. consume owner = Token value = owner; value.\nmake u = Token 7.\n> t = make 0; print (consume t).\n> t = make 0; print (consume t, consume t).\n> t = make 0; print (consume t).\n',
        'records': 'get r = r.a.\n> print "{get {a = 1}}".\n> print (get {a = "str", b = True}).\n> print "{get {a = 9, c = 2}}".\n',
        'clause-order': 'choose True x = x. choose False x = x + 1.\n> print "{choose True 4}".\n> print "{choose False 4}".\n',
        'signed-recursion': 'count : (n : Int | measure n) -> Int. count n = case n <= 0 of True -> 0 | False -> count (n - 1).\n> print "{count 10}".\n> print "{count 20}".\n',
        'mutual-recursion': 'even : (n : Int | measure n) -> Bool. odd : (n : Int | measure n) -> Bool. even n = case n <= 0 of True -> True | False -> odd (n - 1). odd n = case n <= 0 of True -> False | False -> even (n - 1).\n> print (even 8).\n> print (odd 9).\n',
        'late-signature': 'identity x = x.\n> print (identity "ok").\nidentity : Int -> Int.\n> print (identity "still ok").\n> print "{identity 7}".\n',
        'builtin-shadowing': 'go x = strlen x.\n> print "{go "abc"}".\nstrlen x = True.\n> print "{go "abcd"}".\n',
        'error-recovery': 'inc x = x + 1.\n> print "{inc 1}".\n> print "{inc True}".\nwrong = 3 + "bad".\n> print "{inc 4}".\ninc x = x + 2.\n> print "{inc 5}".\n',
        'holes': 'identity x = x.\n> print "{identity 3}".\nmissing = ?named.\n> print "{identity 4}".\n> print (??).\n> print "{identity 5}".\n',
        'parse-marks': '# é🦀\nidentity x = x.\n> print (identity "λ").\nwrong x =\n x + True.\n> ).\nwaiting =\n\n> print (identity "alive").\n',
        'precondition': 'positive : (n : Int | n > 0) -> Int. positive n = n + 1.\n> print "{positive 1}".\n> print "{positive 2}".\n> print "{positive 0}".\n> print "{positive 3}".\n',
        'transactions': 'inc x = x + 1.\n> writePath "value.txt" "first".\n> print (readPath "value.txt").\n> writePath "value.txt" "discard"; parseInt "bad".\n> print (readPath "value.txt").\n> writePath "value.txt" (strcat (readPath "value.txt") "x").\n> print "{inc 4}".\n',
        'libraries': f'J = use "{ROOT / "sol/lib/json"}".\nC = use "{ROOT / "sol/lib/csv"}".\n> print (J.render (J.strs ["a", "b"])).\n> print (C.render [["x", "y"]]).\n> print (J.render (J.strs ["c"])).\n> print (J.render (J.strs ["d"])).\n',
    }
    expected = {
        'polymorphism': 'hello\n42\nTrue\n', 'new-definition': '2\n4\n5\n',
        'safety': '2\n5\n', 'linearity': '7\n7\n', 'records': '1\nstr\n9\n', 'clause-order': '4\n5\n',
        'signed-recursion': '0\n0\n', 'mutual-recursion': 'True\nTrue\n',
        'late-signature': 'ok\nstill ok\n7\n', 'builtin-shadowing': '3\n4\n',
        'error-recovery': '2\n5\n6\n', 'holes': '3\n4\n5\n',
        'parse-marks': 'λ\nalive\n', 'precondition': '2\n3\n4\n',
        'transactions': 'first\nfirst\n5\n', 'libraries': '["a","b"]\nx,y\n\n["c"]\n["d"]\n',
    }
    with tempfile.TemporaryDirectory(prefix='sol-repl-incremental-') as tmp:
        work = Path(tmp)
        for jit in ('0', '1'):
            for name, source in cases.items():
                results = []
                traces = []
                for mode in ('0', 'trace'):
                    target = work / 'value.txt'
                    target.unlink(missing_ok=True)
                    proc = subprocess.run([str(FPR), 'sol', '--repl'], cwd=work,
                                          input=source, text=True, capture_output=True,
                                          env=environment(work, mode, jit), timeout=120)
                    results.append((proc.returncode, proc.stdout, strip_trace(proc.stderr),
                                    target.read_bytes() if target.exists() else None))
                    traces += re.findall(r'reused (\d+)/(\d+) definitions', proc.stderr)
                assert results[0] == results[1], (name, jit, results)
                assert results[1][0] == 0 and results[1][1] == expected[name], (name, jit, results[1])
                assert any(int(n) > 0 and n == total for n, total in traces), (name, 'no reuse', traces)
                if name == 'new-definition':
                    assert any(0 < int(n) < int(total) for n, total in traces), ('fresh helper did not reuse', traces)
                if name == 'safety':
                    assert 'SAFETY' in results[1][2], results[1]
                if name == 'linearity':
                    assert 'LINEARITY' in results[1][2], results[1]
                if name == 'transactions':
                    assert results[1][3] == b'firstx', results
                count += 1

            # Imports must be re-read even when the accepted user source did
            # not change. Edits at the leaf of a transitive import invalidate
            # the definition snapshot despite preserved size and timestamps.
            results = []
            for mode in ('0', 'trace'):
                leaf = work / 'leaf.sol'
                middle = work / 'middle.sol'
                leaf.write_text('value = 10.\n')
                middle.write_text('L = use "leaf".\nget x = L.value + x.\n')
                session = Session(work, mode, jit)
                try:
                    transcript = [session.send('M = use "middle".')]
                    transcript.append(session.send('> print "{M.get 1}".'))
                    transcript.append(session.send('> print "{M.get 2}".'))
                    old = leaf.stat()
                    leaf.write_text('value = 20.\n')
                    os.utime(leaf, ns=(old.st_atime_ns, old.st_mtime_ns))
                    transcript.append(session.send('> print "{M.get 3}".'))
                    transcript.append(session.send('> print "{M.get 4}".'))
                    results.append(''.join(map(strip_trace, transcript)))
                finally:
                    session.close()
            assert results[0] == results[1], ('edited import', jit, results)
            assert results[1] == '11\n12\n23\n24\n', results
            count += 1
    print(f'Sol REPL incremental: {count} differential sessions passed (JIT off/on, actual reuse, import edits and committed data)')


if __name__ == '__main__':
    main()
