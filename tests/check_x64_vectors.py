#!/usr/bin/env python3
"""Execute the generated x64 vector kernels against independent C references."""
import re, subprocess, tempfile, platform, shutil
from pathlib import Path
root=Path(__file__).resolve().parents[1]
mac=platform.system() == 'Darwin'
native=platform.machine() in ('x86_64','AMD64')
rosetta=mac and not native and subprocess.run(['arch','-x86_64','/usr/bin/true'],capture_output=True).returncode == 0
if not (native or rosetta):
    print('x64 vector execution: SKIP (requires native x64 or Rosetta)')
    raise SystemExit(0)
temporary=tempfile.TemporaryDirectory(prefix='fpr-x64-vectors-')
tmp=Path(temporary.name)
def kernels(fixture, name):
    output = tmp / (name + '.s')
    subprocess.run([str(root/'fprc'), '--profile=base', '--target=x64',
                    str(root/'tests/base'/fixture), str(output)], cwd=root,
                   capture_output=True, text=True, check=True, timeout=120)
    assembly = output.read_text().split('# ---- Vec specializations', 1)[1].split('\n', 1)[1]
    assembly = assembly.split('    .section')[0].split('    .rodata')[0]
    # Keep instructions intact; adapt only platform symbol/TLS linkage.
    assembly = assembly.replace('%fs:fpr_posix_hart@tpoff', 'probe_hart(%rip)')
    assembly = assembly.replace('%fs:fpr_x64_a6@tpoff', 'probe_a6(%rip)')
    assembly = assembly.replace('%fs:fpr_x64_a7@tpoff', 'probe_a7(%rip)')
    if mac:
        assembly = re.sub(r'\bfpr_[A-Za-z0-9_]+\b', lambda m: '_'+m.group(), assembly)
        for symbol in ('probe_hart', 'probe_a6', 'probe_a7'):
            assembly = assembly.replace(symbol+'(%rip)', '_'+symbol+'(%rip)')
    output.write_text('.text\n'+assembly)
    return output, assembly

scalar_path, a = kernels('veccaps.fpr', 'scalar-kernels')
fold_path, fold_assembly = kernels('veccaps_fold.fpr', 'captured-fold-kernels')
# Referenced object constants need addresses even when guards never fall back.
objs=set(re.findall(r'\bfpr_obj_[A-Za-z0-9_]+', (a+fold_assembly).replace('_fpr_obj_','fpr_obj_')))
Path(str(tmp/'fpr-x64-kernel-probe.c')).write_text('''
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <assert.h>
typedef intptr_t V;
static intptr_t hart[256]={1};
static int fuel_calls;
static void clobber(void) {
 __asm__ volatile("pxor %%xmm2, %%xmm2; pxor %%xmm3, %%xmm3; pxor %%xmm4, %%xmm4; pxor %%xmm5, %%xmm5; pxor %%xmm6, %%xmm6; pxor %%xmm7, %%xmm7" ::: "xmm2","xmm3","xmm4","xmm5","xmm6","xmm7");
}
void *probe_hart=hart;
intptr_t probe_a6,probe_a7;
void fpr_fuel_exhausted(void) { fuel_calls++; clobber(); hart[0]=1; }
void *fpr_alloc(intptr_t n) { clobber(); return calloc(1,n); }
void fpr_panic(void *v) { abort(); }
void fpr_apply(void) { abort(); }
void fpr_vec_map(void) { abort(); }
void fpr_vec_filter(void) { abort(); }
void fpr_vec_fold(void) { abort(); }
'''+'\n'.join(f'char {o}[40];' for o in objs)+'''
typedef struct {intptr_t cap,*base;} Col;
typedef struct {uint32_t tid,var;intptr_t len,eltid,elvar,ncols;uint8_t *kinds;Col **cols;} Vec;
extern Vec *fpr_vspec_map_affine(V,V,Vec*);
extern Vec *fpr_vspec_filter_above(V,Vec*);
extern Vec *fpr_vspec_mvmap_bump9(V,Vec*);
extern Vec *fpr_vspec_rfilter_keep9(Vec*);
extern void *fpr_vspec_fold_lifted_x5f31(V,Vec*);
extern void *fpr_vspec_fold_step(V,V,V,Vec*);
static Vec *mk(int n,int k,int rep) {
 Vec *v=calloc(1,sizeof *v);v->tid=9006;v->var=rep;v->len=n;v->ncols=k;
 v->kinds=calloc(k<8?8:k,1);v->cols=calloc(k,sizeof(Col*));
 for(int j=0;j<k;j++){v->kinds[j]=1;v->cols[j]=calloc(1,sizeof(Col));v->cols[j]->cap=n;v->cols[j]->base=calloc(n?n:1,8);for(int i=0;i<n;i++)v->cols[j]->base[i]=i+j;}
 return v;
}
int main(void) {
 for(int n=0;n<100;n++) {
  Vec *v=mk(n,1,1);assert(fpr_vspec_map_affine(5,3,v)==v);
  for(int i=0;i<n;i++)assert(v->cols[0]->base[i]==2*i+1);
  fpr_vspec_filter_above(11,v);
  int kept=0;for(int i=0;i<n;i++)if(2*i+1>5)assert(v->cols[0]->base[kept++]==2*i+1);
  assert(v->len==kept);
  void *pair=fpr_vspec_fold_lifted_x5f31(1,v);
  intptr_t s=0;for(int i=0;i<kept;i++)s+=v->cols[0]->base[i];
  assert(*(intptr_t*)((char*)pair+8)==2*s+1);
 }
 Vec *v=mk(1000,9,3);
 // Set the shape identity from the generated guard before calling the map.
 v->eltid=SHAPE;v->elvar=9;
 assert(fpr_vspec_mvmap_bump9(1,v)==v);
 for(int i=0;i<1000;i++){assert(v->cols[0]->base[i]==9*i+36);for(int j=1;j<9;j++)assert(v->cols[j]->base[i]==2*(i+j));}
 v=mk(1000,9,3);v->eltid=SHAPE;v->elvar=9;
 fpr_vspec_rfilter_keep9(v);assert(v->len==559);
 for(int i=0;i<559;i++)for(int j=0;j<9;j++)assert(v->cols[j]->base[i]==441+i+j);
 v=mk(1000,9,3);
 void *pair=fpr_vspec_fold_step(5,7,15,v); // tagged scale=2, bias=3, initial=7
 intptr_t total=7;
 for(int i=0;i<1000;i++)total+=2*(9*i+36)+3;
 assert(*(intptr_t*)((char*)pair+8)==2*total+1);
 assert(fuel_calls>100);
 puts("x64 kernels: 100 scalar map/filter/fold lengths, nine-column map/filter, captured wide fold and clobbering calls PASS");
}
''')
# x64 shape guard emits immediate tid into r11.
guard=a[a.index(('_' if mac else '')+'fpr_vspec_mvmap_bump9:'):]
shape=re.search(r'movq 16\(%rsi\), %r10\s+movq \$(\d+), %r11',guard).group(1)
p=Path(str(tmp/'fpr-x64-kernel-probe.c'));p.write_text(p.read_text().replace('SHAPE',shape))
subprocess.run([shutil.which('clang') or 'cc',*(['-arch','x86_64'] if mac else []),'-O2',str(scalar_path),str(fold_path),str(p),'-o',str(tmp/'fpr-x64-kernel-probe-v2')],check=True,timeout=60)
if mac: subprocess.run(['codesign','--force','--sign','-',str(tmp/'fpr-x64-kernel-probe-v2')],capture_output=True,check=True)
subprocess.run([*(['arch','-x86_64'] if rosetta else []),str(tmp/'fpr-x64-kernel-probe-v2')],check=True,timeout=60)
