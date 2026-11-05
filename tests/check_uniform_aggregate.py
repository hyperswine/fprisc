#!/usr/bin/env python3
"""Uniform aggregate graph conversion: sharing, raw fields and bounded C stack."""
import os
from pathlib import Path
import subprocess
import tempfile
import re

ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void);
extern V fpr_fn__x24arc_x2euniformAggregate(V,V,V,V);
extern V fpr_fn__x24arc_x2euniformBoxAddr(V);
#define STR(name,text) static const struct {uint32_t tid,var;uw len;uint8_t bytes[sizeof(text)];} name={T_STR,0,sizeof(text)-1,text}
STR(empty,""); STR(list_layout,"wt"); STR(root_layout,"ttadft"); STR(wrong_layout,"tt");
STR(plan,"U1 6 2 2 2 0 0 1 2 1 5 536879104 1 0 6 5 5 2 3 4 0");
STR(bad_plan,"U1 6 2 2 2 0 0 0 2 1 5 536879104 1 0 6 5 5 2 3 4 0");
static const hdr_t nil={T_LIST,0};
static const hdr_t descriptor_nil={0x1fff0001,0};
static void check(int b){if(!b)fpr_cpanic("uniform aggregate oracle");}
static V node(uw tid,uw var,uw n,const str_t *layout) {
 V v=fpr_builtin_alloc_adt(8+n*sizeof(V),n);
 ((hdr_t*)v)->tid=tid;((hdr_t*)v)->var=var;
 if(layout)fpr_builtin_set_layout(v,(V)layout);
 return v;
}
static V descriptors(void) {
 const str_t *strings[]={(const str_t*)&empty,(const str_t*)&list_layout,(const str_t*)&root_layout};
 V list=(V)&descriptor_nil;
 for(unsigned i=3;i-->0;) {
  V cell=node(0x1fff0001,1,2,0);((V*)(cell+8))[0]=(V)strings[i];((V*)(cell+8))[1]=list;list=cell;
 }
 return list;
}
static V convert(V v,int direction) {
 return fpr_fn__x24arc_x2euniformAggregate(v,(V)&plan,descriptors(),TAG(direction));
}
static uw word(uw i){return 0xfedcba9876543210ULL^(i*0x9e3779b97f4a7c15ULL);}
V __wrap_fpr_fn_main(void) {
 uw before=fpr_builtin_live_allocations();
 V list=(V)&nil;
 for(uw i=0;i<6000;i++) {
  V cell=node(T_LIST,1,2,(const str_t*)&list_layout);
  ((V*)(cell+8))[0]=word(i);((V*)(cell+8))[1]=list;list=cell;
 }
 V root=node(536879104,0,6,(const str_t*)&root_layout),*fields=(V*)(root+8);
 fields[0]=fpr_builtin_retain(list);fields[1]=fpr_builtin_retain(list);
 fields[2]=list;fields[3]=0x7ff8000000000011ULL;fields[4]=0x80000000U;
 fields[5]=(V)fpr_mkstr((const uint8_t*)"owned",5);
 #if TEST_CASE == 1
 /* Layout metadata must not turn raw payload bits into references. */
 fpr_builtin_set_layout(list,(V)&wrong_layout);
 #elif TEST_CASE == 2
 fpr_fn__x24arc_x2euniformAggregate(root,(V)&bad_plan,descriptors(),TAG(0));
 #elif TEST_CASE == 3
 V tail=((V*)(list+8))[1];((V*)(list+8))[1]=fpr_builtin_retain(list);fpr_builtin_release(tail);
 #endif
 V boxed=convert(root,0),*bf=(V*)(boxed+8);
 check(bf[0]==bf[1]); /* shared list copied once, not once per edge */
 check(((bits_t*)bf[2])->val==list);
 check(((bits_t*)bf[3])->val==0x7ff8000000000011ULL);
 check(((bits_t*)bf[4])->val==0x80000000U);
 for(uw i=0;i<6;i++)check(fpr_builtin_field_kind(boxed,i)=='t');
 #if TEST_CASE == 4
 V old=((V*)(bf[0]+8))[0];((V*)(bf[0]+8))[0]=fpr_fn__x24arc_x2euniformBoxAddr(9);fpr_builtin_release(old);
 #endif
 V raw=convert(fpr_builtin_retain(boxed),1),*rf=(V*)(raw+8);
 check(rf[0]==rf[1] && rf[0]!=list && rf[0]!=bf[0]);
 check(rf[2]==list && rf[3]==0x7ff8000000000011ULL && rf[4]==0x80000000U);
 check(rf[5]==bf[5]); /* already managed leaves preserve identity */
 V a=list,b=bf[0],c=rf[0];
 for(uw i=6000;i-->0;) {
  check(((V*)(a+8))[0]==word(i));
  check(((bits_t*)((V*)(b+8))[0])->val==word(i));
  check(((V*)(c+8))[0]==word(i));
  check(fpr_builtin_field_kind(a,0)=='w' && fpr_builtin_field_kind(b,0)=='t' && fpr_builtin_field_kind(c,0)=='w');
  a=((V*)(a+8))[1];b=((V*)(b+8))[1];c=((V*)(c+8))[1];
 }
 check(a==(V)&nil && b==(V)&nil && c==(V)&nil);
 fpr_builtin_release(raw);fpr_builtin_release(boxed);
 check(((V*)(list+8))[0]==word(5999)); /* boxed Addr never owns the pointee */
 fpr_builtin_release(list);
 check(fpr_builtin_live_allocations()==before);
 const char*s="UNIFORM_AGGREGATE_PASS\n";
 volatile unsigned char*uart=(void*)0x10000000;
 for(;*s;s++){while(!(uart[5]&32)){}uart[0]=*s;}
 return __real_fpr_fn_main();
}
'''


def run(args, expected=0, env=None):
    result = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout + result.stderr


SOURCE = '''profile builtin.
identity : a -> a.
identity x = x.
wrap : a -> (a, Word).
wrap x = identity (x, Word.fromInt 7).
internalWord : Word -> Word.
internalWord x = Word.add (identity x) (Word.fromInt 1).
reverseGeneric : List a -> List a.
reverseGeneric xs = reverseGo xs [].
reverseGo xs acc = case xs of [] -> acc | x :: rest -> reverseGo rest (x :: acc).
countGeneric : List a -> Int.
countGeneric xs = case xs of [] -> 0 | _ :: rest -> 1 + countGeneric rest.
sameWords : List Word -> List Word.
sameWords xs = xs.
makeWords : Int -> List Word.
makeWords n = makeGo n [].
makeGo n xs = case n == 0 of True -> xs | False -> makeGo (n - 1) (Word.fromInt n :: xs).
sumWords : List Word -> Word.
sumWords xs = sumGo xs (Word.fromInt 0).
sumGo xs acc = case xs of [] -> acc | x :: rest -> sumGo rest (Word.add acc x).
duo : List Word -> (List Word, List Word).
duo xs = (xs,xs).
sameText : String -> String.
sameText s = s.
makeRecord : Word -> {addr: Addr, d: F64, f: F32, text: String, w: Word}.
makeRecord w = {addr = Addr.fromWord w, d = F64.ofInt 5, f = F32.ofInt 7, text = "ok", w = w}.
sameRecord : {addr: Addr, d: F64, f: F32, text: String, w: Word} -> {addr: Addr, d: F64, f: F32, text: String, w: Word}.
sameRecord r = r.
Choice a = Type (No | Yes a).
choice : Int -> Choice Word.
choice n = case n == 0 of True -> No | False -> Yes (Word.fromInt n).
readChoice : Choice Word -> Word.
readChoice c = case c of No -> Word.fromInt 0 | Yes w -> w.
'''

SOURCE_PROBE = r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void);
extern V makeWords(intptr_t),sameWords(V),duo(V),sameRecord(V),makeRecord(uw),sameInts(V),sameText(V);
extern uw sumWords(V);
extern V identity(V),wrap(V),reverseGeneric(V);
extern intptr_t countGeneric(V);
extern uw internal_word_worker(uw) __asm__("INTERNAL_WORD_WORKER");
extern V choice(intptr_t);
extern uw readChoice(V);
static uw requests;
extern V __real_fpr_builtin_alloc_adt(V,uw);
V __wrap_fpr_builtin_alloc_adt(V bytes,uw fields){requests++;return __real_fpr_builtin_alloc_adt(bytes,fields);}
static void check(int b){if(!b)fpr_cpanic("generated uniform aggregate oracle");}
V __wrap_fpr_fn_main(void) {
 uw before=fpr_builtin_live_allocations();
 for(uw n=1;n<=128;n++) {
  check(readChoice(choice(n))==n && readChoice(choice(0))==0);
  V xs=makeWords(n),copy=sameWords(fpr_builtin_retain(xs));
  uw genericRequests=requests;
  V alias=identity(fpr_builtin_retain(xs));
  check(alias==xs && requests==genericRequests);fpr_builtin_release(alias);
  V wrapped=wrap(fpr_builtin_retain(xs)),*wf=(V*)(wrapped+8);
  check(wf[0]==xs && ((bits_t*)wf[1])->val==7);fpr_builtin_release(wrapped);
  genericRequests=requests;
  V reversed=reverseGeneric(fpr_builtin_retain(xs));
  check(countGeneric(fpr_builtin_retain(reversed))==(intptr_t)n);
  check(requests==genericRequests+n);
  check(((bits_t*)((V*)(reversed+8))[0])->val==n);fpr_builtin_release(reversed);
  genericRequests=requests;
  check(internal_word_worker(n)==n+1);
  check(requests==genericRequests+INTERNAL_BOXES);
  check(xs!=copy && fpr_builtin_field_kind(copy,0)=='t');
  V pairs=duo(fpr_builtin_retain(copy)),*pf=(V*)(pairs+8);
  check(pf[0]==pf[1]);
  check(sumWords(fpr_builtin_retain(xs))==n*(n+1)/2);
  check(sumWords(fpr_builtin_retain(pf[0]))==n*(n+1)/2);
  V record=makeRecord(xs),*rf=(V*)(record+8);
  check(fpr_builtin_field_count(record)==5 && ((bits_t*)rf[0])->val==xs && ((bits_t*)rf[4])->val==xs);
  check(((bits_t*)rf[1])->val==0x4014000000000000ULL && ((bits_t*)rf[2])->val==0x40e00000U);
  V copyRecord=sameRecord(fpr_builtin_retain(record)),*cf=(V*)(copyRecord+8);
  check(cf[3]==rf[3] && ((bits_t*)cf[4])->val==xs);
  fpr_builtin_release(copyRecord);fpr_builtin_release(record);
  fpr_builtin_release(pairs);fpr_builtin_release(copy);fpr_builtin_release(xs);
  static const hdr_t nil={T_LIST,0};
  V ints=fpr_builtin_alloc_adt(24,2);
  ((hdr_t*)ints)->tid=T_LIST;((hdr_t*)ints)->var=1;
  ((V*)(ints+8))[0]=TAG(n);((V*)(ints+8))[1]=(V)&nil;
  uw counted=requests;
  V intCopy=sameInts(fpr_builtin_retain(ints));
  check(intCopy==ints && requests==counted);
  fpr_builtin_release(intCopy);fpr_builtin_release(ints);
  V text=(V)fpr_mkstr((const uint8_t*)"owned",5);
  counted=requests;
  V textCopy=sameText(fpr_builtin_retain(text));
  check(text==textCopy && requests==counted);
  fpr_builtin_release(textCopy);fpr_builtin_release(text);
  check(fpr_builtin_live_allocations()==before);
 }
 volatile unsigned char*uart=(void*)0x10000000;
 const char*s="GENERATED_UNIFORM_AGGREGATE_PASS\n";
 for(;*s;s++){while(!(uart[5]&32)){}uart[0]=*s;}
 return __real_fpr_fn_main();
}
'''


def generated(tmp, source):
    library = tmp / 'aggregate.fpr'
    library.write_text(SOURCE)
    ints = tmp / 'ints.fpr'
    ints.write_text('profile builtin.\nsameInts : List Int -> List Int.\nsameInts xs = xs.\n')
    harness = tmp / 'generated.c'
    harness.write_text(SOURCE_PROBE)
    for rollback in (False, True):
        env = dict(os.environ)
        env.pop('FPR_NO_TYPE_SPEC', None)
        if rollback:
            env['FPR_NO_TYPE_SPEC'] = '1'
        asm = tmp / f'aggregate-{rollback}.s'
        int_asm = tmp / f'ints-{rollback}.s'
        exports = 'sameWords,makeWords,sumWords,duo,sameText,makeRecord,sameRecord,choice,readChoice,identity,wrap,internalWord,reverseGeneric,countGeneric'
        run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--lib',f'--export={exports}',library,asm], env=env)
        run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--lib','--export=sameInts',ints,int_asm], env=env)
        assert '$uniform.raw.sameWords' in asm.read_text()
        assert 'uniformBoxAggregate' in asm.read_text() and 'uniformUnboxAggregate' in asm.read_text()
        assert 'uniformBoxAggregate' not in int_asm.read_text()
        worker=re.search(r'^# fn \$uniform\.raw\.internalWord\S* .*?^    \.globl (\S+)',asm.read_text(),re.M|re.S).group(1)
        harness.write_text(SOURCE_PROBE.replace('INTERNAL_WORD_WORKER',worker).replace('INTERNAL_BOXES','1' if rollback else '0'))
        for allocator in ('c', 'fpr'):
            output = tmp / f'generated-{allocator}-{rollback}'
            image = output.with_suffix('.elf')
            run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1',f'HEAP={allocator}',
                 'BUILTIN_HEAP_BYTES=1048576',f'PROG={source}',f'BUILD={output}',f'IMAGE={image}',
                 f'BUILTIN_EXTRA={asm} {int_asm} {harness}',
                 'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main -Wl,--wrap=fpr_builtin_alloc_adt'], env=env)
            text=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image])
            assert 'GENERATED_UNIFORM_AGGREGATE_PASS' in text, text
            print(f'{allocator} allocator, rollback={rollback}: generated list/record/tuple/string boundaries, sharing and zero leaks: PASS', flush=True)


def sanitizer(tmp):
    # Compile the exact production converters with the host allocator; only
    # the platform's terminal and string construction are supplied here.
    host = r'''
#include "builtin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "uniform.inc"
const hdr_t fpr_unit={T_UNIT,0},fpr_false={T_BOOL,0},fpr_true={T_BOOL,1};
static _Alignas(16) unsigned char arena[8*1024*1024];
void fpr_cpanic(const char *s){fprintf(stderr,"%s\n",s);exit(1);}
str_t *fpr_mkstr(const uint8_t *bytes,uw n){
 str_t*s=(str_t*)fpr_builtin_alloc_adt(sizeof(str_t)+n,0);
 s->tid=T_STR;s->var=0;s->len=n;memcpy(s->bytes,bytes,n);return s;
}
V __real_fpr_fn_main(void){return 0;}
extern V __wrap_fpr_fn_main(void);
int main(void){fpr_builtin_heap_init(arena,arena+sizeof arena);return (int)__wrap_fpr_fn_main();}
'''
    # UART output is the only platform-specific operation in the shared probe.
    probe = PROBE.replace('volatile unsigned char*uart=(void*)0x10000000;\n for(;*s;s++){while(!(uart[5]&32)){}uart[0]=*s;}', 'fputs(s,stdout);')
    for case in range(5):
        source = tmp / f'host-{case}.c'
        source.write_text(f'#define TEST_CASE {case}\n'+host+probe)
        binary = source.with_suffix('')
        run(['clang','-std=c11','-O1','-g','-DFPR_POSIX','-DFPR_BUILTIN_ARC',
             '-Iruntime','-Imachine/builtin','-fsanitize=address,undefined',
             source,'machine/builtin/heap.c','-o',binary])
        output = run([binary], expected=0 if case==0 else 1)
        assert 'AddressSanitizer' not in output and 'runtime error:' not in output, output
        assert ('UNIFORM_AGGREGATE_PASS' if case==0 else 'Builtin:') in output, output
    print('Production aggregate converters: 6000-node sharing/roundtrip and refusals under ASan/UBSan: PASS', flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-uniform-aggregate-') as directory:
        tmp = Path(directory)
        source = tmp / 'main.fpr'
        source.write_text('main = Unit.\n')
        sanitizer(tmp)
        generated(tmp, source)
        for allocator in ('c', 'fpr'):
            for case, expected in [(0, 'UNIFORM_AGGREGATE_PASS'),
                                   (1, 'uniform aggregate representation mismatch'),
                                   (2, 'uniform aggregate representation mismatch'),
                                   (3, 'cycle at uniform aggregate boundary'),
                                   (4, 'uniform scalar representation mismatch')]:
                harness = tmp / f'probe-{case}.c'
                harness.write_text(f'#define TEST_CASE {case}\n' + PROBE)
                output = tmp / f'{allocator}-{case}'
                image = output.with_suffix('.elf')
                run(['make', '-s', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', f'HEAP={allocator}',
                     'BUILTIN_HEAP_BYTES=4194304', f'PROG={source}', f'BUILD={output}', f'IMAGE={image}',
                     f'BUILTIN_EXTRA={harness}', 'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main'])
                text = run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic',
                            '-bios', 'none', '-kernel', image], expected=0 if case == 0 else 1)
                assert expected in text, text
                print(f'{allocator} allocator: aggregate case {case}: PASS', flush=True)


if __name__ == '__main__':
    main()
