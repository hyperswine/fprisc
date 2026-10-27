#!/usr/bin/env python3
"""Advisory facts survive warm caches without changing native emission."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-remarks-"🙂-') as directory:
        tmp = Path(directory)
        provider = tmp / 'provider.fpr'
        provider_text = '''unsafe base.
first x = _ = print x; x.
second x = x.
run n = v = Vec.fromList [1, 2]; a = Vec.map first v;
  b = Vec.map second a; _ = Vec.free b; n.
count n acc = if n == 0 then acc else scratch = "row {n}";
  count (n - 1) (acc + strlen scratch).
'''
        provider.write_text(provider_text)
        source = tmp / 'main.fpr'
        source.write_text('unsafe base. P = use "provider.fpr".\n'
                          'main = _ = print (P.run 9); print (P.count 12 0).\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / 'cache'),
                   FPR_NO_INLINE='1')

        def run(args, code=0):
            p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                               capture_output=True, text=True, timeout=120)
            assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
            return p

        for target in ('a64', 'x64', 'rv64', 'rv32', 'qa64', 'qx64', 'qrv64'):
            assembly = tmp / target / 'main.s'
            assembly.parent.mkdir()

            def compile(*flags, code=0):
                return run([ROOT / 'fpr', 'compile', f'--target={target}', *flags, source, assembly], code)

            cold = compile()
            assert 'remark[' not in cold.stderr and 'is NOT fused:' not in cold.stdout
            original = assembly.read_bytes()
            unit_list = Path(str(assembly) + '.units').read_text()
            units = [Path(p) for p in unit_list.splitlines()]
            snapshots = {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in units}
            first = compile('--remarks=json')
            second = compile('--remarks=json')
            assert first.stderr == second.stderr, 'warm remarks changed'
            records = [json.loads(line) for line in first.stderr.splitlines()]
            failures = [r for r in records if r['kind'] == 'not-fused']
            assert len(failures) == 1, failures
            refusal = failures[0]
            assert refusal['reason']['tag'] == 'CallbackEffect', refusal
            assert refusal['reason']['cause']['tag'] == 'Primitive', refusal
            assert refusal['owner'].startswith('run@') and Path(refusal['file']).resolve() == provider.resolve(), refusal
            assert refusal['start'] == {'line': 3, 'character': 0} and refusal['end'] is None, refusal
            assert refusal['precision'] == 'definition' and refusal['positionEncoding'] == 'utf-32'
            assert any(r['kind'] == 'region' and r['owner'].startswith('count@') for r in records), records
            text = compile('--remarks=all')
            assert 'remark[not-fused]' in text.stderr and 'provider.fpr:4:' in text.stderr
            hot = compile('--remarks')
            assert 'callback `first' not in hot.stderr, 'cold refusal escaped the heat filter'
            assert assembly.read_bytes() == original, target
            assert Path(str(assembly) + '.units').read_text() == unit_list, 'remark options changed cache identity'
            assert {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in units} == snapshots, target
            compile('--remarks=typo', code=1)
            compile('--remarks=json', '--check-only', code=1)
            if target == 'a64':
                provider.write_text('# moved 🙂\n' + provider_text)
                moved = [json.loads(line) for line in compile('--remarks=json').stderr.splitlines()]
                located = next(r for r in moved if r['kind'] == 'not-fused')
                assert located['start']['line'] == 4, located
                provider.write_text(provider_text)
            print(f'remarks {target}: disabled/cold/warm, JSON, imported owner, visibility and emission/cache parity PASS', flush=True)

        env.pop('FPR_NO_INLINE', None)
        analysis = tmp / 'attempts.fpr'
        analysis.write_text('unsafe base.\napply f x = f x.\ninc x = x + 1.\n'
                            'count n = if n == 0 then 0 else count (n - 1).\n'
                            'main = print (apply inc (count 4)).\n')
        args = [ROOT / 'fpr', 'compile', '--target=a64', analysis, tmp / 'attempts.s']
        plain = run(args)
        original = (tmp / 'attempts.s').read_bytes()
        cold = run([*args, '--remarks=json'])
        warm = run([*args, '--remarks=json'])
        assert cold.stderr == warm.stderr
        attempts = [json.loads(line) for line in cold.stderr.splitlines()]
        assert any(r.get('kind') == 'inline' and r['reason']['tag'] == 'Inlined' for r in attempts)
        assert any(r.get('kind') == 'inline' and r['reason']['tag'] == 'RecursiveCallee' for r in attempts)
        assert any(r.get('kind') == 'generic-call' and r['reason']['tag'] == 'Specialized' for r in attempts)
        assert any(r.get('kind') == 'generic-call' and r['reason']['tag'] in ('NoKnownArgument', 'UnknownTarget') for r in attempts)
        assert any(r.get('remarkInputsVersion') == 1 and r['files'] for r in attempts)
        assert original == (tmp / 'attempts.s').read_bytes()
        image = tmp / 'native'
        built = run([ROOT / 'fpr', 'build', source, '--remarks=json', '-o', image])
        assert any(json.loads(line)['kind'] == 'not-fused' for line in built.stderr.splitlines()
                   if line.startswith('{')), built.stderr
        assert run([image]).stdout == '1\n2\n9\n63\n'
        print('remarks build: native execution and flag forwarding PASS')


if __name__ == '__main__':
    main()
