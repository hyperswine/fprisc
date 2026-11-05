#!/usr/bin/env python3
"""Checked builtin product values: private packets, tagged boundaries and ARC."""
import os
from pathlib import Path
import re
import tempfile
from check_uniform_aggregate import ROOT, run

SOURCE = '''profile builtin.
Pair a = Type (Pair a a).
makePair : Word -> Pair Word.
makePair x = Pair x x.
readPair : Pair Word -> Word.
readPair p = case p of Pair a b -> Word.add a b.
advance : Pair Word -> Pair Word.
advance p = case p of Pair a b -> Pair (Word.add a (Word.fromInt 1)) (Word.add b (Word.fromInt 1)).
loop : Int -> Pair Word -> Word.
loop n p = if n == 0 then readPair p else loop (n - 1) (advance p).
runLoop : Int -> Word.
runLoop n = loop n (makePair (Word.fromInt 1)).
explicit : Int -> Word -> Word -> Word.
explicit n a b = if n == 0 then Word.add a b else explicit (n - 1) (Word.add a (Word.fromInt 1)) (Word.add b (Word.fromInt 1)).
runExplicit : Int -> Word.
runExplicit n = explicit n (Word.fromInt 1) (Word.fromInt 1).
localPair : Word -> Word.
localPair n = p = Pair n n; readPair p.
branchPair : Bool -> Word -> Word.
branchPair flag n = p = if flag then Pair n n else Pair (Word.fromInt 0) (Word.fromInt 0); readPair p.
constantPair : Pair Word.
constantPair = Pair (Word.fromInt 3) (Word.fromInt 7).
constantValue : Unit -> Word.
constantValue u = readPair constantPair.
identity : a -> a.
identity x = x.
roundTrip : Pair Word -> Pair Word.
roundTrip p = identity p.
heapPair : Word -> Word.
heapPair n = xs = [makePair n,makePair n]; case xs of a :: b :: rest -> Word.add (readPair a) (readPair b) | _ -> Word.fromInt 0.
Wrap a = Type (Wrap a).
Nested = Type (Nested (Wrap Word) (Wrap Word)).
nestedValue : Word -> Word.
nestedValue n = p = Nested (Wrap n) (Wrap n); case p of Nested (Wrap a) (Wrap b) -> Word.add a b.
Mixed = Type (Mixed Word F64 F32 Addr Int Bool Unit).
makeMixed : Word -> F64 -> F32 -> Addr -> Int -> Bool -> Unit -> Mixed.
makeMixed w d f a i b u = Mixed w d f a i b u.
getWord : Mixed -> Word.
getWord m = case m of Mixed w d f a i b u -> w.
getDouble : Mixed -> F64.
getDouble m = case m of Mixed w d f a i b u -> d.
getFloat : Mixed -> F32.
getFloat m = case m of Mixed w d f a i b u -> f.
getAddr : Mixed -> Addr.
getAddr m = case m of Mixed w d f a i b u -> a.
getInt : Mixed -> Int.
getInt m = case m of Mixed w d f a i b u -> i.
getBool : Mixed -> Bool.
getBool m = case m of Mixed w d f a i b u -> b.
getUnit : Mixed -> Unit.
getUnit m = case m of Mixed w d f a i b u -> u.
localDouble : F64 -> F64.
localDouble d = getDouble (makeMixed (Word.fromInt 1) d (F32.ofInt 2) (Addr.fromWord (Word.fromInt 0)) 3 True Unit).
Eight = Type (Eight Word Word Word Word Word Word Word Word).
makeEight : Word -> Eight.
makeEight w = Eight w w w w w w w w.
readEight : Eight -> Word.
readEight p = case p of Eight a b c d e f g h -> Word.add a h.
branchEight : Bool -> Word -> Word.
branchEight flag w = p = if flag then makeEight w else makeEight (Word.fromInt 0); readEight p.
wideArguments : Eight -> Eight -> Eight -> Eight -> Eight -> Eight -> Eight -> Eight -> Eight -> Word.
wideArguments a b c d e f g h i = Word.add (readEight a) (readEight i).
wideBoundary : Word -> Word.
wideBoundary w = p = makeEight w; wideArguments p p p p p p p p p.
Nine = Type (Nine Word Word Word Word Word Word Word Word Word).
makeNine : Word -> Nine.
makeNine w = Nine w w w w w w w w w.
readNine : Nine -> Word.
readNine p = case p of Nine a b c d e f g h i -> Word.add a i.
TextPair = Type (TextPair String Word).
makeText : Word -> TextPair.
makeText w = TextPair (str (Word.toInt w)) w.
readText : TextPair -> Word.
readText p = case p of TextPair text w -> Word.add w (Word.fromInt (String.len text)).
exercise : Unit -> Unit.
exercise u = _ = print (makePair (Word.fromInt 7)); _ = print (identity (makePair (Word.fromInt 9))); Unit.
'''

PROBE = r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void),__real_fpr_builtin_alloc_adt(V,uw);
static uw allocations;
V __wrap_fpr_builtin_alloc_adt(V b,uw n){allocations++;return __real_fpr_builtin_alloc_adt(b,n);}
#define check(b) do{if(!(b))fpr_cpanic("product oracle: " #b);}while(0)
extern V makePair(uw),roundTrip(V),makeNine(uw),makeText(uw);
extern uw readPair(V),readNine(V),readText(V);
extern V makeMixed(uw,double,float,void*,intptr_t,int);
extern uw getWord(V);
extern double getDouble(V);
extern float getFloat(V);
extern void*getAddr(V);
extern intptr_t getInt(V);
extern int getBool(V);
extern void getUnit(V),exercise(void);
extern uw raw_loop(V) __asm__("RAW_LOOP");
extern uw raw_explicit(V) __asm__("RAW_EXPLICIT");
extern uw raw_local(uw) __asm__("RAW_LOCAL");
extern uw raw_nested(uw) __asm__("RAW_NESTED");
extern uw raw_branch(V,uw) __asm__("RAW_BRANCH");
extern uw raw_eight(V,uw) __asm__("RAW_EIGHT");
extern uw raw_wide(uw) __asm__("RAW_WIDE");
extern uw raw_constant(V) __asm__("RAW_CONSTANT");
extern uw raw_heap(uw) __asm__("RAW_HEAP");
extern uw raw_double(uw) __asm__("RAW_DOUBLE");
V __wrap_fpr_fn_main(void){
 uw live=fpr_builtin_live_allocations();
 for(uw i=1;i<=128;i++){
  uw bits=0xfedcba9876543210ULL^i,count=allocations;
  check(raw_local(bits)==2*bits && raw_nested(bits)==2*bits);
  check(raw_branch((V)&fpr_true,bits)==2*bits && raw_branch((V)&fpr_false,bits)==0);
  check(raw_constant((V)&fpr_unit)==10);
  check(raw_eight((V)&fpr_true,bits)==2*bits && raw_eight((V)&fpr_false,bits)==0);
  uw dbits=i==1?0x8000000000000000ULL:i==2?0x7ff8000000000011ULL:0x4014000000000000ULL;
  check(raw_double(dbits)==dbits);
 #if !BOXED
  check(allocations==count);
 #endif
  V p=makePair(bits);
  check(fpr_builtin_field_count(p)==2 && fpr_builtin_field_kind(p,0)=='t' && fpr_builtin_field_kind(p,1)=='t');
  V*fields=(V*)(p+8);check(TID(fields[0])==T_BITS && ((bits_t*)fields[0])->val==bits);
  V held=fpr_builtin_retain(p);
  check(readPair(roundTrip(p))==2*bits && readPair(held)==2*bits);
  check(raw_wide(bits)==4*bits);
  check(raw_heap(i)==4*i && readNine(makeNine(bits))==2*bits && readText(makeText(7))==8);
  union{uw bits;double value;}d={.bits=dbits};
  union{uint32_t bits;float value;}f={.bits=i==1?0x80000000U:i==2?0x7fc00011U:0x40e00000U};
  V m=makeMixed(bits,d.value,f.value,(void*)bits,-(intptr_t)i,i&1);
  check(fpr_builtin_field_count(m)==7);
  for(uw j=0;j<7;j++)check(fpr_builtin_field_kind(m,j)=='t');
  check(getWord(fpr_builtin_retain(m))==bits);
  union{uw bits;double value;}dr={.value=getDouble(fpr_builtin_retain(m))};check(dr.bits==d.bits);
  union{uint32_t bits;float value;}fr={.value=getFloat(fpr_builtin_retain(m))};check(fr.bits==f.bits);
  check(getAddr(fpr_builtin_retain(m))==(void*)bits);
  check(getInt(fpr_builtin_retain(m))==-(intptr_t)i);
  check(getBool(fpr_builtin_retain(m))==(int)(i&1));getUnit(m);
  check(fpr_builtin_live_allocations()==live);
 }
 uw count=allocations;
 check(raw_loop(TAG(10000))==20002);
 #if BOXED
 check(allocations-count==10001);
 #else
 check(allocations==count);
 #endif
 count=allocations;check(raw_explicit(TAG(10000))==20002 && allocations==count);
 exercise();check(fpr_builtin_live_allocations()==live);
 volatile unsigned char*uart=(void*)0x10000000;const char*s="BUILTIN_PRODUCTS_PASS\n";
 for(;*s;s++){while(!(uart[5]&32)){}uart[0]=*s;}return __real_fpr_fn_main();}
'''


def effects(tmp, env, mode):
    header = ('Pair = Type (Pair Int Int).\n'
              'make : Int -> Pair.\nmake n = _ = print n; Pair n n.\n'
              'consume : Pair -> Pair -> Unit.\n'
              'consume a b = _ = print 99; case (a,b) of (Pair x _,Pair y _) -> print (x + y).\n')
    programs = [
        ('ordered', header+'main = consume (make 1) (make 2).\n', 0, ['1','2','99','3'], None),
        ('division', header+'fail u = _ = print 2; Pair 7 (17 / 0).\nmain = consume (make 1) (fail Unit).\n', 1, ['1','2'], 'division by zero'),
        ('unused', header+'readFirst : Pair -> Int.\nreadFirst p = case p of Pair x _ -> x.\nmain = print (readFirst (Pair 7 (17 / 0))).\n', 1, [], 'division by zero'),
        ('branch', header+'choose : Bool -> Pair.\nchoose b = if b then make 4 else error "wrong arm".\nmain = case choose True of Pair x y -> print (x+y).\n', 0, ['4','8'], None),
    ]
    for label,endpoint,op in [('maximum','intMax','+'),('minimum','intMin','-')]:
        programs.append((label,header+'step : Pair -> Pair.\nstep p = case p of Pair x y -> Pair (x '+op+' 1) y.\nmain = print (step (make ('+endpoint+' Unit))).\n', 1, None, 'overflow'))
    for label,code,status,prefix,message in programs:
        source=tmp/f'effects-{mode}-{label}.fpr';source.write_text(code)
        build=source.with_suffix('');image=build.with_suffix('.elf')
        run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1','HEAP=c',
             f'PROG={source}',f'BUILD={build}',f'IMAGE={image}'],env=env)
        output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],expected=status)
        lines=output.splitlines()
        if message:
            assert message in output and '99' not in lines,output
            if prefix is not None:assert lines[:len(prefix)]==prefix,output
            else:assert re.fullmatch(r'-?[0-9]+',lines[0]),output
        else:assert lines==prefix,output
    print(f'{mode}: strict effects, dead-arm choice, unused-field traps and integer limits PASS',flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-builtin-products-') as directory:
        tmp=Path(directory)
        source=tmp/'products.fpr';source.write_text(SOURCE)
        entry=tmp/'main.fpr';entry.write_text('main = Unit.\n')
        exports=','.join(n for n in re.findall(r'^(\w+) :',SOURCE,re.M) if n!='wideArguments')
        for boxed,rollback in ((False,False),(False,True),(True,False)):
            env=dict(os.environ,FPR_NO_INLINE='1')
            for flag in ('FPR_NO_TYPE_SPEC','FPR_NO_PAIR_RETURNS'):env.pop(flag,None)
            if boxed:env['FPR_NO_PAIR_RETURNS']='1'
            if rollback:env['FPR_NO_TYPE_SPEC']='1'
            effects(tmp,env,f'{boxed}-{rollback}')
            for abi in ('soft','hard'):
                asm=tmp/f'products-{boxed}-{rollback}-{abi}.s'
                run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--lib',f'--float-abi={abi}',f'--export={exports}',source,asm],env=env)
                text=asm.read_text()
                assert not re.search(r'\b(?:call|tail) .*product_x2e(?:pack|value)',text),text
                def worker(name):
                    match=re.search(r'^# fn \$uniform\.raw\.'+name+r'\S* .*?^    \.globl (\S+)',text,re.M|re.S)
                    assert match,name
                    return match[1]
                body=f'#define BOXED {int(boxed)}\n'+PROBE
                for key,name in [('LOOP','runLoop'),('EXPLICIT','runExplicit'),('LOCAL','localPair'),('NESTED','nestedValue'),
                                 ('BRANCH','branchPair'),('CONSTANT','constantValue'),('HEAP','heapPair'),('DOUBLE','localDouble'),('EIGHT','branchEight'),('WIDE','wideBoundary')]:
                    body=body.replace('RAW_'+key,worker(name))
                probe=tmp/f'probe-{boxed}-{rollback}-{abi}.c';probe.write_text(body)
                for allocator in ('c','fpr'):
                    build=tmp/f'build-{boxed}-{rollback}-{abi}-{allocator}';image=build.with_suffix('.elf')
                    run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1',f'HEAP={allocator}','BUILTIN_HEAP_BYTES=1048576',
                         f'PROG={entry}',f'BUILD={build}',f'IMAGE={image}',f'BUILTIN_EXTRA={asm} {probe}',
                         'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main -Wl,--wrap=fpr_builtin_alloc_adt',
                         f'ARCHFLAGS=-march=rv64imafdc_zicsr -mabi={"lp64d" if abi=="hard" else "lp64"} -mcmodel=medany',
                         f'FPRC_FLAGS=--float-abi={abi}'],env=env)
                    output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image])
                    lines=output.splitlines()
                    assert len(lines)==3 and re.fullmatch(r'<[0-9]+\.0>',lines[0]) and lines==[lines[0],lines[0],'BUILTIN_PRODUCTS_PASS'],output
                    print(f'{allocator}, {abi}, boxed={boxed}, type-spec rollback={rollback}: packets, joins, public/generic/heap boundaries, exact bits and ARC PASS; loop allocations={10001 if boxed else 0}, explicit=0',flush=True)

if __name__=='__main__':main()
