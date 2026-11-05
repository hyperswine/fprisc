#!/usr/bin/env python3
"""Owned product fields: allocation parity, aliases, escapes and ARC lifetime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from check_uniform_aggregate import ROOT, run

SOURCE = '''profile builtin.
TextPair = Type (TextPair String Word).
go : Int -> TextPair -> Word.
go n p = case p of TextPair text w -> if n == 0 then Word.add w (Word.fromInt (String.len text)) else go (n - 1) (TextPair text (Word.add w (Word.fromInt 1))).
plain : Int -> String -> Word -> Word.
plain n text w = if n == 0 then Word.add w (Word.fromInt (String.len text)) else plain (n - 1) text (Word.add w (Word.fromInt 1)).
runOwned : Int -> Word.
runOwned n = go n (TextPair (str n) (Word.fromInt 0)).
runPlain : Int -> Word.
runPlain n = plain n (str n) (Word.fromInt 0).
makePublic : Int -> Word -> TextPair.
makePublic n w = TextPair (str n) w.
readPublic : TextPair -> Word.
readPublic p = case p of TextPair text w -> Word.add w (Word.fromInt (String.len text)).
textOf : TextPair -> String.
textOf p = case p of TextPair text w -> text.
takeText : Int -> String.
takeText n = textOf (TextPair (str n) (Word.fromInt n)).
identity : a -> a.
identity x = x.
roundTrip : TextPair -> TextPair.
roundTrip p = identity p.
Twin = Type (Twin String String).
select : Bool -> Twin -> Twin -> Twin.
select flag a b = if flag then a else b.
discard : Twin -> Word.
discard p = Word.fromInt 0.
hasTag : Twin -> Bool.
hasTag p = case p of Twin _ _ -> True.
readTwin : Twin -> Word.
readTwin p = case p of Twin a b -> Word.fromInt (String.len a + String.len b).
alias : Bool -> Int -> Word.
alias flag n = s = str n; p = Twin s s; q = select flag p p; _ = discard p; if hasTag q then readTwin q else Word.fromInt 99.
Outer = Type (Outer TextPair String).
nested : Int -> Word.
nested n = s = str n; p = Outer (TextPair s (Word.fromInt n)) s; case p of Outer q t -> Word.add (readPublic q) (Word.fromInt (String.len t)).
nestedGo : Int -> Outer -> Word.
nestedGo n p = case p of Outer inner other -> case inner of TextPair text w -> if n == 0 then Word.add w (Word.fromInt (String.len text + String.len other)) else nestedGo (n - 1) (Outer (TextPair text (Word.add w (Word.fromInt 1))) other).
runNested : Int -> Word.
runNested n = s = str n; nestedGo n (Outer (TextPair s (Word.fromInt 0)) s).
nestedPlain : Int -> String -> Word -> String -> Word.
nestedPlain n text w other = if n == 0 then Word.add w (Word.fromInt (String.len text + String.len other)) else nestedPlain (n - 1) text (Word.add w (Word.fromInt 1)) other.
runNestedPlain : Int -> Word.
runNestedPlain n = s = str n; nestedPlain n s (Word.fromInt 0) s.
makeNested : Int -> Word -> Outer.
makeNested n w = Outer (TextPair (str n) w) (str (n + 1000000)).
readNested : Outer -> Word.
readNested p = case p of Outer q t -> Word.add (readPublic q) (Word.fromInt (String.len t)).
roundNested : Outer -> Outer.
roundNested p = identity p.
nestedAlias : Bool -> Int -> Word.
nestedAlias flag n = s = str n; outer = Outer (TextPair s (Word.fromInt n)) s; alias = outer;
  case alias of Outer inner other -> q = inner; r = if flag then q else inner;
  Word.add (readPublic r) (readNested outer).
nestedHeap : Int -> Word.
nestedHeap n = s = str n; p = Outer (TextPair s (Word.fromInt n)) s; xs = [p,p];
  case xs of a :: b :: rest -> Word.add (readNested a) (readNested b) | _ -> Word.fromInt 99.
heap : Int -> Word.
heap n = s = str n; p = TextPair s (Word.fromInt n); xs = [p,p]; case xs of a :: b :: rest -> Word.add (readPublic a) (readPublic b) | _ -> Word.fromInt 99.
ListBox = Type (ListBox (List Int) Word).
listGo : Int -> ListBox -> Word.
listGo n p = case p of ListBox xs w -> if n == 0 then case xs of a :: b :: rest -> Word.add w (Word.fromInt (a + b)) | _ -> Word.fromInt 99 else listGo (n - 1) (ListBox xs (Word.add w (Word.fromInt 1))).
runList : Int -> Word.
runList n = listGo n (ListBox [n,n + 1] (Word.fromInt 0)).
listPlain : Int -> (List Int) -> Word -> Word.
listPlain n xs w = if n == 0 then case xs of a :: b :: rest -> Word.add w (Word.fromInt (a + b)) | _ -> Word.fromInt 99 else listPlain (n - 1) xs (Word.add w (Word.fromInt 1)).
runListPlain : Int -> Word.
runListPlain n = listPlain n [n,n + 1] (Word.fromInt 0).
Eight = Type (Eight String Word Word Word Word Word Word Word).
readEight : Eight -> Word.
readEight p = case p of Eight s a b c d e f g -> Word.add a (Word.fromInt (String.len s)).
wide : Eight -> Eight -> Eight -> Eight -> Eight -> Eight -> Eight -> Eight -> Eight -> Word.
wide a b c d e f g h i = Word.add (readEight a) (readEight i).
runWide : Int -> Word.
runWide n = p = Eight (str n) (Word.fromInt n) (Word.fromInt 0) (Word.fromInt 0) (Word.fromInt 0) (Word.fromInt 0) (Word.fromInt 0) (Word.fromInt 0); wide p p p p p p p p p.
'''


SINGLE_SOURCE = '''
TextShell = Type (TextShell String).
stepSingle : TextShell -> TextShell.
stepSingle p = case p of TextShell text -> TextShell text.
singleGo : Int -> Word -> TextShell -> Word.
singleGo n w p = case p of TextShell text -> if n == 0 then Word.add w (Word.fromInt (String.len text)) else singleGo (n - 1) (Word.add w (Word.fromInt 1)) (stepSingle p).
runSingle : Int -> Word.
runSingle n = singleGo n (Word.fromInt 0) (TextShell (str n)).
singlePlain : Int -> Word -> String -> Word.
singlePlain n w text = if n == 0 then Word.add w (Word.fromInt (String.len text)) else singlePlain (n - 1) (Word.add w (Word.fromInt 1)) text.
runSinglePlain : Int -> Word.
runSinglePlain n = singlePlain n (Word.fromInt 0) (str n).
ShellShell = Type (ShellShell TextShell).
doubleGo : Int -> Word -> ShellShell -> Word.
doubleGo n w p = case p of ShellShell inner -> case inner of TextShell text -> if n == 0 then Word.add w (Word.fromInt (String.len text)) else doubleGo (n - 1) (Word.add w (Word.fromInt 1)) (ShellShell (TextShell text)).
runDouble : Int -> Word.
runDouble n = doubleGo n (Word.fromInt 0) (ShellShell (TextShell (str n))).
makeSingle : Int -> TextShell.
makeSingle n = TextShell (str n).
readSingle : TextShell -> Word.
readSingle p = case p of TextShell text -> Word.fromInt (String.len text).
roundSingle : TextShell -> TextShell.
roundSingle p = identity p.
makeDouble : Int -> ShellShell.
makeDouble n = ShellShell (makeSingle n).
readDouble : ShellShell -> Word.
readDouble p = case p of ShellShell inner -> readSingle inner.
chooseSingle : Bool -> TextShell -> TextShell -> TextShell.
chooseSingle flag a b = if flag then a else b.
singleAlias : Bool -> Int -> Word.
singleAlias flag n = p = makeSingle n; q = chooseSingle flag p (stepSingle p); Word.add (readSingle p) (readSingle q).
singleHeap : Int -> Word.
singleHeap n = p = makeSingle n; xs = [p,p]; case xs of a :: b :: _ -> Word.add (readSingle a) (readSingle b) | _ -> Word.fromInt 99.
ListShell = Type (ListShell (List Int)).
singleListGo : Int -> Word -> ListShell -> Word.
singleListGo n w p = case p of ListShell xs -> if n == 0 then case xs of a :: b :: rest -> Word.add w (Word.fromInt (a + b)) | _ -> Word.fromInt 99 else singleListGo (n - 1) (Word.add w (Word.fromInt 1)) (ListShell xs).
runSingleList : Int -> Word.
runSingleList n = singleListGo n (Word.fromInt 0) (ListShell [n,n + 1]).
'''
SOURCE += SINGLE_SOURCE

PROBE = r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void),__real_fpr_builtin_alloc_adt(V,uw);
static uw allocations;
V __wrap_fpr_builtin_alloc_adt(V b,uw n){allocations++;return __real_fpr_builtin_alloc_adt(b,n);}
#define check(b) do{if(!(b))fpr_cpanic("owned product oracle: " #b);}while(0)
extern uw raw_owned(V) __asm__("RAW_OWNED"),raw_plain(V) __asm__("RAW_PLAIN");
extern uw raw_alias(V,V) __asm__("RAW_ALIAS");
extern uw raw_nested(V) __asm__("RAW_NESTED"),raw_heap(V) __asm__("RAW_HEAP");
extern uw raw_list(V) __asm__("RAW_LIST"),raw_wide(V) __asm__("RAW_WIDE");
extern uw raw_list_plain(V) __asm__("RAW_LIST_PLAIN");
extern uw raw_nested_loop(V) __asm__("RAW_NESTED_LOOP"),raw_nested_plain(V) __asm__("RAW_NESTED_PLAIN");
extern uw raw_nested_alias(V,V) __asm__("RAW_NESTED_ALIAS"),raw_nested_heap(V) __asm__("RAW_NESTED_HEAP");
extern uw raw_single(V) __asm__("RAW_SINGLE"),raw_single_plain(V) __asm__("RAW_SINGLE_PLAIN"),raw_double(V) __asm__("RAW_DOUBLE");
extern uw raw_single_list(V) __asm__("RAW_SINGLE_LIST"),raw_single_alias(V,V) __asm__("RAW_SINGLE_ALIAS"),raw_single_heap(V) __asm__("RAW_SINGLE_HEAP");
extern V makeSingle(intptr_t),roundSingle(V),makeDouble(intptr_t);
extern uw readSingle(V),readDouble(V);
extern V makeNested(intptr_t,uw),roundNested(V);
extern uw readNested(V);
extern V makePublic(intptr_t,uw),roundTrip(V);
extern V takeText(intptr_t);
extern uw readPublic(V);
static void say(const char*s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
static void number(uw n){char b[32];unsigned k=0;do{b[k++]='0'+n%10;n/=10;}while(n);while(k){char s[]={b[--k],0};say(s);}}
V __wrap_fpr_fn_main(void){
 uw live=fpr_builtin_live_allocations(),before=allocations;
 check(raw_owned(TAG(1000))==1004);
 uw owned=allocations-before;check(owned==(BOXED?1001:0));
 check(fpr_builtin_live_allocations()==live);before=allocations;
 check(raw_plain(TAG(1000))==1004 && allocations==before);
 check(fpr_builtin_live_allocations()==live);before=allocations;
 check(raw_list(TAG(1000))==3001);
 uw list_count=allocations-before;
 check(fpr_builtin_live_allocations()==live);before=allocations;
 check(raw_list_plain(TAG(1000))==3001);
 check(allocations-before==4 && list_count==(allocations-before)+(BOXED?1001:0));
 check(fpr_builtin_live_allocations()==live);
 before=allocations;check(raw_nested_loop(TAG(1000))==1008);
 uw nested_count=allocations-before;check(nested_count==(BOXED?2002:NESTED_BOXES*1001));
 check(fpr_builtin_live_allocations()==live);before=allocations;
 check(raw_nested_plain(TAG(1000))==1008 && allocations==before);
 check(fpr_builtin_live_allocations()==live);
 before=allocations;check(raw_single(TAG(1000))==1004);
 uw single_count=allocations-before;check(single_count==(BOXED?1001:SINGLE_BOXES*1001));
 check(fpr_builtin_live_allocations()==live);before=allocations;
 check(raw_single_plain(TAG(1000))==1004 && allocations==before);
 before=allocations;check(raw_double(TAG(1000))==1004);
 uw double_count=allocations-before;check(double_count==(BOXED?2002:SINGLE_BOXES*2002));
 check(fpr_builtin_live_allocations()==live);before=allocations;
 check(raw_single_list(TAG(1000))==3001 && allocations-before==4+(BOXED?1001:SINGLE_BOXES*1001));
 check(fpr_builtin_live_allocations()==live);
 for(intptr_t i=1;i<=128;i++){
  uw length=i<10?1:i<100?2:3;
  check(raw_alias((V)&fpr_true,TAG(i))==2*length);
  check(raw_alias((V)&fpr_false,TAG(i))==2*length);
  check(raw_nested(TAG(i))==(uw)i+2*length);
  check(raw_heap(TAG(i))==2*((uw)i+length));
  check(raw_wide(TAG(i))==2*((uw)i+length));
  check(raw_nested_alias((V)&fpr_true,TAG(i))==2*(uw)i+3*length);
  check(raw_nested_alias((V)&fpr_false,TAG(i))==2*(uw)i+3*length);
  check(raw_nested_heap(TAG(i))==2*((uw)i+2*length));
  check(raw_single_alias((V)&fpr_true,TAG(i))==2*length);
  check(raw_single_alias((V)&fpr_false,TAG(i))==2*length);
  check(raw_single_heap(TAG(i))==2*length);
  V shell=makeSingle(i);check(fpr_builtin_field_count(shell)==1 && fpr_builtin_field_kind(shell,0)=='t');
  V payload=*(V*)(shell+8);check(TID(payload)==T_STR && ((str_t*)payload)->len==length);
  V held_shell=fpr_builtin_retain(shell),round=roundSingle(shell);
  check(fpr_builtin_field_count(round)==1 && *(V*)(round+8)==payload);
  check(readSingle(round)==length && readSingle(held_shell)==length);
  V double_shell=makeDouble(i);check(fpr_builtin_field_count(double_shell)==1);
  V child=*(V*)(double_shell+8);check(fpr_builtin_field_count(child)==1 && TID(*(V*)(child+8))==T_STR);
  check(readDouble(double_shell)==length);
  uw bits=0xfedcba9876543210ULL^(uw)i;
  V p=makePublic(i,bits);
  check(fpr_builtin_field_count(p)==2);
  check(fpr_builtin_field_kind(p,0)=='t' && fpr_builtin_field_kind(p,1)=='t');
  V*fields=(V*)(p+8);check(TID(fields[1])==T_BITS && ((bits_t*)fields[1])->val==bits);
  V held=fpr_builtin_retain(p);
  check(readPublic(roundTrip(p))==bits+length);
  check(readPublic(held)==bits+length);
  V text=takeText(i);check(TID(text)==T_STR && ((str_t*)text)->len==length);
  V text_held=fpr_builtin_retain(text);fpr_builtin_release(text);
  check(((str_t*)text_held)->bytes[0]>='1' && ((str_t*)text_held)->bytes[0]<='9');
  fpr_builtin_release(text_held);
  V outer=makeNested(i,bits);check(fpr_builtin_field_count(outer)==2);
  check(fpr_builtin_field_kind(outer,0)=='t' && fpr_builtin_field_kind(outer,1)=='t');
  V inner=*(V*)(outer+8);check(fpr_builtin_field_count(inner)==2);
  check(fpr_builtin_field_kind(inner,0)=='t' && fpr_builtin_field_kind(inner,1)=='t');
  V nested_bits=*(V*)(inner+16);check(TID(nested_bits)==T_BITS && ((bits_t*)nested_bits)->val==bits);
  V kept_outer=fpr_builtin_retain(outer);
  check(readNested(roundNested(outer))==bits+length+7);
  check(readNested(kept_outer)==bits+length+7);
  check(fpr_builtin_live_allocations()==live);
 }
 say("owned ");number(owned);say(" plain 0\nnested ");number(nested_count);say(" plain 0\nsingle ");number(single_count);say(" double ");number(double_count);say(" plain 0\nOWNED_PRODUCTS_PASS\n");
 return __real_fpr_fn_main();
}
'''


def effects(tmp, env, mode):
    header = ('Pair = Type (Pair String Int).\n'
              'make : Int -> Pair.\nmake n = _ = print n; Pair (str n) n.\n'
              'consume : Pair -> Pair -> Unit.\n'
              'consume a b = _ = print 99; case (a,b) of (Pair s x,Pair t y) -> print (x+y+String.len s+String.len t).\n')
    cases = [
        ('ordered', header+'main = consume (make 1) (make 2).\n', 0, ['1','2','99','5'], None),
        ('division', header+'fail u = _ = print 2; Pair (str 2) (17 / 0).\nmain = consume (make 1) (fail Unit).\n', 1, ['1','2'], 'division by zero'),
        ('unused', header+'first : Pair -> String.\nfirst p = case p of Pair s _ -> s.\nmain = print (first (Pair (str 7) (17 / 0))).\n', 1, [], 'division by zero'),
        ('branch', header+'choose : Bool -> Pair.\nchoose b = if b then make 4 else error "wrong arm".\nmain = case choose True of Pair s x -> print (x+String.len s).\n', 0, ['4','5'], None),
    ]
    for label, endpoint, op, value in [('maximum','intMax','+',4611686018427387903),('minimum','intMin','-',-4611686018427387904)]:
        cases.append((label,header+'step : Pair -> Pair.\nstep p = case p of Pair s n -> Pair s (n '+op+' 1).\nmain = print (step (make ('+endpoint+' Unit))).\n',1,[str(value)],'overflow'))
    nested = (header+'Outer = Type (Outer Pair String).\n'
              'text : Int -> String.\ntext n = _ = print n; str n.\n'
              'wrap : Pair -> String -> Outer.\nwrap p s = Outer p s.\n'
              'read : Outer -> Int.\nread p = case p of Outer inner other -> case inner of Pair s n -> n+String.len s+String.len other.\n')
    cases += [
        ('nested-ordered',nested+'main = print (read (wrap (make 1) (text 2))).\n',0,['1','2','3'],None),
        ('nested-failure',nested+'fail u = _ = print 2; str (17 / 0).\nmain = print (read (wrap (make 1) (fail Unit))).\n',1,['1','2'],'division by zero'),
        ('nested-unused',nested+'first : Outer -> String.\nfirst p = case p of Outer inner other -> other.\nmain = print (first (wrap (Pair (text 1) (17 / 0)) (text 2))).\n',1,['1'],'division by zero'),
        ('nested-branch',nested+'choose : Bool -> Outer.\nchoose b = if b then wrap (make 4) (text 5) else error "wrong arm".\nmain = print (read (choose True)).\n',0,['4','5','6'],None),
    ]
    for label,endpoint,op,value in [('maximum','intMax','+',4611686018427387903),('minimum','intMin','-',-4611686018427387904)]:
        cases.append(('nested-'+label,nested+'step : Outer -> Outer.\nstep p = case p of Outer inner other -> case inner of Pair s n -> wrap (Pair s (n '+op+' 1)) other.\nmain = print (step (wrap (make ('+endpoint+' Unit)) (text 2))).\n',1,[str(value),'2'],'overflow'))
    one = 'Shell = Type (Shell String).\nmake : Int -> Shell.\nmake n = _ = print n; Shell (str n).\nignore : Shell -> Unit.\nignore p = Unit.\n'
    cases += [
        ('single-unused',one+'main = ignore (Shell (str (17 / 0))).\n',1,[],'division by zero'),
        ('single-order',one+'consume : Shell -> Shell -> Unit.\nconsume a b = print 99.\nmain = consume (make 1) (make 2).\n',0,['1','2','99'],None),
        ('single-branch',one+'choose : Bool -> Shell.\nchoose b = if b then make 7 else error "wrong arm".\nmain = case choose True of Shell s -> print s.\n',0,['7','7'],None),
    ]
    for label,endpoint,op,value in [('maximum','intMax','+',4611686018427387903),('minimum','intMin','-',-4611686018427387904)]:
        cases.append(('single-'+label,one+'say n = _=print n; n.\nmain = ignore (Shell (str ((say ('+endpoint+' Unit)) '+op+' 1))).\n',1,[str(value)],'overflow'))
    outputs = {}
    for label, source, status, prefix, message in cases:
        path=tmp/f'{mode}-{label}.fpr';path.write_text(source)
        image=path.with_suffix('.elf')
        run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1','HEAP=c',f'PROG={path}',f'BUILD={path.with_suffix("")}',f'IMAGE={image}'],env=env)
        output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],expected=status)
        lines=output.splitlines()
        if message:
            assert message in output and lines[:-1]==prefix,(label,output,prefix)
        else:
            assert lines==prefix,(label,output,prefix)
        outputs[label]=dict(status=status,output=output)
    print(f'{mode}: effects, strict unused fields, dead arms and integer endpoints PASS',flush=True)
    return outputs


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--quick',action='store_true',help='Only default soft-float/C-heap ownership oracle; skips the full matrix and effects')
    parser.add_argument('--normal-inline',action='store_true',help='Use ordinary inlining rather than isolating representation lowering')
    parser.add_argument('--compiler',type=Path,default=ROOT/'fpr',help='Compiler for the library under test; runtime remains the current checkout')
    parser.add_argument('--nested-boxes',type=int,choices=(0,1),default=0,help='Expected inner boxes per step; 1 qualifies the saved pre-flattening compiler')
    parser.add_argument('--single-boxes',type=int,choices=(0,1),default=0,help='Expected owned wrapper boxes per step; 1 qualifies the saved pre-unwrapping compiler')
    args=parser.parse_args()
    records=[];differentials={}
    with tempfile.TemporaryDirectory(prefix='fpr-owned-products-') as directory:
        tmp=Path(directory);source=tmp/'products.fpr';source.write_text(SOURCE)
        entry=tmp/'main.fpr';entry.write_text('main = Unit.\n')
        exports='runOwned,runPlain,makePublic,readPublic,roundTrip,takeText,alias,nested,heap,runList,runListPlain,runWide,runNested,runNestedPlain,makeNested,readNested,roundNested,nestedAlias,nestedHeap,runSingle,runSinglePlain,runDouble,makeSingle,readSingle,roundSingle,makeDouble,readDouble,singleAlias,singleHeap,runSingleList'
        modes=[('packets',False,False)] if args.quick else [('packets',False,False),('no-type-spec',False,True),('boxed',True,False)]
        for mode,boxed,rollback in modes:
            env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
            env.update(FPR_HOME=str(ROOT),XDG_CACHE_HOME=str(tmp/f'cache-{mode}'))
            if not args.normal_inline:env['FPR_NO_INLINE']='1'
            if boxed:env['FPR_NO_PAIR_RETURNS']='1'
            if rollback:env['FPR_NO_TYPE_SPEC']='1'
            if not args.quick:differentials[mode]=effects(tmp,env,mode)
            for abi in (['soft'] if args.quick else ['soft','hard']):
                asm=tmp/f'{mode}-{abi}.s'
                run([args.compiler,'--profile=bare-metal-builtin','--arc','--lib',f'--float-abi={abi}',f'--export={exports}',source,asm],env=env)
                text=asm.read_text();body=f'#define BOXED {int(boxed)}\n#define NESTED_BOXES {args.nested_boxes}\n#define SINGLE_BOXES {args.single_boxes}\n'+PROBE
                for key,name in [('SINGLE_PLAIN','runSinglePlain'),('SINGLE_LIST','runSingleList'),('SINGLE_ALIAS','singleAlias'),('SINGLE_HEAP','singleHeap'),('SINGLE','runSingle'),('DOUBLE','runDouble'),('NESTED_LOOP','runNested'),('NESTED_PLAIN','runNestedPlain'),('NESTED_ALIAS','nestedAlias'),('NESTED_HEAP','nestedHeap'),('OWNED','runOwned'),('PLAIN','runPlain'),('ALIAS','alias'),('NESTED','nested'),('HEAP','heap'),('LIST_PLAIN','runListPlain'),('LIST','runList'),('WIDE','runWide')]:
                    match=re.search(r'^# fn \$uniform\.raw\.'+name+r'\S* .*?^    \.globl (\S+)',text,re.M|re.S)
                    assert match,name
                    body=body.replace('RAW_'+key,match[1])
                probe=tmp/f'{mode}-{abi}.c';probe.write_text(body)
                for allocator in (['c'] if args.quick else ['c','fpr']):
                    build=tmp/f'build-{mode}-{abi}-{allocator}';image=build.with_suffix('.elf')
                    run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1',f'HEAP={allocator}','BUILTIN_HEAP_BYTES=1048576',
                         f'PROG={entry}',f'BUILD={build}',f'IMAGE={image}',f'BUILTIN_EXTRA={asm} {probe}',
                         'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main -Wl,--wrap=fpr_builtin_alloc_adt',
                         f'ARCHFLAGS=-march=rv64imafdc_zicsr -mabi={"lp64d" if abi=="hard" else "lp64"} -mcmodel=medany',f'FPRC_FLAGS=--float-abi={abi}'],env=env)
                    output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image])
                    nested_count=2002 if boxed else args.nested_boxes*1001
                    single_count=1001 if boxed else args.single_boxes*1001
                    double_count=2002 if boxed else args.single_boxes*2002
                    assert output==f'owned {1001 if boxed else 0} plain 0\nnested {nested_count} plain 0\nsingle {single_count} double {double_count} plain 0\nOWNED_PRODUCTS_PASS\n',output
                    records.append(dict(mode=mode,abi=abi,allocator=allocator,owned_allocations=1001 if boxed else 0,nested_allocations=nested_count,single_allocations=single_count,double_allocations=double_count,explicit_allocations=0,output=output))
                    print(f'{mode}, {abi}, {allocator}: aliases, nested/heap/public boundaries, wide fallback and ARC PASS',flush=True)
        if differentials:
            assert all(result==differentials['packets'] for result in differentials.values()),differentials
    if args.output:
        args.output.write_text(json.dumps(dict(schema=1,compiler_sha256=hashlib.sha256(args.compiler.read_bytes()).hexdigest(),runtime_compiler_sha256=hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),
            test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),quick=args.quick,normal_inline=args.normal_inline,records=records,effects=differentials),indent=2)+'\n')


if __name__=='__main__':main()
