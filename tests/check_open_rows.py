#!/usr/bin/env python3
"""Open-record tagged boundaries: shape dispatch, updates, bits and ownership."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from check_uniform_aggregate import ROOT, run

SOURCE = '''profile builtin.
get : {x : Word | r} -> Word.
get p = p.x.
put : Word -> {x : Word | r} -> {x : Word | r}.
put w p = {p | x = w}.
makeOne : Word -> {x : Word}.
makeOne w = {x=w}.
makeTwo : Word -> {x : Word, y : Word}.
makeTwo w = {x=w,y=Word.not w}.
makeText : Int -> Word -> {label : String, x : Word}.
makeText n w = {label=str n,x=w}.
makeFloat : F64 -> F32 -> {x : F64, z : F32}.
makeFloat d f = {x=d,z=f}.
getDouble : {x : F64 | r} -> F64.
getDouble p = p.x.
getFloat : {z : F32 | r} -> F32.
getFloat p = p.z.
makeNested : Int -> Word -> {inner : {label : String, x : Word}, keep : List Word}.
makeNested n w = {inner={label=str n,x=w},keep=[w,Word.not w]}.
makeSmall : Word -> {inner : {x : Word}}.
makeSmall w = {inner={x=w}}.
putNested : Word -> {inner : {x : Word | r} | s} -> {inner : {x : Word | r} | s}.
putNested w p = {p | inner.x = w}.
getNested : {inner : {x : Word | r} | s} -> Word.
getNested p = p.inner.x.
bumpMany : Word -> {x : Word | r} -> Word.
bumpMany n p = if Word.eq n (Word.fromInt 0) then get p else bumpMany (Word.sub n (Word.fromInt 1)) (put (Word.add (get p) (Word.fromInt 1)) p).
makeOnes : Word -> List {x : Word}.
makeOnes w = [{x=w},{x=Word.not w}].
makeTwos : Word -> List {x : Word, y : Word}.
makeTwos w = [{x=w,y=w},{x=Word.not w,y=Word.not w}].
sumRecords : List {x : Word | r} -> Word.
sumRecords xs = case xs of [] -> Word.fromInt 0 | p :: rest -> Word.add (get p) (sumRecords rest).
bumpRecords : Word -> List {x : Word | r} -> List {x : Word | r}.
bumpRecords delta xs = case xs of [] -> [] | p :: rest -> put (Word.add (get p) delta) p :: bumpRecords delta rest.
'''
EXPORTS = 'get,put,makeOne,makeTwo,makeText,makeFloat,getDouble,getFloat,makeNested,makeSmall,putNested,getNested,bumpMany,makeOnes,makeTwos,sumRecords,bumpRecords'

PROBE = r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void);
extern V makeOne(uw),makeTwo(uw),makeText(intptr_t,uw),put(uw,V);
extern V makeFloat(double,float),makeNested(intptr_t,uw),makeSmall(uw),putNested(uw,V);
extern uw get(V),getNested(V);
extern uw bumpMany(uw,V);
extern V makeOnes(uw),makeTwos(uw),bumpRecords(uw,V);
extern uw sumRecords(V);
extern double getDouble(V);
extern float getFloat(V);
extern V fpr_fn__x24arc_x2euniformTagEq(V,V,V);
#define check(b) do{if(!(b))fpr_cpanic("open row oracle: " #b);}while(0)
static V field(V p,uw i){check(i<fpr_builtin_field_count(p));check(fpr_builtin_field_kind(p,i)=='t');return ((V*)(p+8))[i];}
static uw bits(V p){check(TID(p)==T_BITS && ((bits_t*)p)->var==2);return ((bits_t*)p)->val;}
V __wrap_fpr_fn_main(void){
 uw live=fpr_builtin_live_allocations();
#if TEST_CASE == 1
 get(makeFloat(1.0,2.0f));
#elif TEST_CASE == 2
 V p=makeOne(7);static const struct{uint32_t tid,var;uw len;char s[1];}layout={T_STR,0,1,{'w'}};
 fpr_builtin_set_layout(p,(V)&layout);get(p);
#elif TEST_CASE == 3
 fpr_fn__x24arc_x2euniformTagEq(makeOne(7),TAG(-1),TAG(1));
#else
 for(uw i=1;i<=128;i++){
  uw w=0xfedcba9876543210ULL^i;
  V p=makeOne(w),held=fpr_builtin_retain(p);
  check(get(put(w+1,p))==w+1 && get(held)==w);
  p=makeTwo(w);V old=fpr_builtin_retain(p),extra=field(p,1);
  V q=put(w+3,p);check(bits(field(q,0))==w+3 && field(q,1)==extra && bits(extra)==~w);
  check(get(old)==w);fpr_builtin_release(q);
  p=makeText(i,w);old=fpr_builtin_retain(p);extra=field(p,0);
  q=put(w+4,p);check(field(q,0)==extra && ((str_t*)extra)->len==(i<10?1:i<100?2:3));
  check(get(old)==w && get(q)==w+4);
  p=makeNested(i,w);old=fpr_builtin_retain(p);extra=field(p,1);V text=field(field(p,0),0);
  q=putNested(w+5,p);check(field(q,1)==extra && field(field(q,0),0)==text);
  check(bits(field(extra,0))==w && bits(field(field(extra,1),0))==~w);
  check(getNested(old)==w && getNested(q)==w+5);
  check(getNested(putNested(w+6,makeSmall(w)))==w+6);
  check(bumpMany(17,makeText(i,w))==w+17);
  check(sumRecords(makeOnes(w))==~(uw)0 && sumRecords(makeTwos(w))==~(uw)0);
  check(sumRecords(bumpRecords(3,makeOnes(w)))==5 && sumRecords(bumpRecords(7,makeTwos(w)))==13);
  union{uw bits;double value;}d={.bits=i==1?0x8000000000000000ULL:0x7ff8000000000011ULL+i},rd;
  union{uint32_t bits;float value;}f={.bits=i==1?0x80000000U:0x7fc00011U+(uint32_t)i},rf;
  p=makeFloat(d.value,f.value);rd.value=getDouble(fpr_builtin_retain(p));rf.value=getFloat(p);
  check(rd.bits==d.bits && rf.bits==f.bits);
  p=makeTwo(w);uw tid=TID(p),variant=((hdr_t*)p)->var;
  check(fpr_fn__x24arc_x2euniformTagEq(fpr_builtin_retain(p),TAG(tid+1),TAG(variant))==(V)&fpr_false);
  check(fpr_fn__x24arc_x2euniformTagEq(fpr_builtin_retain(p),TAG(tid),TAG(variant+1))==(V)&fpr_false);
  check(fpr_fn__x24arc_x2euniformTagEq(p,TAG(tid),TAG(variant))==(V)&fpr_true);
  check(fpr_fn__x24arc_x2euniformTagEq(TAG(i),TAG(tid),TAG(variant))==(V)&fpr_false);
  check(fpr_builtin_live_allocations()==live);
 }
 volatile unsigned char*uart=(void*)0x10000000;const char*s="OPEN_ROWS_PASS\n";
 for(;*s;s++){while(!(uart[5]&32)){}uart[0]=*s;}
#endif
 return __real_fpr_fn_main();
}
'''


def effects(tmp,env,rollback,host=False):
    header=('get : {x : Word | r} -> Word.\nget p = p.x.\n'
            'say n = _ = print n; n.\n')
    nested=header+('put : Word -> {inner : {x : Word | r} | s} -> {inner : {x : Word | r} | s}.\n'
                   'put w p = {p | inner.x = w}.\n')
    cases=[
        ('ordered',nested+'main = a=put (Word.fromInt (say 1)) {inner={x=Word.fromInt (say 2)}}; b=put (Word.fromInt (say 3)) {inner={label=str (say 4),x=Word.fromInt (say 5)},other=say 6}; _=print (get a.inner); print (get b.inner).\n',0,['1','2','3','4','5','6','1','3'],None),
        ('unused',header+'main = print (get {x=Word.fromInt (say 1),z=17 / (say 0)}).\n',1,['1','0'],'division by zero'),
        ('nested-unused',nested+'main = p=put (Word.fromInt (say 1)) {inner={x=Word.fromInt (say 2),z=17 / (say 0)}}; print (get p.inner).\n',1,['1','2','0'],'division by zero'),
        ('branch',header+'choose flag = if flag then {x=Word.fromInt (say 7),extra="ok"} else error "wrong arm".\nmain = print (get (choose True)).\n',0,['7','7'],None),
        ('generic',header+'pick p = p.value.\nmain = _=print (pick {value=7}); _=print (pick {extra="ok",value=Word.fromInt 9}); print (pick {value="text"}).\n',0,['7','9','text'],None),
        ('tag-fallthrough','Box = Type (Box a).\nchoose : Box -> Int.\nchoose b = case b of Box (x :: rest) -> 1 | _ -> 99.\nflag : Box -> Int.\nflag b = case b of Box True -> 1 | Box False -> 2 | _ -> 0.\nmain = _=print (choose (Box 7)); _=print (choose (Box [])); _=print (choose (Box [2])); _=print (flag (Box 7)); _=print (flag (Box True)); _=print (flag (Box False)); print (flag (Box [2])).\n',0,['99','99','1','0','1','2','0'],None),
    ]
    for name,value,op in [('maximum','intMax Unit','+'),('minimum','intMin Unit','-')]:
        cases.append((name,header+'main = print (get {x=Word.fromInt (say 1),z=(say ('+value+')) '+op+' 1}).\n',1,['1',str(2**62-1 if name=='maximum' else -2**62)],'overflow'))
    records={}
    for name,code,status,prefix,message in cases:
        # Hosted Base has no builtin Word HAL. Use its checked Int analogue
        # for the same row/effect operations; raw Word/IEEE bits are tested by C.
        host_code='unsafe base.\nidentityInt : Int -> Int.\nidentityInt n = n.\n'+code.replace('Word.fromInt','identityInt').replace('Word','Int')
        source=tmp/f'effect-{host}-{rollback}-{name}.fpr';source.write_text(host_code if host else code)
        build=source.with_suffix('');image=build.with_suffix('.elf')
        if host:
            native_env=dict(env);native_env.pop('FPR_NO_INLINE',None)
            run([ROOT/'fpr','build',source,'--harts','4','-o',build],env=native_env)
            observations=[]
            for harts in (1,4):
                p=subprocess.run([str(build)],env=dict(native_env,FPR_HARTS=str(harts)),cwd=ROOT,capture_output=True,text=True,timeout=60)
                assert (p.returncode==0)==(status==0) and p.stdout.splitlines()==prefix,(name,p.returncode,p.stdout,p.stderr)
                if message:assert message in p.stderr,(name,p.stderr)
                observations.append(dict(harts=harts,status=p.returncode,stdout=p.stdout,stderr=p.stderr))
            records[name]=observations
            continue
        run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1','HEAP=c',f'PROG={source}',f'BUILD={build}',f'IMAGE={image}'],env=env)
        output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],expected=status)
        lines=output.splitlines()
        assert (lines[:-1]==prefix and message in lines[-1]) if message else lines==prefix,(name,output,prefix)
        records[name]=dict(status=status,output=output)
    print(f'{rollback=}, {host=}: generic payloads, nested effects, unused fields, dead branch and overflow endpoints PASS',flush=True)
    return records


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--record',type=Path)
    ap.add_argument('--quick',action='store_true')
    ap.add_argument('--baseline-compiler',type=Path)
    args=ap.parse_args()
    record=dict(schema='open-rows-v1',compiler_sha256=hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),
                test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),records=[],effects={})
    with tempfile.TemporaryDirectory(prefix='fpr-open-rows-') as directory:
        tmp=Path(directory);source=tmp/'rows.fpr';source.write_text(SOURCE)
        entry=tmp/'main.fpr';entry.write_text('main = Unit.\n')
        if args.baseline_compiler:
            env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
            env.update(FPR_HOME=str(ROOT),FPR_NO_INLINE='1',FPR_NO_TYPE_SPEC='1',XDG_CACHE_HOME=str(tmp/'before-cache'))
            output=run([args.baseline_compiler,'--profile=bare-metal-builtin','--arc','--lib',f'--export={EXPORTS}',source,tmp/'before.s'],env=env,expected=1)
            assert 'not a C-representable type' in output,output
            internal=tmp/'before-internal.fpr'
            internal.write_text('get : {x : Word | r} -> Word.\nget p = p.x.\nmain = _=print (get {x=Word.fromInt 7}); print (get {x=Word.fromInt 9,text="ok"}).\n')
            diagnostic=run([args.baseline_compiler,'--profile=bare-metal-builtin','--arc',internal,tmp/'before-internal.s'],env=env,expected=1)
            assert 'incompatible representations' in diagnostic,diagnostic
            record['baseline']=dict(compiler_sha256=hashlib.sha256(args.baseline_compiler.read_bytes()).hexdigest(),public_refusal=output,internal_refusal=diagnostic)
        for rollback in ([True] if args.quick else [False,True]):
            env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
            env.update(FPR_HOME=str(ROOT),FPR_NO_INLINE='1',XDG_CACHE_HOME=str(tmp/f'cache-{rollback}'))
            if rollback:env['FPR_NO_TYPE_SPEC']='1'
            refused=tmp/f'raw-{rollback}.s'
            diagnostic=run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--raw','--lib',
                            '--export=get,put',source,refused],env=env,expected=1)
            assert 'not a C-representable type' in diagnostic and not refused.exists(),diagnostic
            record.setdefault('raw_refusals',{})[str(rollback)]=diagnostic
            if not args.quick:
                record['effects'][str(rollback)]=effects(tmp,env,rollback)
                if not rollback:record['native_base']=effects(tmp,env,rollback,host=True)
            for abi in (['soft'] if args.quick else ['soft','hard']):
                asm=tmp/f'rows-{rollback}-{abi}.s'
                run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--lib',f'--float-abi={abi}',f'--export={EXPORTS}',source,asm],env=env)
                assert 'uniformTagEq' in asm.read_text() and 'uniformProject' in asm.read_text()
                for allocator in (['c'] if args.quick else ['c','fpr']):
                    for case,message in ([(0,'OPEN_ROWS_PASS')] if args.quick else [(0,'OPEN_ROWS_PASS'),(1,'uniform scalar representation mismatch'),(2,'uniform field representation mismatch'),(3,'uniform tag test descriptor mismatch')]):
                        probe=tmp/f'probe-{case}.c';probe.write_text(f'#define TEST_CASE {case}\n'+PROBE)
                        build=tmp/f'build-{rollback}-{abi}-{allocator}-{case}';image=build.with_suffix('.elf')
                        run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1',f'HEAP={allocator}',
                            'BUILTIN_HEAP_BYTES=1048576',f'PROG={entry}',f'BUILD={build}',f'IMAGE={image}',
                            f'BUILTIN_EXTRA={asm} {probe}','BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main',
                            f'ARCHFLAGS=-march=rv64imafdc_zicsr -mabi={"lp64d" if abi=="hard" else "lp64"} -mcmodel=medany',
                            f'FPRC_FLAGS=--float-abi={abi}'],env=env)
                        output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],expected=int(case!=0))
                        assert message in output,output
                        record['records'].append(dict(rollback=rollback,abi=abi,allocator=allocator,case=case,output=output))
                        print(f'{rollback=}, {abi}, {allocator}, case {case}: open-row boundaries PASS',flush=True)
    if record['effects']:assert record['effects']['False']==record['effects']['True']
    if args.record:args.record.write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':main()
