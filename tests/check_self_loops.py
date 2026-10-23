#!/usr/bin/env python3
"""Self-tail frame reuse: argument cycles, effects, fuel, stacks and caches."""
import os
import platform
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def run(args, env, code=0):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                       capture_output=True, timeout=240)
    assert p.returncode == code, (args, p.returncode, p.stdout[-3000:], p.stderr[-3000:])
    return p.stdout

def fixture():
    text = """unsafe base.
Loops.arm : Unit -> Unit .
Loops.used : Unit -> Int .
Loops.force : Unit -> Unit .
ticks : unsafe Int -> Int -> Int .
ticks n a = if n == 0 then a else ticks (n - 1) (a + 1).
deep : unsafe Int -> Int .
deep n = if n == 0 then 0 else 1 + deep (n - 1).
mixed : unsafe Int -> Int -> Int .
mixed n a = if n == 0 then a else mixed (n - 1) (a + deep 10000).
mark n = _ = print n; n.
effects : unsafe Int -> Int -> Int -> Int .
effects n a b = if n == 0 then a * 10 + b
  else effects (n - 1) (mark b) (mark a).
spin : unsafe Int -> Unit .
spin n = spin n.
hog parent self = _ = send parent 1; spin 0.
"""
    cases = []
    expected = {}
    for width in (2, 7, 8, 63):
        names = [f"a{i}" for i in range(1, width + 1)]
        text += f"""rotate{width} : unsafe {' -> '.join(['Int'] * (width + 2))} .
rotate{width} n {' '.join(names)} = if n == 0 then {' + '.join(f'{i} * {n}' for i, n in enumerate(names, 1))}
  else rotate{width} (n - 1) {' '.join(names[1:] + names[:1])}.
"""
        cases.append(f'["rotate{width}"] -> _ = Loops.force Unit; print (rotate{width} 20001 {" ".join(map(str, range(1, width + 1)))})')
        values = list(range(1, width + 1))
        shift = 20001 % width
        values = values[shift:] + values[:shift]
        expected[f"rotate{width}"] = f"{sum(i*v for i, v in enumerate(values, 1))}\n"
    cases += [
        '["ticks"] -> _ = Loops.arm Unit; a = ticks 20000 0; count = Loops.used Unit; print "{a} {count}"',
        '["stack"] -> print (mixed 20 0)',
        '["effects"] -> print (effects 2 1 2)',
        '["fair"] -> me = myself 0; child = spawn (hog me); msg = receiveFrom me child; saved = keep msg; _ = kill child; print saved',
        '_ -> print "self loops"',
    ]
    # 20,001 loop entries; canonical Unit introduces no extra function entry.
    expected.update(ticks="20000 20001\n", stack="200000\n",
                    effects="2\n1\n1\n2\n12\n", fair="1\n")
    return text + "main = case Sys.args Unit of\n  " + "\n | ".join(cases) + ".\n", expected

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-self-loops-') as td:
        tmp=Path(td)
        env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/'cache'),
                 FPR_NO_INLINE='1',FPR_NO_SCALAR_WORKERS='1',FPR_NO_FIELD_WORKERS='1')
        env.pop('FPR_FOREIGN',None)
        ghc=['cabal','exec','--','runghc']
        print(run([*ghc,'-w','-icompiler','tests/NullaryConstants.hs'],env),end='',flush=True)
        source=tmp/'selfloops.fpr';text,expected=fixture();source.write_text(text)
        for enabled in ('0','1'):
            mode=dict(env,FPR_TYPED_IR_SELF_LOOPS=enabled)
            exe=tmp/'probe'
            run([ROOT/'fpr','build',source,'--harts','4','--with',ROOT/'tests/base/selfloops_probe.c','-o',exe],mode)
            for harts in ('1','4'):
                for case,want in expected.items():
                    got=run([exe,case],dict(mode,FPR_HARTS=harts))
                    assert got==want,(enabled,harts,case,got,want)
            for target in ('rv32','rv64'):
                asm=tmp/(target+'.s')
                run([ROOT/'fpr','compile','--target='+target,source,asm],mode)
                text=asm.read_text()
                assert ('_m3loop:' in text)==(enabled=='1')
                assert '# wcet:' not in text and 'segmax=UNBOUNDED' not in text
            print(f'Typed self loops={enabled}: cycles of 2/7/8/63 arguments, effects, fuel, stacks, fairness, 1/4 harts and RV32/RV64 emission PASS',flush=True)

if __name__=='__main__':main()
