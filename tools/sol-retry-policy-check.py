#!/usr/bin/env python3
"""Guarded replay, explicit compatibility and replay assertions on real effects."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()


def lit(value):
    return json.dumps(str(value)).replace('{', '\\{').replace('}', '\\}')


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-retry-policy-') as tmp:
        w = Path(tmp).resolve()
        env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
        env |= {'SOL_GPU': '0', 'SOL_JIT': os.environ.get('FPR_TEST_JIT', '1'),
                'SOL_CACHE_DIR': str(w / 'cache'), 'SOL_FORCE_RETRY': '2'}
        counter = w / 'counter'
        destination = w / 'destination'
        helper = w / 'count.py'
        helper.write_text('from pathlib import Path\nimport sys\np=Path(sys.argv[1])\n'
                          'p.write_text(p.read_text()+"x" if p.exists() else "x")\n')
        argv = ','.join(map(lit, [sys.executable, helper, counter]))
        spec = f'ProcessSpec [{argv}] "" [] "" 2000'

        def run(name, source, code=0, expected=b'', policy=None, cli=(), occurrences=None):
            nonlocal count
            counter.unlink(missing_ok=True)
            destination.unlink(missing_ok=True)
            path = w / (name + '.sol')
            path.write_text(source)
            p = subprocess.run([str(FPR), 'sol', *cli, str(path)],
                               env=env | ({} if policy is None else {'SOL_RETRY_POLICY': policy}),
                               capture_output=True, timeout=20)
            assert (p.returncode, p.stdout) == (code, expected), (name, p)
            if code == 1:
                assert b'guarded retry refused' in p.stderr and b'partial external execution' in p.stderr, (name, p)
                assert b'retrying (attempt' not in p.stderr, (name, p)
                assert not destination.exists(), (name, p)
            else:
                assert destination.read_text() == 'committed', (name, p)
                assert p.stderr.count(b'retrying (attempt') == 2, (name, p)
            if occurrences is not None:
                assert counter.read_text() == 'x' * occurrences, (name, p, counter.read_text())
            count += 1

        write = f'u = writePath {lit(destination)} "committed"; '
        run('arbitrary_query_guarded', f'> q = Proc.query ({spec}); {write}Unit.\n', 1, occurrences=1)
        run('arbitrary_query_legacy', f'> q = Proc.query ({spec}); {write}Unit.\n',
            policy='legacy', occurrences=3)
        run('cli_legacy_overrides_env', f'> q = Proc.query ({spec}); {write}Unit.\n',
            policy='guarded', cli=['--retry-policy=legacy'], occurrences=3)
        run('cli_guarded_overrides_env', f'> q = Proc.query ({spec}); {write}Unit.\n', 1,
            policy='legacy', cli=['--retry-policy=guarded'], occurrences=1)
        run('explicit_query_assertion', f'> q = Proc.queryReplayable ({spec}); {write}Unit.\n', occurrences=3)
        run('scoped_assertion', f'> q = Script.replayable (fn u -> Proc.query ({spec})); {write}Unit.\n', occurrences=3)
        run('scope_does_not_escape', f'> q = Script.replayable (fn u -> Proc.query ({spec}));'
            f' r = Proc.query ({spec}); {write}Unit.\n', 1, occurrences=2)
        run('nested_scopes', f'> q = Script.replayable (fn u -> Script.replayable (fn v -> Proc.query ({spec})));'
            f' {write}Unit.\n', occurrences=3)
        run('actor_scope_isolation',
            f'worker parent self = q = Proc.query ({spec}); send parent self.\n'
            '> me = myself 0; child = Script.replayable (fn u -> spawn (worker me));'
            f' got = receive me; {write}Unit.\n', 1, occurrences=1)
        run('printed_output', f'> p = print "once"; {write}Unit.\n', 1, b'once\n')
        run('exact_output', f'> p = IO.stdoutText "once"; {write}Unit.\n', 1, b'once')
        run('asserted_output', f'> p = Script.replayable (fn u -> print "repeat"); {write}Unit.\n',
            expected=b'repeat\n' * 3)
        run('transactional_log', f'> {write}log "once".\n', expected=b'once\n')
        run('deferred_runs_after_validation', f'> p = Proc.afterCommit ({spec}); {write}Unit.\n', occurrences=1)
        run('shell_guarded', f'> q = sh {lit(f"{sys.executable} {helper} {counter}")}; {write}Unit.\n', 1, occurrences=1)
        run('stdin_guarded', f'> p = IO.readLine 1; {write}Unit.\n', 1)
        stream_source = w/'stream-source'
        stream_source.write_bytes(b'abc')
        run('fold_outside_asserted_open_is_guarded',
            'countBytes n b = n + Bytes.len b.\n'
            f'> r = Script.replayable (fn u -> unwrap (Stream.openRead {lit(stream_source)} 2));'
            ' (result,r2) = Stream.foldChunks countBytes 0 r; closed = Stream.closeRead r2;'
            f' {write}Unit.\n', 1)
        # Invalid configuration fails before source execution, with a useful error.
        p = subprocess.run([str(FPR), 'sol', '--retry-policy=unknown', str(w / 'missing.sol')],
                           env=env, capture_output=True, timeout=10)
        assert p.returncode == 1 and b'invalid retry policy' in p.stderr, p
        count += 1
    print(f'sol retry-policy checks: {count} passed')


if __name__ == '__main__':
    main()
