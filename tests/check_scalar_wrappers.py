#!/usr/bin/env python3
"""Checked scalar wrappers: nominal boundaries, raw storage and ownership."""
import os
from pathlib import Path
import re
import tempfile
from check_uniform_aggregate import ROOT, run

VALIDATION_PROBE = r'''
#include "builtin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "uniform.inc"
const hdr_t fpr_unit={T_UNIT,0},fpr_false={T_BOOL,0},fpr_true={T_BOOL,1};
static _Alignas(16) unsigned char arena[8*1024*1024];
void fpr_cpanic(const char*s){fprintf(stderr,"%s\n",s);exit(1);}
str_t*fpr_mkstr(const uint8_t*bytes,uw n){str_t*s=(str_t*)fpr_builtin_alloc_adt(sizeof(str_t)+n,0);
 s->tid=T_STR;s->var=0;s->len=n;memcpy(s->bytes,bytes,n);return s;}
#define STR(name,text) static const struct {uint32_t tid,var;uw len;uint8_t bytes[sizeof(text)];} name={T_STR,0,sizeof(text)-1,text}
STR(word_layout,"w");STR(tagged_layout,"t");
static const hdr_t descriptor_nil={0x1fff0001,0};
static void check(int b){if(!b)fpr_cpanic("scalar wrapper oracle");}
static V descriptors(uw count,const void*layout){V xs=(V)&descriptor_nil;
 while(count--){V p=fpr_builtin_alloc_adt(24,2);((hdr_t*)p)->tid=0x1fff0001;((hdr_t*)p)->var=1;
 ((V*)(p+8))[0]=(V)layout;((V*)(p+8))[1]=xs;xs=p;}return xs;}
int main(void){fpr_builtin_heap_init(arena,arena+sizeof arena);
 const uw count=TEST_CASE?1:6000;
 char*text=malloc(128*count+64);size_t len=snprintf(text,64,"U3 9 %lu ",(unsigned long)count);
 for(uw i=0;i<count;i++)len+=snprintf(text+len,128,"%lu 1 1 0 1 %lu ",(unsigned long)(0x20001000+i),
   (unsigned long)(i+1==count?1:i+10));
 #if TEST_CASE == 1
 strcpy(text,"U3 9 1 536875008 1 1 0 1 9 ");len=strlen(text); /* scalar cycle */
 #elif TEST_CASE == 2
 strcpy(text,"U3 9 1 536875008 1 1 0 1 6 ");len=strlen(text); /* string payload */
 #elif TEST_CASE == 3
 strcpy(text,"U3 9 1 536875008 1 1 0 2 1 1 ");len=strlen(text); /* multi-field scalar */
 #endif
 V plan=(V)fpr_mkstr((const uint8_t*)text,len);free(text);
 uw bits=0xfedcba9876543210ULL;
 V boxed=fpr_fn__x24arc_x2euniformBoxAggregate(bits,fpr_builtin_retain(plan),descriptors(count,&word_layout));
 V at=boxed;
 for(uw i=0;i<count;i++){
  check(TID(at)==0x20001000+i && ((hdr_t*)at)->var==0 && fpr_builtin_field_count(at)==1);
  check(fpr_builtin_field_kind(at,0)=='t');at=((V*)(at+8))[0];
 }
 check(TID(at)==T_BITS && ((bits_t*)at)->var==2 && ((bits_t*)at)->val==bits);
 #if TEST_CASE == 4
 ((hdr_t*)boxed)->tid++;
 #elif TEST_CASE == 5
 ((bits_t*)at)->var=3; /* Addr does not satisfy Word */
 #elif TEST_CASE == 6
 fpr_builtin_set_layout(boxed,(V)&word_layout); /* foreign raw slot is not tagged */
 #endif
 check(fpr_fn__x24arc_x2euniformUnboxAggregate(boxed,plan,descriptors(count,&word_layout))==bits);
 check(!fpr_builtin_live_allocations());puts("SCALAR_CHAIN_PASS");return 0;}
'''

SOURCE = '''profile builtin.
Wrap a = Type (Wrap a).
makeWord : Word -> Wrap Word.
makeWord x = Wrap x.
readWord : Wrap Word -> Word.
readWord x = case x of Wrap y -> y.
makeInt : Int -> Wrap Int.
makeInt x = Wrap x.
readInt : Wrap Int -> Int.
readInt x = case x of Wrap y -> y.
makeFlag : Bool -> Wrap Bool.
makeFlag x = Wrap x.
readFlag : Wrap Bool -> Bool.
readFlag x = case x of Wrap y -> y.
makeUnit : Unit -> Wrap Unit.
makeUnit u = Wrap u.
readUnit : Wrap Unit -> Unit.
readUnit x = case x of Wrap y -> y.
makeRecord : Word -> {value: Word}.
makeRecord x = {value = x}.
readRecord : {value: Word} -> Word.
readRecord x = x.value.
makeDouble : F64 -> Wrap F64.
makeDouble x = Wrap x.
readDouble : Wrap F64 -> F64.
readDouble x = case x of Wrap y -> y.
makeFloat : F32 -> Wrap F32.
makeFloat x = Wrap x.
readFloat : Wrap F32 -> F32.
readFloat x = case x of Wrap y -> y.
makeAddr : Addr -> Wrap Addr.
makeAddr x = Wrap x.
readAddr : Wrap Addr -> Addr.
readAddr x = case x of Wrap y -> y.
makeNested : Word -> Wrap (Wrap Word).
makeNested x = Wrap (Wrap x).
readNested : Wrap (Wrap Word) -> Word.
readNested x = case x of Wrap (Wrap y) -> y.
makeWords : Word -> (Wrap Word, Wrap Word).
makeWords x = (Wrap x,Wrap x).
readWords : (Wrap Word, Wrap Word) -> Word.
readWords x = case x of (Wrap a,Wrap b) -> Word.add a b.
identity : a -> a.
identity x = x.
roundTrip : Wrap Word -> Wrap Word.
roundTrip x = identity x.
advance : Wrap Word -> Wrap Word.
advance x = case x of Wrap y -> Wrap (Word.add y (Word.fromInt 1)).
loopWrapped : Int -> Wrap Word -> Word.
loopWrapped n x = if n == 0 then readWord x else loopWrapped (n - 1) (advance x).
runWrapped : Int -> Word.
runWrapped n = loopWrapped n (makeWord (Word.fromInt 1)).
advanceExplicit : Word -> Word.
advanceExplicit x = Word.add x (Word.fromInt 1).
loopExplicit : Int -> Word -> Word.
loopExplicit n x = if n == 0 then x else loopExplicit (n - 1) (advanceExplicit x).
runExplicit : Int -> Word.
runExplicit n = loopExplicit n (Word.fromInt 1).
exercise : Unit -> Unit.
exercise u =
 nan = makeDouble (f64frombits 2146959360 17);
 _ = if nan != nan then Unit else error "wrapped NaN equality";
 _ = if makeDouble (f64frombits 2147483648 0) == makeDouble 0.0 then Unit else error "wrapped signed zero equality";
 _ = print (makeWord (Word.fromInt 7));
 _ = print [makeWord (Word.fromInt 8)];
 _ = print (identity (makeWord (Word.fromInt 9)));
 _ = print (Wrap 10);
 _ = print (Wrap (Wrap 11));
 _ = print (Wrap "text");
 _ = print {value = makeWord (Word.fromInt 12)};
 Unit.
'''

PROBE = r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void);
extern void exercise(void);
extern V makeWord(uw),makeInt(intptr_t),makeFlag(int),makeDouble(double),makeFloat(float),makeAddr(void*),makeNested(uw),makeWords(uw),roundTrip(V);
extern uw readWord(V),readNested(V),readWords(V),readRecord(V);
extern V makeUnit(void),makeRecord(uw);
extern void readUnit(V);
extern intptr_t readInt(V);
extern int readFlag(V);
extern double readDouble(V);
extern float readFloat(V);
extern void*readAddr(V);
extern uw raw_make(uw) __asm__("RAW_MAKE");
extern uw raw_nested(uw) __asm__("RAW_NESTED");
extern uw raw_record(uw) __asm__("RAW_RECORD");
extern uw raw_wrapped(V) __asm__("RAW_WRAPPED");
extern uw raw_explicit(V) __asm__("RAW_EXPLICIT");
extern V __real_fpr_builtin_alloc_adt(V,uw);
static uw allocations;
V __wrap_fpr_builtin_alloc_adt(V bytes,uw fields){allocations++;return __real_fpr_builtin_alloc_adt(bytes,fields);}
#define check(b) do {if(!(b))fpr_cpanic("generated scalar oracle: " #b);} while(0)
V __wrap_fpr_fn_main(void){
 uw before=fpr_builtin_live_allocations();
 for(uw i=1;i<=128;i++){
  uw bits=0xfedcba9876543210ULL^i,counted=allocations;
  check(raw_make(bits)==bits && raw_nested(bits)==bits && raw_record(bits)==bits);
  check(allocations==counted); /* constructors are erased, including the nested wrapper */
  V word=makeWord(bits);
  check(fpr_builtin_field_count(word)==1 && fpr_builtin_field_kind(word,0)=='t');
  V value=((V*)(word+8))[0];check(TID(value)==T_BITS && ((bits_t*)value)->val==bits);
  V held=fpr_builtin_retain(word);
  check(readWord(roundTrip(word))==bits && readWord(held)==bits);
  check(readInt(makeInt(-(intptr_t)i))==-(intptr_t)i);
  check(readFlag(makeFlag(i&1))==(int)(i&1));
  readUnit(makeUnit());check(readRecord(makeRecord(bits))==bits);
  union{uw bits;double value;}d={.bits=i==1?0x8000000000000000ULL:i==2?0x7ff8000000000011ULL:0x4014000000000000ULL};
  union{uw bits;double value;}dr={.value=readDouble(makeDouble(d.value))};check(dr.bits==d.bits);
  union{uint32_t bits;float value;}f={.bits=i==1?0x80000000U:i==2?0x7fc00011U:0x40e00000U};
  union{uint32_t bits;float value;}fr={.value=readFloat(makeFloat(f.value))};check(fr.bits==f.bits);
  check(readAddr(makeAddr((void*)bits))==(void*)bits);
  check(readNested(makeNested(bits))==bits);
  check(readWords(makeWords(i))==2*i);
  check(fpr_builtin_live_allocations()==before);
 }
 uw counted=allocations;
 check(raw_wrapped(TAG(10000))==10001 && raw_explicit(TAG(10000))==10001);
 check(allocations==counted);
 exercise();
 check(fpr_builtin_live_allocations()==before);
 const char*s="SCALAR_WRAPPERS_PASS\n";volatile unsigned char*uart=(void*)0x10000000;
 for(;*s;s++){while(!(uart[5]&32)){}uart[0]=*s;}
 return __real_fpr_fn_main();}
'''


def sanitizer(tmp):
    for case in range(7):
        source=tmp/f'chain-{case}.c'
        source.write_text(f'#define TEST_CASE {case}\n'+VALIDATION_PROBE)
        binary=source.with_suffix('')
        run(['clang','-std=c11','-O1','-g','-DFPR_POSIX','-DFPR_BUILTIN_ARC','-Iruntime','-Imachine/builtin',
             '-fsanitize=address,undefined',source,'machine/builtin/heap.c','-o',binary])
        out=run([binary],expected=0 if case==0 else 1)
        expected='SCALAR_CHAIN_PASS' if case==0 else 'uniform scalar representation mismatch' if case==5 else 'uniform aggregate representation mismatch'
        assert expected in out and 'AddressSanitizer' not in out and 'runtime error:' not in out,out
    print('6000 nested scalar wrappers: iterative boxing/unboxing and malformed storage rejection under ASan/UBSan PASS',flush=True)


def effects(tmp,env,rollback):
    header=("Wrap = Type (Wrap Word).\n"
            "make : Int -> Wrap.\nmake n = _ = print n; Wrap (Word.fromInt n).\n"
            "consume : Wrap -> Wrap -> Unit.\n"
            "consume a b = _ = print 99; case (a,b) of (Wrap x,Wrap y) -> print (Word.toInt (Word.add x y)).\n")
    programs=[('ordered',header+'main = consume (make 1) (make 2).\n',0,['1','2','99','3'],None),
              ('trap',header+'fail u = _ = print 2; Wrap (Word.fromInt (17 / 0)).\n'
               +'main = consume (make 1) (fail Unit).\n',1,['1','2'],'division by zero'),
              ('pattern',header+'main = case make 4 of Wrap n -> print (Word.toInt n).\n',0,['4','4'],None)]
    for label,endpoint,op in [('maximum','intMax','+'),('minimum','intMin','-')]:
        code=('Wrap = Type (Wrap Int).\nmake : Int -> Wrap.\nmake n = _ = print 1; Wrap n.\n'
              'step : Wrap -> Wrap.\nstep x = case x of Wrap n -> Wrap (n '+op+' 1).\n'
              'main = print (step (make ('+endpoint+' Unit))).\n')
        programs.append((label,code,1,['1'],'overflow'))
    for label,code,status,prefix,message in programs:
        source=tmp/f'effects-{label}-{rollback}.fpr';source.write_text(code)
        build=source.with_suffix('');image=build.with_suffix('.elf')
        run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1','HEAP=c',
             f'PROG={source}',f'BUILD={build}',f'IMAGE={image}'],env=env)
        output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],expected=status)
        lines=output.splitlines()
        if message:assert lines[:len(prefix)]==prefix and message in output and '99' not in output,output
        else:assert lines==prefix,output
    print(f'rollback={rollback}: argument effects, integer-limit/division failures and pattern scrutinee execution PASS',flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-scalar-') as directory:
        tmp=Path(directory)
        sanitizer(tmp)
        local_evidence(tmp)
        main_source=tmp/'main.fpr';main_source.write_text('main = Unit.\n')
        library=tmp/'wrapper.fpr';library.write_text(SOURCE)
        exports=','.join(re.findall(r'^(\w+) :',SOURCE,re.M))
        for rollback in (False,True):
            env=dict(os.environ);env.pop('FPR_NO_TYPE_SPEC',None)
            if rollback:env['FPR_NO_TYPE_SPEC']='1'
            effects(tmp,env,rollback)
            for abi in ('soft','hard'):
                asm=tmp/f'wrapper-{rollback}-{abi}.s'
                run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--lib',f'--float-abi={abi}',f'--export={exports}',library,asm],env=env)
                def worker(name):
                    return re.search(r'^# fn \$uniform\.raw\.'+name+r'\S* .*?^    \.globl (\S+)',asm.read_text(),re.M|re.S).group(1)
                probe=tmp/f'probe-{rollback}-{abi}.c'
                probe.write_text(PROBE.replace('RAW_MAKE',worker('makeWord')).replace('RAW_NESTED',worker('makeNested')).replace('RAW_WRAPPED',worker('runWrapped')).replace('RAW_EXPLICIT',worker('runExplicit')).replace('RAW_RECORD',worker('makeRecord')))
                for allocator in ('c','fpr'):
                    build=tmp/f'build-{allocator}-{rollback}-{abi}';image=build.with_suffix('.elf')
                    run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1',f'HEAP={allocator}','BUILTIN_HEAP_BYTES=1048576',
                         f'PROG={main_source}',f'BUILD={build}',f'IMAGE={image}',f'BUILTIN_EXTRA={asm} {probe}',
                         'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main -Wl,--wrap=fpr_builtin_alloc_adt',
                         f'ARCHFLAGS=-march=rv64imafdc_zicsr -mabi={"lp64d" if abi=="hard" else "lp64"} -mcmodel=medany',
                         f'FPRC_FLAGS=--float-abi={abi}'],env=env)
                    output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image])
                    # Baseline codegen167 printed nominal constructors, including the
                    # enclosing record; erasing wrappers must not print raw leaves.
                    lines=output.splitlines();tag=lines[0]
                    assert re.fullmatch(r'<[0-9]+\.0>',tag),output
                    assert lines==[tag,f'[{tag}]',tag,tag,tag,tag,
                        '<44028874.1>','SCALAR_WRAPPERS_PASS'],output
                    print(f'{allocator}, {abi}, rollback={rollback}: scalar kinds, nested/product fields, generic round trip, exact bits and ownership PASS',flush=True)



LOCAL_SOURCE = '''profile builtin.
LocalBox a = Type (LocalBox a).
localWord : Word -> Word.
localWord n = x = LocalBox n; case x of LocalBox v -> v.
localDouble : F64 -> F64.
localDouble n = x = LocalBox n; case x of LocalBox v -> v.
localRecord : Word -> Word.
localRecord n = x = {value = n}; x.value.
localNested : Word -> Word.
localNested n = x = LocalBox (LocalBox n); case x of LocalBox (LocalBox v) -> v.
localBranch : Bool -> Word -> Word.
localBranch b n = x = if b then LocalBox n else LocalBox (Word.fromInt 0); case x of LocalBox v -> v.
genericLocal : a -> Word -> a.
genericLocal x n = local = LocalBox n; _ = case local of LocalBox v -> if Word.eq v n then Unit else error "local generic check"; x.
'''

LOCAL_PROBE = r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void);
extern V __real_fpr_builtin_alloc_adt(V,uw);
static uw requests;
V __wrap_fpr_builtin_alloc_adt(V b,uw n){requests++;return __real_fpr_builtin_alloc_adt(b,n);}
extern uw word(uw) __asm__("LOCAL_WORD");
extern uw floating(uw) __asm__("LOCAL_DOUBLE");
extern uw record(uw) __asm__("LOCAL_RECORD");
extern uw nested(uw) __asm__("LOCAL_NESTED");
extern uw branch(V,uw) __asm__("LOCAL_BRANCH");
extern V generic(V,uw) __asm__("LOCAL_GENERIC");
V __wrap_fpr_fn_main(void){
 uw before=fpr_builtin_live_allocations(),count=requests;
 for(uw i=0;i<256;i++){
  uw n=0xfedcba9876543210ULL^i;
  if(word(n)!=n || record(n)!=n || nested(n)!=n || floating(0x7ff8000000000001ULL+i)!=0x7ff8000000000001ULL+i ||
     branch((V)&fpr_true,n)!=n || branch((V)&fpr_false,n)!=0)fpr_cpanic("local evidence oracle");
 #if !LOCAL_RAW
 if(generic(TAG(7),n)!=TAG(7))fpr_cpanic("local generic oracle");
 #endif
 }
 if(requests!=count || fpr_builtin_live_allocations()!=before)fpr_cpanic("local evidence allocation");
 volatile unsigned char*uart=(void*)0x10000000;const char*s="LOCAL_EVIDENCE_PASS\n";
 for(;*s;s++){while(!(uart[5]&32)){}uart[0]=*s;}return __real_fpr_fn_main();}
'''


def local_evidence(tmp):
    bad=tmp/'unbounded-layout.fpr'
    bad.write_text('Grow a = Type (More (Grow (List a))).\n'
                   'ignore : Grow Word -> Int.\nignore x = 0.\nmain = Unit.\n')
    output=bad.with_suffix('.s')
    refusal=run([ROOT/'fpr','--profile=bare-metal-builtin','--arc',bad,output],expected=1)
    assert 'finite layout graph' in refusal and 'CallStack' not in refusal and not output.exists(),refusal
    source=tmp/'local-evidence.fpr';source.write_text(LOCAL_SOURCE)
    main=tmp/'local-main.fpr';main.write_text('main = Unit.\n')
    names=re.findall(r'^(\w+) :',LOCAL_SOURCE,re.M)
    for raw in (False,True):
        for rollback in (False,True):
            env=dict(os.environ);env.pop('FPR_NO_TYPE_SPEC',None)
            if rollback:env['FPR_NO_TYPE_SPEC']='1'
            exports=[n for n in names if not raw or n!='genericLocal']
            asm=tmp/f'local-{raw}-{rollback}.s'
            run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--lib',*(['--raw'] if raw else []),
                 '--export='+','.join(exports),source,asm],env=env)
            text=asm.read_text()
            assert 'representation_x2elocal' not in text and '$representation.local.' not in text
            def symbol(name):
                if raw:
                    # Raw workers keep their qualified source names.
                    return re.search(r'^# fn '+name+r'\S* .*?^    \.globl (\S+)',text,re.M|re.S).group(1)
                return re.search(r'^# fn \$uniform\.raw\.'+name+r'\S* .*?^    \.globl (\S+)',text,re.M|re.S).group(1)
            probe=tmp/f'local-{raw}-{rollback}.c'
            body=f'#define LOCAL_RAW {int(raw)}\n'+LOCAL_PROBE
            for key,name in [('WORD','localWord'),('DOUBLE','localDouble'),('RECORD','localRecord'),
                             ('NESTED','localNested'),('BRANCH','localBranch'),('GENERIC','genericLocal')]:
                body=body.replace('LOCAL_'+key,'unused_generic' if raw and key=='GENERIC' else symbol(name))
            probe.write_text(body)
            for allocator in (('c',) if raw else ('c','fpr')):
                build=tmp/f'local-build-{raw}-{rollback}-{allocator}';image=build.with_suffix('.elf')
                run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1',f'HEAP={allocator}',
                     f'PROG={main}',f'BUILD={build}',f'IMAGE={image}',f'BUILTIN_EXTRA={asm} {probe}',
                     'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main -Wl,--wrap=fpr_builtin_alloc_adt'],env=env)
                output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image])
                assert 'LOCAL_EVIDENCE_PASS' in output,output
                print(f'local-only layouts: raw={raw}, rollback={rollback}, {allocator}: zero allocations and exact values PASS',flush=True)


if __name__=='__main__':main()
