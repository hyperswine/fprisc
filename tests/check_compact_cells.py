#!/usr/bin/env python3
"""Independent physical extent, size derivation and mixed allocator contracts."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
PROBE = r'''
static _Thread_local unsigned char compact_storage[65536] __attribute__((aligned(16)));
#define CK(ok,why) do { if (!(ok)) fpr_cpanic("compact contract: " why); } while (0)
static void extent_check(V v,uw raw,uw prefix,char *start,fpr_slab_t *sl) {
  uw total=(raw+prefix+15)&~(uw)15;
  CK((char *)v==start+prefix && sl->hp==start+total,"physical extent");
  CK(*(fpr_slab_t **)((char *)v-8)==sl,"owning slab");
  CK(!(v & (prefix==16?15:7)),"alignment");
  for (uw i=raw;i<total-prefix;i++) CK(((unsigned char *)v)[i]==0,"rounding pad");
}
static void initialize(V v,uw tid,uw var,uw count) {
  hdr_t *h=(hdr_t *)v; h->tid=tid;h->var=var;
  switch (tid) {
    case T_STR: ((str_t *)v)->len=count; break;
    case T_PAP: ((pap_t *)v)->arity=count; ((pap_t *)v)->nargs=0; break;
    default: break;
  }
}
static V compact_probe(V unused) {
  (void)unused;
  const uw table[]={9, 0x70000001,0,0, 0x70000001,1,1, 0x70000001,2,2,
    0x70000001,3,3, 0x70000001,4,4, 0x70000001,5,5,
    0x70000001,6,6, 0x70000001,7,7, 0x70000001,8,8};
  CK(!fpr_layout_register(table),"register oracle constructors");
  fpr_hart_t *h=fpr_hart(); struct fpr_pool **slot=override_slot(h),*saved=*slot;
  uw clock=h->region_bytes;
  fpr_pool_t pool; void *buckets[FPR_NBUCKETS];
  struct { uw tid,var,count,raw; } cases[100]; uw count=0;
#define ADD(t,v,n,z) cases[count++]=(typeof(cases[0])){t,v,n,z}
  for (uw n=0;n<9;n++) ADD(0x70000001,n,n,8+8*n);
  for (uw n=0;n<33;n++) ADD(T_STR,0,n,sizeof(str_t)+n);
  ADD(T_TUPN+16,0,16,8+16*sizeof(V));
  ADD(T_TUPN+64,0,64,8+64*sizeof(V));
  ADD(T_TUPN+128,0,128,8+128*sizeof(V));
  ADD(T_STR,0,9000,sizeof(str_t)+9000);
  ADD(T_SSTR,0,0,sizeof(sstr_t));
  ADD(T_BITS,0,0,sizeof(bits_t));
  ADD(T_BITS,4,0,sizeof(fpr_num64_t));
  ADD(T_BITS,5,0,sizeof(fpr_num64_t));
  ADD(T_VEC,0,0,sizeof(vec_t));
  ADD(T_DEVICE,0,0,sizeof(fpr_dev_t));
  ADD(T_REGISTER,0,0,sizeof(reg_t));
  for (uw n=0;n<9;n++) ADD(T_PAP,0,n,sizeof(pap_t)+n*sizeof(V));
  for (uw bucketed=0;bucketed<2;bucketed++) for (uw k=0;k<count;k++) {
    __builtin_memset(compact_storage,0xa5,sizeof compact_storage);
    __builtin_memset(buckets,0,sizeof buckets);
    fpr_pool_init(&pool,bucketed?buckets:0);
    fpr_slab_t *sl=(fpr_slab_t *)compact_storage;
    __builtin_memset(sl,0,sizeof *sl); sl->owner=&pool;
    sl->hp=(char *)(sl+1); sl->end=(char *)compact_storage+sizeof compact_storage;
    pool.cur=sl;pool.fixed_heap=1;*slot=&pool;
    uw raw=cases[k].raw,total=(raw+FPR_MANAGED_PREFIX+15)&~(uw)15;
    char *start=sl->hp;
    V v=fpr_alloc(raw);
    extent_check(v,raw,FPR_MANAGED_PREFIX,start,sl);
    initialize(v,cases[k].tid,cases[k].var,cases[k].count);
    CK(PREHEADER(v)==total,"derived size vs physical extent");
    CK(pool.allocated==total,"allocation gauge");
    if (bucketed || total>16*FPR_NBUCKETS) {
      fpr_free(v);
      uw raw_capacity=total-FPR_RAW_PREFIX;
      V b=fpr_alloc_raw(raw_capacity);
      CK((char *)b==start+FPR_RAW_PREFIX && sl->hp==start+total,"managed to raw exact reuse");
      CK(RAW_TOTAL(b)==total && !(b&15),"raw header and alignment");
      __builtin_memset((void *)b,0xa5,raw_capacity);
      fpr_free_raw(b);
      V again=fpr_alloc(raw);
      extent_check(again,raw,FPR_MANAGED_PREFIX,start,sl);
      initialize(again,cases[k].tid,cases[k].var,cases[k].count);
      CK(PREHEADER(again)==total,"raw to managed exact reuse");
      CK(pool.allocated==total,"reuse gauge");
    }
  }
  *slot=saved; fpr_bump_close(h);
  V b=fpr_alloc_raw(17);for(uw i=0;i<17;i++) ((unsigned char *)b)[i]=(unsigned char)i;
  V n=fpr_realloc_raw(b,9001);
  CK(!(n&(FPR_MANAGED_PREFIX==8?15:7)),"raw growth alignment"); CK(RAW_TOTAL(n)>=9017,"raw growth capacity");
  for(uw i=0;i<17;i++) CK(((unsigned char *)n)[i]==i,"raw realloc data");
  CK(fpr_realloc_raw(n,1)==n,"raw shrink");fpr_free_raw(n);
  h=fpr_hart();h->region_bytes=clock;fpr_bump_close(h);
  return TAG(FPR_MANAGED_PREFIX==8?32:48);
}
FPR_FN(fpr_g_Compact_x2echeck,compact_probe,1);
static V compact_overflow(V u) { (void)u; return fpr_alloc_raw((uw)-1-32); }
FPR_FN(fpr_g_Compact_x2eoverflow,compact_overflow,1);
'''

def rv32_owner(tmp):
    # The real owner slot remains value-8 even when sizeof(void *) is four.
    source=tmp/'rv32-owner.c'
    source.write_text('#include "'+str(ROOT/'runtime/runtime.c')+'"\n'+r'''
static unsigned char storage[64] __attribute__((aligned(16)));
static void *buckets[FPR_NBUCKETS];
static fpr_pool_t pool;
static fpr_slab_t slab;
int main(void) {
  for (uw i=0;i<sizeof storage;i++) storage[i]=0xa5;
  pool.buckets=buckets;slab.owner=&pool;
  allocation_header((char *)storage,32,&slab,FPR_MANAGED_PREFIX);
  V v=(V)(storage+16);
  if(FPR_MANAGED_PREFIX!=16 || *(volatile uw *)(v-16)!=32) return 1;
  if(*(fpr_slab_t *volatile *)(v-8)!=&slab || *(volatile uw *)(v-4)!=0xa5a5a5a5u) return 2;
  fpr_free(v);
  if(buckets[1]!=storage || *(fpr_slab_t *volatile *)(storage+8)!=&slab) return 3;
  buckets[1]=0;allocation_header((char *)storage,32,&slab,FPR_RAW_PREFIX);
  fpr_free_raw(v);
  if(buckets[1]!=storage) return 4;
  return 0;
}
''')
    crt=tmp/'rv32-owner.S'
    crt.write_text('.section .text.entry,"ax",@progbits\n.globl _start\n_start:\n la sp, _stack_top\n call main\n beqz a0, 1f\n slli a0, a0, 16\n li t0, 0x3333\n or a0, a0, t0\n j 2f\n1: li a0, 0x5555\n2: li t0, 0x100000\n sw a0, 0(t0)\n3: j 3b\n')
    ld=tmp/'rv32-owner.ld'
    ld.write_text('OUTPUT_ARCH(riscv)\nENTRY(_start)\nSECTIONS { . = 0x80000000; .text : { KEEP(*(.text.entry)) *(.text .text.*) } .rodata : { *(.rodata .rodata.*) } .data : { *(.data .data.*) } .bss : { *(.bss .bss.* COMMON) } _stack_top = 0x80100000; }\n')
    elf=tmp/'rv32-owner.elf'
    def check(args):
        p=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=120)
        assert p.returncode==0,(args,p.returncode,p.stdout[-1000:],p.stderr[-3000:])
    check(['riscv64-unknown-elf-gcc','-ffixed-x27','-march=rv32imac_zicsr','-mabi=ilp32','-mcmodel=medany','-msmall-data-limit=0','-O2','-ffreestanding','-fno-builtin','-ffunction-sections','-fdata-sections','-DFPR_NHARTS=1','-I',ROOT/'runtime','-nostdlib','-Wl,--gc-sections','-T',ld,crt,source,'-o',elf])
    check(['qemu-system-riscv32','-machine','virt','-m','32M','-nographic','-bios','none','-kernel',elf])
    print('RV32 legacy owner slot and managed/raw frees execute correctly under QEMU PASS',flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-compact-cells-') as directory:
        tmp=Path(directory)
        rv32_owner(tmp)
        (tmp/'runtime.c').write_text((ROOT/'runtime/runtime.c').read_text()+'\n'+PROBE)
        cc=tmp/'cc'
        cc.write_text('#!/usr/bin/env python3\nimport os,sys\na=['+repr(str(tmp/'runtime.c'))+
                      ' if x.endswith("/runtime/runtime.c") else x for x in sys.argv[1:]]\n'+
                      'if '+repr(str(tmp/'runtime.c'))+' in a: a += ["-fsanitize=alignment"]\n'+
                      'os.execvp("cc",["cc",*a])\n')
        cc.chmod(0o755)
        p=tmp/'probe.fpr';p.write_text('unsafe base.\nCompact.check : Unit -> Int.\nmain = print (Compact.check Unit).\n')
        base={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),UBSAN_OPTIONS='halt_on_error=1')
        for compact in ('0','1'):
            env=dict(base,FPR_COMPACT_CELLS=compact,FPR_LAYOUT_CHECK='1',XDG_CACHE_HOME=str(tmp/('cache'+compact)))
            exe=tmp/('probe'+compact)
            build=subprocess.run([ROOT/'fpr','build',p,'--harts','4','--cc',cc,'--link','-fsanitize=alignment','-o',exe],env=env,cwd=ROOT,capture_output=True,text=True,timeout=300)
            assert not build.returncode,build.stdout+build.stderr
            for harts in ('1','4'):
                run=subprocess.run([exe],env=dict(env,FPR_HARTS=harts),capture_output=True,text=True,timeout=60)
                assert run.returncode==0 and run.stdout==('32\n' if compact=='1' else '48\n') and not run.stderr,(compact,harts,run.stdout,run.stderr)
            overflow=tmp/'overflow.fpr'
            overflow.write_text('unsafe base.\nCompact.overflow : Unit -> Unit.\nmain = Compact.overflow Unit.\n')
            fail=tmp/('overflow'+compact)
            built=subprocess.run([ROOT/'fpr','build',overflow,'--cc',cc,'--link','-fsanitize=alignment','-o',fail],env=env,cwd=ROOT,capture_output=True,text=True,timeout=300)
            assert not built.returncode,built.stderr
            bad=subprocess.run([fail],env=env,capture_output=True,text=True,timeout=30)
            assert bad.returncode!=0 and not bad.stdout and 'allocation size overflow' in bad.stderr,(bad.returncode,bad.stdout,bad.stderr)
            print(f'compact={compact}: independent extents, all object classes, mixed bucket/big reuse, padding, raw realloc and alignment on 1/4 harts PASS',flush=True)
if __name__=='__main__': main()
