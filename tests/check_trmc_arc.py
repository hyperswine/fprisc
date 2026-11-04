#!/usr/bin/env python3
"""Checked TRMC under the builtin owned-call ABI: values, traps and lifetime."""
from pathlib import Path
import os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
HELPERS = """revOnto xs acc = case xs of Nil -> acc | Cons h t -> revOnto t (Cons h acc).
reverse xs = revOnto xs Nil.
build n acc = case n == 0 of True -> reverse acc | False -> build (n - 1) (Cons n acc).
append xs ys = revOnto (reverse xs) ys.
check b = case b of True -> Unit | False -> error "TRMC ARC check failed".
"""

def run(args, env, timeout=180):
    return subprocess.run(list(map(str,args)),cwd=ROOT,env=env,text=True,capture_output=True,timeout=timeout)

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-trmc-arc-') as d:
        tmp=Path(d)
        env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/'cache'))
        def build(code, name, disabled=False, heap=1048576, arc=True, extra=()):
            path=tmp/(name+'.fpr')
            helpers=HELPERS
            if name.startswith(('raw-', 'managed-')):
                helpers='\n'.join(line for line in helpers.splitlines() if not line.startswith(('build ', 'append ')))+'\n'
            path.write_text(helpers+code)
            directory=tmp/name; image=directory/'test.elf'
            mode=dict(env,FPR_NO_TRMC=str(int(disabled)),FPR_OPT_REMARKS='1')
            p=run(['make','bare-metal-builtin',f'ARC={int(arc)}','ARC_CHECK=1',f'BUILTIN_HEAP_BYTES={heap}',f'PROG={path}',f'IMAGE={image}',f'BUILD={directory}',*extra],mode)
            assert p.returncode==0,(name,p.stdout[-2000:],p.stderr[-8000:])
            asm=(directory/'builtin.s').read_text()
            return image,mode,asm
        def boot(image, mode):
            p=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],mode,60)
            return p.returncode,p.stdout,p.stderr
        cases={
          'values': 'main = seed = [9,8]; xs = build 3 seed; tail = [7,6]; ys = append xs tail; print (xs,seed,ys,tail).',
          'managed': 'go : Int -> String -> List String -> List String.\ngo n payload acc = case n == 0 of True -> reverse acc | False -> go (n - 1) payload (Cons payload acc).\nmain = payload = strcat "a" "b"; xs = go 5 payload []; print (xs,payload).',
          'raw': 'go : Int -> Word -> List Word -> List Word.\ngo n w acc = case n == 0 of True -> reverse acc | False -> go (n - 1) w (Cons w acc).\nmain = xs = go 5 (Word.fromInt 42) []; print xs.',
          'effects': 'tap n = print n >> n.\ngo n acc = case n == 0 of True -> reverse acc | False -> go (n - 1) (Cons (tap n) acc).\nmain = print (go 3 []).',
          'division': 'go n acc = case n == 0 of True -> reverse acc | False -> print n >> go (n - 1) (Cons (10 / (n - 2)) acc).\nmain = print (go 3 []).',
          'overflow': 'go n acc = case n == 0 of True -> reverse acc | False -> print n >> go (n - 1) (Cons (4611686018427387903 + n) acc).\nmain = print (go 3 []).',
          'release': 'exercise n = xs = build 20 []; ys = append xs [7,8]; check (case ys of Nil -> False | Cons h t -> h == 20).\nrepeat n = case n == 0 of True -> Unit | False -> exercise n >> repeat (n - 1).\nmain = repeat 1000 >> check (Mem.liveAllocations Unit == 0) >> print "TRMC ARC HOLDS".',
        }
        for name,code in cases.items():
            seen=[]
            for disabled in (False,True):
                image,mode,asm=build(code,f'{name}-{disabled}',disabled,16384 if name=='release' else 1048576)
                assert ('$worker.trmc.' in asm)==(not disabled),(name,disabled)
                seen.append(boot(image,mode))
            assert seen[0]==seen[1],(name,seen)
            if name in ('division','overflow'):
                assert ('division by zero' if name=='division' else 'overflow') in seen[0][1]+seen[0][2],seen
            else:
                assert seen[0][0]==0 and 'ARC leak' not in seen[0][1]+seen[0][2],seen
            print('TRMC ARC differential '+name+': PASS',flush=True)
        # The same checked builder uses direct stores in manual builtin mode.
        seen=[]
        for disabled in (False,True):
            image,mode,asm=build(cases['values'],f'manual-{disabled}',disabled,arc=False)
            assert ('$worker.trmc.' in asm)==(not disabled)
            seen.append(boot(image,mode))
        assert seen[0]==seen[1] and seen[0][0]==0,seen
        print('TRMC manual builtin shared tails: PASS',flush=True)
        # Count allocation requests at the actual owned allocation ABI on both
        # allocator implementations. No print/str allocation contaminates it.
        for allocator in ('fpr','c'):
            for disabled in (False,True):
                wanted=400 if disabled else 200
                oracle=tmp/'oracle.c'
                oracle.write_text('#include "builtin.h"\n'
                    'static uw requests;\n'
                    'extern V __real_fpr_builtin_alloc_adt(V,uw);\n'
                    'V __wrap_fpr_builtin_alloc_adt(V n,uw fields) { requests++; return __real_fpr_builtin_alloc_adt(n,fields); }\n'
                    'extern V __real_fpr_fn_main(void);\n'
                    'V __wrap_fpr_fn_main(void) { uw before=requests; V v=__real_fpr_fn_main(); '
                    f'if(requests-before!={wanted}) fpr_cpanic("TRMC allocation count"); return v; }}\n')
                image,mode,asm=build('main = build 200 [].',f'count-{allocator}-{disabled}',disabled,
                    extra=[f'HEAP={allocator}',f'BUILTIN_EXTRA={oracle}',
                           'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main,--wrap=fpr_builtin_alloc_adt'])
                result=boot(image,mode)
                assert result[0]==0,result
            print(f'TRMC ARC {allocator} allocator: 400 -> 200 requests PASS',flush=True)
        image,mode,asm=build('main = build 6000 [].','deep')
        assert '$worker.trmc.' in asm
        assert boot(image,mode)[0]==0
        print('TRMC ARC deep returned graph / iterative release: PASS',flush=True)
if __name__=='__main__': main()
