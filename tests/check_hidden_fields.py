#!/usr/bin/env python3
"""Canonical hidden fields: real C boundaries, checked extraction and effects."""
import os
from pathlib import Path
import re
import tempfile
from check_uniform_aggregate import ROOT, run

SOURCE = '''profile builtin.
Hidden = Type (Hidden a).
makeWord : Word -> Hidden.
makeWord x = Hidden x.
readWord : Hidden -> Word.
readWord h = case h of Hidden x -> x.
makeInt : Int -> Hidden.
makeInt x = Hidden x.
readInt : Hidden -> Int.
readInt h = case h of Hidden x -> x.
makeText : String -> Hidden.
makeText x = Hidden x.
readText : Hidden -> String.
readText h = case h of Hidden x -> x.
makeInts : Int -> Hidden.
makeInts n = Hidden [n,n + 1].
readInts : Hidden -> List Int.
readInts h = case h of Hidden x -> x.
makeWords : Word -> Hidden.
makeWords n = Hidden [n,n].
readWords : Hidden -> List Word.
readWords h = case h of Hidden x -> x.
firstWord : Hidden -> Word.
firstWord h = case h of Hidden (x :: _) -> x | _ -> Word.fromInt 0.
makeFlag : Bool -> Hidden.
makeFlag x = Hidden x.
readFlag : Hidden -> Bool.
readFlag h = case h of Hidden x -> if x then True else False.
makeNested : Word -> Hidden.
makeNested x = Hidden (Hidden x).
readNested : Hidden -> Word.
readNested h = case h of Hidden (Hidden x) -> x.
'''

PROBE = r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void);
extern V makeWord(uw),makeInt(intptr_t),makeText(V),makeInts(intptr_t),makeWords(uw),makeFlag(int),makeNested(uw);
extern uw readWord(V),firstWord(V),readNested(V);
extern intptr_t readInt(V);
extern int readFlag(V);
extern V readText(V),readInts(V),readWords(V);
extern V raw_make_word(uw) __asm__("RAW_MAKE_WORD");
extern V __real_fpr_builtin_alloc_adt(V,uw);
static uw requests;
V __wrap_fpr_builtin_alloc_adt(V bytes,uw fields){requests++;return __real_fpr_builtin_alloc_adt(bytes,fields);}
#define check(b) do{if(!(b))fpr_cpanic("hidden-field oracle: " #b);}while(0)
static V field(V p,uw i){check(fpr_builtin_field_kind(p,i)=='t');return ((V*)(p+8))[i];}
V __wrap_fpr_fn_main(void) {
 uw before=fpr_builtin_live_allocations();
 #if TEST_CASE == 1
 readInt(makeWord(7));
 #elif TEST_CASE == 2
 readWord(makeInt(7));
 #elif TEST_CASE == 3
 readText(makeInt(7));
 #elif TEST_CASE == 4
 readInts(makeWords(7));
 #elif TEST_CASE == 5
 readWords(makeInts(7));
 #elif TEST_CASE == 6
 readFlag(makeWord(7));
 #else
 for(uw n=1;n<=128;n++) {
  uw counted=requests;
  V direct=raw_make_word(n);
  check(requests==counted+1); /* private one-word result: only the payload box */
  check(TID(direct)==T_BITS && ((bits_t*)direct)->var==2 && ((bits_t*)direct)->val==n);
  fpr_builtin_release(direct);
  counted=requests;
  V h=makeWord(n);
  check(requests==counted+3); /* public scalar bridge, payload box and nominal Hidden */
  V payload=field(h,0);
  check(TID(payload)==T_BITS && ((bits_t*)payload)->var==2 && ((bits_t*)payload)->val==n);
  check(readWord(fpr_builtin_retain(h))==n);fpr_builtin_release(h);
  check(readInt(makeInt(n))==(intptr_t)n);
  V text=(V)fpr_mkstr((const uint8_t*)"abc",3);
  h=makeText(fpr_builtin_retain(text));
  V copy=readText(h);check(copy==text);fpr_builtin_release(copy);fpr_builtin_release(text);
  h=makeInts(n);payload=field(h,0);copy=readInts(fpr_builtin_retain(h));
  check(copy==payload && UNTAG(field(copy,0))==(intptr_t)n);
  check(UNTAG(field(field(copy,1),0))==(intptr_t)n+1);
  fpr_builtin_release(copy);fpr_builtin_release(h);
  h=makeWords(n);check(firstWord(fpr_builtin_retain(h))==n);
  copy=readWords(h);check(((bits_t*)field(copy,0))->val==n);fpr_builtin_release(copy);
  check(readFlag(makeFlag(1))==1 && readFlag(makeFlag(0))==0);
  check(readNested(makeNested(n))==n);
  check(fpr_builtin_live_allocations()==before);
 }
 volatile unsigned char*uart=(void*)0x10000000;
 const char*s="HIDDEN_FIELDS_PASS\n";
 for(;*s;s++){while(!(uart[5]&32)){}uart[0]=*s;}
 #endif
 return __real_fpr_fn_main();
}
'''

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
STR(empty,"");STR(pair,"tt");STR(raw,"wt");
STR(plan,"U2 10 2 2 2 0 0 1 2 5 9 536879104 1 0 2 9 9");
static const hdr_t nil={T_LIST,0},descriptor_nil={0x1fff0001,0};
static void check(int b){if(!b)fpr_cpanic("checked graph oracle");}
static V node(uw tid,uw tag,V a,V b){V p=fpr_builtin_alloc_adt(24,2);
 ((hdr_t*)p)->tid=tid;((hdr_t*)p)->var=tag;((V*)(p+8))[0]=a;((V*)(p+8))[1]=b;return p;}
static V descriptors(void){const void*ss[]={&empty,&pair,&pair};V xs=(V)&descriptor_nil;
 for(unsigned i=3;i-->0;)xs=node(0x1fff0001,1,(V)ss[i],xs);return xs;}
int main(void){fpr_builtin_heap_init(arena,arena+sizeof arena);
 V xs=(V)&nil;for(uw i=0;i<6000;i++)xs=node(T_LIST,1,TAG(i),xs);
 V root=node(536879104,0,fpr_builtin_retain(xs),xs);
 #if TEST_CASE == 0
 check(fpr_fn__x24arc_x2euniformTagEq(fpr_builtin_retain(root),TAG(536879104),TAG(0))==(V)&fpr_true);
 check(fpr_fn__x24arc_x2euniformTagEq(fpr_builtin_retain(root),TAG(536879105),TAG(0))==(V)&fpr_false);
 check(fpr_fn__x24arc_x2euniformTagEq(fpr_builtin_retain(root),TAG(536879104),TAG(1))==(V)&fpr_false);
 check(fpr_fn__x24arc_x2euniformTagEq(TAG(7),TAG(536879104),TAG(0))==(V)&fpr_false);
 #endif
 #if TEST_CASE == 1
 ((V*)(xs+8))[0]=uniform_box(7,2,64);
 #elif TEST_CASE == 2
 ((hdr_t*)root)->tid=T_BOOL;
 #elif TEST_CASE == 3
 V old=((V*)(xs+8))[1];((V*)(xs+8))[1]=fpr_builtin_retain(xs);fpr_builtin_release(old);
 #elif TEST_CASE == 4
 fpr_builtin_set_layout(xs,(V)&raw);
 #elif TEST_CASE == 5
 ((V*)(xs+8))[0]=(V)fpr_mkstr((const uint8_t*)"wrong",5);
 #endif
 uw before=fpr_builtin_live_allocations();
 V got=fpr_fn__x24arc_x2euniformUnboxAggregate(fpr_builtin_retain(root),(V)&plan,descriptors());
 check(got==root && ((V*)(got+8))[0]==xs && ((V*)(got+8))[1]==xs);
 check(fpr_builtin_live_allocations()==before);
 V at=xs;for(uw i=6000;i-->0;){check(((V*)(at+8))[0]==TAG(i));at=((V*)(at+8))[1];}
 check(at==(V)&nil);fpr_builtin_release(got);fpr_builtin_release(root);
 check(!fpr_builtin_live_allocations());puts("CHECKED_GRAPH_PASS");return 0;}
'''


def sanitizer(tmp):
    for case, expected in [(0,'CHECKED_GRAPH_PASS'),(1,'uniform tagged representation mismatch'),
                           (2,'uniform aggregate representation mismatch'),(3,'cycle at uniform aggregate boundary'),
                           (4,'uniform aggregate representation mismatch'),(5,'uniform tagged representation mismatch')]:
        source=tmp/f'checked-graph-{case}.c'
        source.write_text(f'#define TEST_CASE {case}\n'+VALIDATION_PROBE)
        binary=source.with_suffix('')
        run(['clang','-std=c11','-O1','-g','-DFPR_POSIX','-DFPR_BUILTIN_ARC',
             '-Iruntime','-Imachine/builtin','-fsanitize=address,undefined',source,'machine/builtin/heap.c','-o',binary])
        out=run([binary],expected=0 if case==0 else 1)
        assert expected in out and 'AddressSanitizer' not in out and 'runtime error:' not in out,out
    print('6000-node checked managed graph: identity/sharing, scalar/nominal/metadata/cycle refusals under ASan/UBSan PASS',flush=True)


def effects(tmp, env, rollback):
    allocation = tmp/'fail-allocation.c'
    allocation.write_text('#include "builtin.h"\nV __wrap_fpr_builtin_alloc_adt(V bytes,uw fields)'
                          '{(void)bytes;(void)fields;fpr_cpanic("injected allocation failure");return 0;}\n')
    header = ('Crate = Type (Crate a b).\n'
              'effect : Int -> Word.\neffect n = _ = print n; Word.fromInt n.\n')
    programs = [
        ('construct-effects', header+'main = Crate (effect 1) (effect 2).\n',
         'injected allocation failure', ['1','2'], True),
        ('construct-trap', header+'fail u = _ = print 2; Word.fromInt (17 / 0).\n'
         'main = Crate (effect 1) (fail Unit).\n', 'division by zero', ['1','2'], True),
        ('argument-effects', 'Hidden = Type (Hidden a).\n'
         'consume : Word -> Int -> Unit.\nconsume x y = _ = print 99; print (Word.toInt x + y).\n'
         'second u = _ = print 2; 3.\n'
         'probe h = case h of Hidden x -> consume x (second Unit).\n'
         'main = probe (Hidden 1).\n', 'uniform scalar representation mismatch', ['2'], False),
    ]
    for label, code, message, prefix, inject in programs:
        source=tmp/f'{label}-{rollback}.fpr';source.write_text(code)
        build=tmp/f'{label}-{rollback}';image=build.with_suffix('.elf')
        args=['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1','HEAP=c',
              'BUILTIN_HEAP_BYTES=65536',f'PROG={source}',f'BUILD={build}',f'IMAGE={image}']
        if inject:
            args += [f'BUILTIN_EXTRA={allocation}','BUILTIN_LDFLAGS=-Wl,--wrap=fpr_builtin_alloc_adt']
        run(args,env=env)
        output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],expected=1)
        assert output.splitlines()[:len(prefix)]==prefix and message in output,output
        assert '99\n' not in output,output
        if label=='construct-trap':
            assert 'injected allocation failure' not in output,output
        print(f'rollback={rollback}, {label}: ordered effects and named failure PASS',flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-hidden-') as directory:
        tmp = Path(directory)
        sanitizer(tmp)
        source = tmp/'main.fpr'
        source.write_text('main = Unit.\n')
        library = tmp/'hidden.fpr'
        library.write_text(SOURCE)
        exports = ','.join(re.findall(r'^(\w+) :', SOURCE, re.M))
        for rollback in (False, True):
            env = dict(os.environ)
            env.pop('FPR_NO_TYPE_SPEC', None)
            if rollback:
                env['FPR_NO_TYPE_SPEC'] = '1'
            asm = tmp/f'hidden-{rollback}.s'
            run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--lib',f'--export={exports}',library,asm],env=env)
            worker = re.search(r'^# fn \$worker\.payload\.\$product\.\$uniform\.raw\.makeWord\S* .*?^    \.globl (\S+)',asm.read_text(),re.M|re.S).group(1)
            assert 'uniformUnboxTagged' in asm.read_text() and 'uniformProject' in asm.read_text()
            for allocator in ('c','fpr'):
                for case, expected in [(0,'HIDDEN_FIELDS_PASS'),(1,'uniform tagged representation mismatch'),
                                       (2,'uniform scalar representation mismatch'),(3,'uniform text representation mismatch'),
                                       (4,'uniform tagged representation mismatch'),(5,'uniform scalar representation mismatch'),
                                       (6,'uniform nominal representation mismatch')]:
                    probe=tmp/f'probe-{allocator}-{rollback}-{case}.c'
                    probe.write_text(f'#define TEST_CASE {case}\n'+PROBE.replace('RAW_MAKE_WORD',worker))
                    build=tmp/f'build-{allocator}-{rollback}-{case}'
                    image=build.with_suffix('.elf')
                    run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1',f'HEAP={allocator}',
                         'BUILTIN_HEAP_BYTES=1048576',f'PROG={source}',f'BUILD={build}',f'IMAGE={image}',
                         f'BUILTIN_EXTRA={asm} {probe}',
                         'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main -Wl,--wrap=fpr_builtin_alloc_adt'],env=env)
                    out=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],
                            expected=0 if case==0 else 1)
                    assert expected in out,out
                    print(f'{allocator}, rollback={rollback}, hidden field case {case}: PASS',flush=True)
            effects(tmp,env,rollback)


if __name__=='__main__':
    main()
