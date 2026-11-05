#!/usr/bin/env python3
"""Execute 2..8-word x64 results with an independent C oracle and fuel clobbers.

This focused harness adapts TLS linkage only; the full Base source regression
also runs separately against the real runtime. No allocator is linked here.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from check_product_returns import fixture
from fuel_wrapper import fuel_wrapper
from product_return_probe import return_bodies
from x64_probe import ROOT, adapt, host, link, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-execution', action='store_true')
    parser.add_argument('--record', type=Path)
    args = parser.parse_args()
    target = host()
    if target is None:
        assert not args.require_execution, 'x64 execution unavailable'
        print('x64 product execution SKIP: requires Intel or Rosetta')
        return
    mac, runner, label = target
    rows, actors = [], []
    with tempfile.TemporaryDirectory(prefix='fpr-x64-products-') as directory:
        tmp = Path(directory)
        env = {k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'),
                   FPR_NO_INLINE='1', FPR_NO_CALL_REGIONS='1', FPR_NO_LOOP_REGIONS='1',
                   FPR_NO_FIELD_WORKERS='1', FPR_NO_SCALAR_WORKERS='1')
        oracle = (ROOT/'tests/typed_ir/product_return_oracle.c').read_text()
        oracle = oracle.replace('static intptr_t hart[64] = {[58] = -1};',
            'static intptr_t hart[64] = {[58] = -1};\nvoid *probe_hart=hart; intptr_t probe_a6,probe_a7;')
        start = oracle.index('__attribute__((noreturn)) void oracle_finish')
        end = oracle.index('void oracle_tick')
        oracle = oracle[:start] + '''#include <stdio.h>
#include <stdlib.h>
__attribute__((noreturn)) void oracle_finish(int code) { exit(code); }
static void require(int ok) { if (!ok) oracle_finish(1); }
''' + oracle[end:]
        oracle = oracle.replace('oracle_tick', 'fpr_probe_tick')
        oracle = oracle.replace('i*n', '(PRODUCT_REPEATED?0:i)*n')
        oracle = oracle.replace('    __asm__ volatile ("mv tp, %0" :: "r"(hart) : "memory");\n', '')
        c = tmp/'oracle.c'; c.write_text(oracle)
        shim = '''.text
.globl fpr_fuel_exhausted
fpr_fuel_exhausted:
    pushq %rbp
    movq %rsp, %rbp
    call fpr_probe_tick
    popq %rbp
''' + ''.join(f'    xorq %{r}, %{r}\n' for r in ['rax','rcx','rdx','rsi','rdi','r8','r9','r10','r11']) + '    ret\n'
        for width,repeated in [*( (n,False) for n in range(1,9)), (8,True)]:
            text = fixture(width)
            if repeated:
                text = text.replace(', '.join(f'n + {i}' for i in range(width)), ', '.join(['n']*width))
            source = tmp/f'width{width}.fpr'; source.write_text(text)
            asm = tmp/f'width{width}.s'
            run([ROOT/'fpr', 'compile', '--system=posix', '--target=x64', source, asm], env)
            whole = asm.read_text()
            body = return_bodies(whole, width)
            adapted = adapt('.text\n'+body+fuel_wrapper(whole, body)+shim, mac)
            assembly = tmp/f'width{width}-adapted.s'; assembly.write_text(adapted)
            exe = tmp/f'width{width}'
            link([f'-DPRODUCT_WIDTH={width}', f'-DPRODUCT_REPEATED={int(repeated)}', assembly, c], exe, mac, env)
            output = run([*runner, exe], env)
            assert '2100 C-reference' in output and 'PASS' in output, output
            rows.append(dict(width=width, repeated_fields=repeated, cases=2100, assembly_sha256=hashlib.sha256(assembly.read_bytes()).hexdigest(),
                             executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest()))
            print(f'x64 product returns: {width} fields, repeated={repeated}, {output.strip()}', flush=True)
        # Real runtime: non-tail recursion keeps eight result fields live as
        # actors exhaust fuel. This covers scheduler-visible continuations
        # independently of the adapted-cell backend oracle above.
        names = [f'x{i}' for i in range(8)]
        actor_source = ('unsafe base.\nsum8 : unsafe Int -> ('+', '.join(['Int']*8)+').\n'
            'sum8 n = if n == 0 then ('+', '.join(str(i+1) for i in range(8))+') else '
            '(case sum8 (n - 1) of ('+', '.join(names)+') -> ('+
            ', '.join(f'{x} + n * {i+1}' for i,x in enumerate(names))+')).\n'
            'rep k a = if k == 0 then a else case sum8 1000 of ('+', '.join(names)+') -> '
            'rep (k - 1) (a + '+' + '.join(names)+').\n'
            'work parent self = send parent (rep 100 0).\n'
            'main = me = myself 0; a = spawn (work me); b = spawn (work me); c = spawn (work me); '
            'x = receiveFrom me a; y = receiveFrom me b; z = receiveFrom me c; '
            'print "{keep x} {keep y} {keep z}".\n')
        source = tmp/'actors.fpr'; source.write_text(actor_source)
        probe = tmp/'scheduler.c'
        probe.write_text('''#include "fpr.h"
#include "sched_probe.h"
#include <stdatomic.h>
#include <stdio.h>
static _Atomic unsigned long fuel;
void fpr_sched_probe(unsigned event, uw hart, uw actor) {
  (void)hart; (void)actor;
  if (event == FPR_SCHED_FUEL) atomic_fetch_add_explicit(&fuel,1,memory_order_relaxed);
}
__attribute__((destructor)) static void report(void) {
  fprintf(stderr,"PRODUCT_FUEL %lu\\n",atomic_load(&fuel));
}
''')
        # --cflag applies to the added HAL source. The compiler wrapper also
        # instruments the separately cached runtime, as the latency suite does.
        cc = tmp/'probe-cc'
        cc.write_text('#!/usr/bin/env python3\nimport os,sys\nos.execvp("cc", ["cc", "-DFPR_SCHED_PROBE=1"] + sys.argv[1:])\n')
        cc.chmod(0o755)
        wanted = str(100 * 36 * (1 + 1000*1001//2))
        for enabled in (False, True):
            settings = dict(env, **({} if enabled else {'FPR_NO_PAIR_RETURNS':'1'}))
            assembly = tmp/f'actors-{enabled}.s'
            run([ROOT/'fpr', 'compile', '--system=posix', '--target=x64', source, assembly], settings)
            assert ('x2eret8_x2esum8' in assembly.read_text()) == enabled
            exe = tmp/f'actors-{enabled}'
            run([ROOT/'fpr', 'build', *(['--target=macos-x86_64'] if mac else []), source,
                 '--harts', '4', '--with', probe, '--cc', cc, '-o', exe], settings)
            for harts in (1, 4):
                p = subprocess.run([*runner, exe], cwd=ROOT, env=dict(settings,FPR_HARTS=str(harts)),
                                   text=True, capture_output=True, timeout=180)
                assert p.returncode==0 and p.stdout==' '.join([wanted]*3)+'\n', (p.returncode,p.stdout,p.stderr)
                match = re.search(r'PRODUCT_FUEL (\d+)',p.stderr)
                assert match and int(match[1])>0, p.stderr
                actors.append(dict(enabled=enabled,harts=harts,fuel_events=int(match[1]),stdout=p.stdout))
        print('x64 real runtime: eight-field recursive results, three actors, observed fuel exhaustion and 1/4 harts PASS',flush=True)
    if args.record:
        args.record.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),
            test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), runner=label, rows=rows,actors=actors,
            scope='Independent C oracle with adapted TLS and no allocator; separate real-runtime recursive actor results with scheduler observation. Not physical timing/WCET.'), indent=2)+'\n')


if __name__ == '__main__':
    main()
