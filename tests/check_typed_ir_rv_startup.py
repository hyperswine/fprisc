#!/usr/bin/env python3
"""Native bare-metal RV plugins and RVV startup, full root/data QEMU oracles.

The freestanding host supplies tp, checks exported PAP/table layout and calls
native functions. This is static linking, not proof of a dynamic board loader.
RVV executes the complete generated root with two COMDAT startup providers,
several VLENs, scalar bound fallbacks and hostile fuel yields on both widths.
"""
from contextlib import nullcontext
import argparse
import os
from pathlib import Path
import re
import shutil
import tempfile
from check_typed_ir_rv import run, ROOT

FIX = ROOT / 'tests/typed_ir'
PLUGIN = '''unsafe module.
mathOp x = x * 3.
twice x = mathOp x + mathOp x.
greeting u = "mod".
wide a b c d e f g h i = a+b+c+d+e+f+g+h+i.
wideCall x = wide x 2 3 4 5 6 7 8 9.
'''
RVV = '''unsafe module.
plus a x = a + x.
probe z v = Vec.fold plus z v.
'''
SUPPORT = (FIX / 'kernel_oracle.c').read_text().split('extern V fpr_fn_probeDiv')[0]
SUPPORT = SUPPORT.replace('    *(volatile unsigned *)0x100000 = code ?', '''
    if(code) { char buf[20]; unsigned n=0,x=code; do { buf[n++]='0'+x%10;x/=10; } while(x);
        while(n) { char one[]={buf[--n],0};say(one); }say("\\n"); }
    *(volatile unsigned *)0x100000 = code ?''')
PLUGIN_ORACLE = r'''
extern V fpr_fn_mathOp(V), fpr_fn_twice(V), fpr_fn_greeting(V), fpr_fn_wideCall(V);
extern uintptr_t fpr_modtab[];
struct Str { uint32_t tid,var; uintptr_t len; unsigned char bytes[]; };
static int eq(struct Str *s, const char *t) {
    unsigned i=0; for (;t[i];i++) if(i>=s->len || s->bytes[i]!=(unsigned char)t[i]) return 0;
    return i==s->len && s->tid==9000;
}
int main(void) {
    __asm__ volatile("mv tp,%0" :: "r"(hart) : "memory");
    hart[57]=0; hart[58]=(V)UINTPTR_MAX;
    for (V x=-300;x<=300;x++) {
        hart[0]=1; CHECK(fpr_fn_mathOp(tag(x))==tag(3*x));
        hart[0]=1; CHECK(fpr_fn_twice(tag(x))==tag(6*x));
        hart[0]=1; CHECK(fpr_fn_wideCall(tag(x))==tag(x+44));
    }
    hart[0]=1; CHECK(eq((void *)fpr_fn_greeting((V)&fpr_unit),"mod"));
    CHECK(fpr_modtab[0]==0x4650524d && fpr_modtab[1]==1);
    unsigned rows=0, found=0;
    for(uintptr_t *r=fpr_modtab+3;*r;r+=4) {
        CHECK(((struct Str *)r[0])->tid==9000 && ((struct Str *)r[3])->tid==9000);
        if(eq((void *)r[1],"mathOp")) {
            uintptr_t *pap=(void *)r[2];
            /* PAP: uint32 tid,var, then code pointer, arity and argc. */
            CHECK(((uint32_t *)pap)[0]==9001);
            uintptr_t *fields=(void *)((char *)pap+8);
            CHECK(fields[0]==(uintptr_t)fpr_fn_mathOp && fields[1]==1 && fields[2]==0);
            hart[0]=1; CHECK(((V (*)(V))fields[0])(tag(14))==tag(42)); found++;
        }
        rows++;
    }
    CHECK(rows==5 && found==1 && yields>=1805);
    say("TYPED_RV_PLUGIN_PASS\n"); return 0;
}
'''
RVV_ORACLE = r'''
extern V fpr_fn_probe(V,V);
int main(void) {
    __asm__ volatile("mv tp,%0" :: "r"(hart) : "memory");
    hart[57]=0; hart[58]=(V)UINTPTR_MAX;
    uintptr_t status;
    __asm__ volatile("csrr %0,mstatus" : "=r"(status));
    CHECK((status&0x600)==0); /* hook must enable V, not the test's CRT */
    extern void fpr_rvv_enable(void); fpr_rvv_enable(); fpr_rvv_enable();
    __asm__ volatile("csrr %0,mstatus" : "=r"(status)); CHECK((status&0x600)==0x600);
    V cells[260]; uint8_t kinds[]={1}; Col col={260,cells}; Col *cols[]={&col};
    if(TRAP_CASE) {
        Vec v={9006,1,2,0,0,1,kinds,cols};cells[0]=INTPTR_MAX/2;cells[1]=1;
        hart[0]=1;fpr_fn_probe(tag(0),(V)&v);oracle_finish(__LINE__);
    }
    unsigned cases=0;
    for(int n=0;n<=257;n++) for(int mode=0;mode<4;mode++) {
        Vec v={9006,1,n,0,0,1,kinds,n?cols:0};
        V sum=0;
        for(int i=0;i<n;i++) { cells[i]=(i%7)-3; sum+=cells[i]; }
        V start=mode==2 ? INTPTR_MAX/2-1000 : mode==1 ? 0 : 7;
        if(mode==1 && n>=2) { sum-=cells[0]+cells[1]; cells[0]=INTPTR_MAX/2; cells[1]=-cells[0]; }
        if(mode==3 && n>=3) { sum-=cells[0]+cells[1]+cells[2]; cells[0]=1;cells[1]=2;cells[2]=3;sum+=6; }
        used=0;hart[0]=1;
        V pair=fpr_fn_probe(tag(start),(V)&v);
        CHECK(*(V*)((char*)pair+8)==tag(start+sum));
        CHECK(*(V*)((char*)pair+8+sizeof(V))==(V)&v && v.len==n);
        cases++;
    }
    CHECK(yields>cases && fallbacks==0);
    say("TYPED_RVV_STARTUP_PASS\n"); return 0;
}
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--require-execution', action='store_true')
    ap.add_argument('--keep-dir', type=Path, help='retain assembly and ELF artifacts in this directory')
    args = ap.parse_args()
    if args.keep_dir: args.keep_dir.mkdir(parents=True,exist_ok=True)
    env = {k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_NO_INLINE='1',
               FPR_TYPED_IR_STRICT='all', FPR_NO_SCALAR_WORKERS='1', FPR_NO_FIELD_WORKERS='1')
    for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig','/usr/local/opt/libarchive/lib/pkgconfig'):
        if Path(keg).is_dir():
            env['PKG_CONFIG_PATH']=keg+':'+env.get('PKG_CONFIG_PATH','');break
    run(['make','fpr'],env)
    with (nullcontext(args.keep_dir) if args.keep_dir else tempfile.TemporaryDirectory(prefix='fpr-rv-startup-')) as d:
        tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
        for width in ('32','64'):
            missing=[t for t in ('riscv64-unknown-elf-gcc','riscv64-unknown-elf-readelf','qemu-system-riscv'+width) if not shutil.which(t)]
            assert not (missing and args.require_execution),missing
            for vector in (False,True):
                source=tmp/'probe.fpr';source.write_text(RVV if vector else PLUGIN)
                asm=tmp/'probe.s'
                command=[ROOT/'fpr','compile','--system=bare-metal','--target=rv'+width,'--plugin']
                if vector: command+=['--rvv']
                run([*command,source,asm],env)
                text=asm.read_text();units=Path(str(asm)+'.units').read_text().splitlines()
                assert '# typed IR: no translation' in text
                assert all('# typed IR: no translation' in Path(p).read_text() for p in units)
                assert 'la.tls' not in text and 'fpr_g_tlsoff' not in text
                assert re.search(r'\bmv t3, tp\b',text)
                assert 'fpr_modtab:' in text
                assert text.count('fpr_rvv_enable:')==int(vector)
                assert ('vsetvli' in text)==vector
                warm=tmp/'warm.s';run([*command,source,warm],env)
                assert warm.read_bytes()==asm.read_bytes()
                print(f'RV{width} {"RVV" if vector else "plugin"}: strict native closure, data, cold/warm PASS',flush=True)
                if missing:
                    print('execution SKIP: '+', '.join(missing));continue
                crt=tmp/'crt.S';crt.write_text((FIX/'kernel_crt.S').read_text().replace('sd ra','sw ra').replace('ld ra','lw ra') if width=='32' else (FIX/'kernel_crt.S').read_text())
                oracle=tmp/'oracle.c'
                support=SUPPORT
                if vector:
                    support=support.replace('hart[0]=1; yields++;', 'hart[0]=1; yields++; __asm__ volatile("vsetivli zero,1,e32,m1,ta,ma; vmv.v.i v0,-1; vmv.v.i v1,-1; vmv.v.i v2,-1; vmv.v.i v3,-1; vmv.v.i v4,-1; vmv.v.i v8,-1; vmv.v.i v9,-1; vmv.v.i v10,-1" ::: "memory");')
                oracle.write_text(support+(RVV_ORACLE if vector else PLUGIN_ORACLE))
                extra=[]
                if vector:
                    # Compile a separate functionless module: its identical hook
                    # must survive direct-data emission and COMDAT linking.
                    empty=tmp/'empty.fpr';empty.write_text('unsafe module.\n')
                    other=tmp/'empty.s';run([*command,empty,other],env)
                    assert '# typed IR: no translation' in other.read_text()
                    assert other.read_text().count('fpr_rvv_enable:')==1
                    # Both plugin tables are strong globals; this link tests only
                    # startup coalescing, independent of module registry policy.
                    hook=tmp/'other.s';othertext=other.read_text()
                    hook.write_text(othertext[:othertext.index('    .section .rodata')])
                    extra=[hook]
                if vector:
                    # Until rollback retirement, mixed and all-legacy units must
                    # also have exactly one startup hook in the assembled unit.
                    for backend in ('legacy','mixed'):
                        probe=tmp/(backend+'.s')
                        src=tmp/(backend+'.fpr')
                        src.write_text(RVV + ('wideFrame x = ['+', '.join('plus x 1' for _ in range(300))+'].\n' if backend=='mixed' else ''))
                        mode=dict(env,FPR_TYPED_IR_BACKEND=backend,FPR_TYPED_IR_STRICT='probe' if backend=='mixed' else '')
                        run([*command,src,probe],mode)
                        code=probe.read_text()
                        assert code.count('fpr_rvv_enable:')==1
                        assert '# typed IR: no translation' not in code
                        run(['riscv64-unknown-elf-gcc','-march=rv'+width+'imv_zicsr_zifencei',
                             '-mabi='+('ilp32' if width=='32' else 'lp64'),'-c',probe,'-o',tmp/'rollback.o'],env)
                    # Executable routing also emits the native preamble.
                    src=tmp/'executable.fpr';src.write_text(RVV.replace('unsafe module.','unsafe base.')+'main = Unit.\n')
                    executable=tmp/'executable.s'
                    run([*[c for c in command if c!='--plugin'],src,executable],env)
                    assert '# typed IR: no translation' in executable.read_text()
                    assert executable.read_text().count('fpr_rvv_enable:')==1
                elf=tmp/'probe.elf'
                run(['riscv64-unknown-elf-gcc','-march=rv'+width+('imv_zicsr_zifencei' if vector else 'im_zicsr_zifencei'),
                     '-mabi='+('ilp32' if width=='32' else 'lp64'),'-mcmodel=medany','-msmall-data-limit=0','-O2',
                     '-ffreestanding','-nostdlib','-fno-builtin','-fno-tree-vectorize','-T',FIX/'kernel_link.ld',crt,asm,*extra,oracle,'-o',elf],env)
                symbols=run(['riscv64-unknown-elf-readelf','-sW',elf],env)
                assert len(re.findall(r'\bGLOBAL\s+DEFAULT\s+\d+\s+fpr_rvv_enable$',symbols,re.M))==int(vector)
                for vlen in ((128,256,512) if vector else (None,)):
                    cpu=['-cpu',f'rv{width},v=true,vlen={vlen},elen=64'] if vector else ['-cpu',f'rv{width},v=false']
                    result=run(['qemu-system-riscv'+width,'-machine','virt','-smp','1','-m','16M',*cpu,
                                '-nographic','-bios','none','-kernel',elf],env)
                    assert ('TYPED_RVV_STARTUP_PASS' if vector else 'TYPED_RV_PLUGIN_PASS') in result,result
                    print(f'RV{width} {"RVV VLEN="+str(vlen) if vector else "plugin PAP/table, args 9"}: QEMU execution PASS',flush=True)
                if vector:
                    trapped=tmp/'trap.elf'
                    run(['riscv64-unknown-elf-gcc','-march=rv'+width+'imv_zicsr_zifencei',
                         '-mabi='+('ilp32' if width=='32' else 'lp64'),'-mcmodel=medany','-msmall-data-limit=0','-O2',
                         '-DTRAP_CASE=1','-ffreestanding','-nostdlib','-fno-builtin','-fno-tree-vectorize',
                         '-T',FIX/'kernel_link.ld',crt,asm,*extra,oracle,'-o',trapped],env)
                    result=run(['qemu-system-riscv'+width,'-machine','virt','-m','16M','-cpu',
                                f'rv{width},v=true,vlen=128,elen=64','-nographic','-bios','none','-kernel',trapped],env)
                    assert 'TYPED_KERNEL_TRAP_PASS' in result,result
                    print(f'RV{width} RVV unsafe lane strip falls back to scalar checked overflow PASS',flush=True)


if __name__=='__main__': main()
