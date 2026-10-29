#!/usr/bin/env python3
"""Typed ESP-IDF host (RV32): emission and a freestanding execution oracle.

On an ESP-IDF board the posix runtime keeps the hart in the thread-local
`fpr_esp_hart`, read local-exec (`lui/add/lw %tprel`) with a 32-bit word. This
check compiles for `--host=esp-idf` with the typed backend, asserts that form
in every function (no `mv tp`, no `fpr_posix_hart`), then links the native
functions statically against a C oracle whose crt sets tp to the TLS block, and
runs them under qemu-system-riscv32. The board itself (the P4) is the
acceptance gate; it is not available here.
"""
import argparse, os, re, shutil, subprocess, tempfile
from pathlib import Path
from fuel_wrapper import fuel_wrapper

ROOT = Path(__file__).resolve().parents[1]
NAMES = ['eArith', 'eChoose', 'eLoop', 'eWide', 'eWideCall', 'eString', 'eDeep']
TOOLS = ['riscv64-unknown-elf-gcc', 'qemu-system-riscv32']

PROGRAM = '''unsafe base.
eArith : Int -> Int -> Int.
eArith a b = a * b + a - b.
eChoose : Int -> Int -> Int.
eChoose a b = if a < b then a else b.
eLoop : Int -> Int -> Int -> Int.
eLoop n a b = if n == 0 then a else eLoop (n - 1) b (a + b).
eWide : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int.
eWide a b c d e f g h i = a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g + 8*h + 9*i.
eWideCall : Int -> Int.
eWideCall n = eWide n 2 3 4 5 6 7 8 9.
eString : Unit -> String.
eString u = "esp".
eDeep : Int -> Int.
eDeep n = if n == 0 then 0 else 1 + eDeep (n - 1).
main = Unit.
'''

CRT = '''
.section .text.entry,"ax",@progbits
.globl _start
_start:
    la sp, _stack_top
    la tp, __tls_start
    la t0, trap
    csrw mtvec, t0
    call main
    tail oracle_finish
.balign 4
trap:
    li a0, 1
    tail oracle_finish
.text
.globl fpr_fuel_exhausted
fpr_fuel_exhausted:
    addi sp, sp, -16
    sw ra, 12(sp)
    call oracle_tick
    lw ra, 12(sp)
    addi sp, sp, 16
    li a0, 0
    li a1, 0
    li a2, 0
    li a3, 0
    li a4, 0
    li a5, 0
    li a6, 0
    li a7, 0
    li t0, 0
    li t1, 0
    li t2, 0
    li t3, 0
    li t4, 0
    li t5, 0
    li t6, 0
    ret
'''

LINK = '''OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M }
SECTIONS {
 .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
 .rodata : { *(.rodata .rodata.*) } > RAM
 .data : { *(.data .data.*) } > RAM
 .tdata : { __tls_start = .; *(.tdata .tdata.*) } > RAM
 .tbss : { *(.tbss .tbss.*) } > RAM
 .bss (NOLOAD) : { *(.bss .bss.* COMMON) } > RAM
 _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
'''

ORACLE = r'''
#include <stdint.h>
typedef intptr_t V;
/* initialised, so the cells are in .tdata (a static freestanding image gives .tbss no memory) */
__thread V tls_anchor = 1;
__thread V *fpr_esp_hart = (V *)4;
static V hart[64];
static unsigned yields;
static uint32_t heap[8192];
static unsigned used;
__attribute__((noreturn)) void oracle_finish(int code) {
    if (code) {
        volatile unsigned char *uart=(void *)0x10000000;
        char buf[24]; unsigned n=0, x=(unsigned)code;
        do { buf[n++]=(char)('0'+x%10); x/=10; } while(x);
        while(n) { while (!(uart[5]&32)) {} uart[0]=buf[--n]; }
        while (!(uart[5]&32)) {} uart[0]='\n';
    }
    *(volatile unsigned *)0x100000 = code ? 0x13333 : 0x5555;
    for (;;) {}
}
static void say(const char *msg) {
    volatile unsigned char *uart=(void*)0x10000000;
    for(;*msg;msg++) { while(!(uart[5]&32)) {} uart[0]=*msg; }
}
#define CHECK(ok) do { if (!(ok)) oracle_finish(__LINE__); } while (0)
static V tag(V x) { return (V)(((uintptr_t)x << 1) | 1); }
void oracle_tick(void) { hart[0]=1; yields++; for (int i=1; i<=56; i++) hart[i]=tag(-777); }
uintptr_t fpr_stack_grow(void) { oracle_finish(2); }
V fpr_prim_fn__x2b(V a,V b) { return tag((a>>1)+(b>>1)); }
V fpr_prim_fn__x2d(V a,V b) { return tag((a>>1)-(b>>1)); }
V fpr_prim_fn__x2a(V a,V b) { return tag((a>>1)*(b>>1)); }
struct Bool { uint32_t tid,var; } fpr_unit={0,0}, fpr_false={1,0}, fpr_true={1,1};
V fpr_prim_fn__x3d_x3d(V a,V b) { return (V)(a==b ? &fpr_true : &fpr_false); }
V fpr_prim_fn__x3c(V a,V b) { return (V)(a<b ? &fpr_true : &fpr_false); }
V fpr_alloc(V bytes) { CHECK(used+(bytes+3)/4 < 8192); V r=(V)&heap[used]; used+=(bytes+3)/4; return r; }
V fpr_panic(V x) { (void)x; oracle_finish(3); }
struct Str { uint32_t tid,var; uintptr_t len; unsigned char bytes[]; };
extern V fpr_fn_eArith(V,V), fpr_fn_eChoose(V,V), fpr_fn_eLoop(V,V,V), fpr_fn_eWideCall(V), fpr_fn_eString(V), fpr_fn_eDeep(V);
int main(void) {
    fpr_esp_hart = hart;
    hart[57]=0; hart[58]=(V)UINTPTR_MAX; hart[0]=1;
    unsigned cases=0;
    for (V a=-20;a<=20;a++) for(V b=-10;b<=10;b++) {
        CHECK(fpr_fn_eArith(tag(a),tag(b))==tag(a*b+a-b)); cases++;
        CHECK(fpr_fn_eChoose(tag(a),tag(b))==tag(a<b?a:b)); cases++;
    }
    for (V n=0;n<40;n++) {
        V a=1, b=1; for (V i=0;i<n;i++) { V t=a+b; a=b; b=t; }
        CHECK(fpr_fn_eLoop(tag(n),tag(1),tag(1))==tag(a)); cases++;
    }
    for (V n=-50;n<=50;n++) {
        CHECK(fpr_fn_eWideCall(tag(n))==tag(n+2*2+3*3+4*4+5*5+6*6+7*7+8*8+9*9)); cases++;
        CHECK(fpr_fn_eDeep(tag(n<0?-n:n))==tag(n<0?-n:n)); cases++;
    }
    struct Str *s=(void *)fpr_fn_eString((V)&fpr_unit);
    CHECK(s->tid==9000 && s->len==3 && s->bytes[0]=='e' && s->bytes[1]=='s' && s->bytes[2]=='p'); cases++;
    CHECK(yields>=cases);
    say("TYPED_ESP_PASS\n");
    return 0;
}
'''


def run(args, env, ok=True):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=600)
    assert (p.returncode == 0) == ok, (args, p.returncode, p.stdout[-3000:], p.stderr[-3000:])
    return p.stdout + p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--require-execution', action='store_true')
    args = ap.parse_args()
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig', '/usr/local/opt/libarchive/lib/pkgconfig'):
        if Path(keg).is_dir():
            env['PKG_CONFIG_PATH'] = keg + ':' + env.get('PKG_CONFIG_PATH', '')
            break
    run(['make', 'fpr'], env)
    with tempfile.TemporaryDirectory(prefix='fpr-esp-') as d:
        tmp = Path(d)
        env['XDG_CACHE_HOME'] = os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache'))
        source = tmp / 'esp.fpr'
        source.write_text(PROGRAM)
        asm = tmp / 'esp.s'
        run([ROOT / 'fpr', 'compile', '--system=posix', '--host=esp-idf', '--target=rv32', source, asm],
            dict(env, FPR_TYPED_IR_STRICT='all'))
        text = asm.read_text()
        units = [Path(p).read_text() for p in Path(str(asm) + '.units').read_text().split()]
        whole = text + ''.join(units)
        bodies = re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# (?:wcet|native-insns-v1):)', text)
        chosen = {title.split()[0]: body for title, body in bodies if title.split()[0] in NAMES}
        assert sorted(chosen) == sorted(NAMES), sorted(chosen)
        assert '# typed IR: no translation' in text
        form = re.compile(r'lui t3, %tprel_hi\(fpr_esp_hart\)\n\s*add t3, t3, tp, %tprel_add\(fpr_esp_hart\)\n\s*lw t3, %tprel_lo\(fpr_esp_hart\)\(t3\)')
        for name, body in chosen.items():
            assert form.search(body) and 'fpr_posix_hart' not in body and not re.search(r'\bmv\s+t\d,\s*tp\b', body), name
        assert 'fpr_posix_hart' not in whole and not re.search(r'\bmv\s+t\d,\s*tp\b', whole)
        print('Native hart access and complete typed emission PASS',flush=True)
        missing = [t for t in TOOLS if not shutil.which(t)]
        if missing:
            assert not args.require_execution, missing
            print('ESP-IDF execution SKIP: ' + ', '.join(missing))
            return
        objects = re.findall(r'(?ms)^    \.balign [48]\n\.Ltirstr[^:\n]*:\n    \.long 9000\n.*?(?=^$)', text)
        probe = tmp / 'probe.s'
        probe.write_text('.text\n' + ''.join(f'    .globl fpr_fn_{n}\n' for n in NAMES)
                         + '\n'.join(chosen[n] for n in NAMES) + fuel_wrapper(whole) + '\n.section .rodata\n' + '\n'.join(objects) + '\n')
        crt = tmp / 'crt.S'; crt.write_text(CRT)
        ld = tmp / 'link.ld'; ld.write_text(LINK)
        oracle = tmp / 'oracle.c'; oracle.write_text(ORACLE)
        exe = tmp / 'esp.elf'
        run(['riscv64-unknown-elf-gcc', '-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-mcmodel=medany',
             '-msmall-data-limit=0', '-O2', '-ffreestanding', '-nostdlib', '-fno-builtin', '-static',
             '-T', ld, crt, probe, oracle, '-o', exe], env)
        result = run(['qemu-system-riscv32', '-machine', 'virt', '-smp', '1', '-m', '16M',
                      '-nographic', '-bios', 'none', '-kernel', exe], env)
        assert 'TYPED_ESP_PASS' in result, result
        print('typed ESP-IDF executes under QEMU (rv32): 2,105 cases through the local-exec hart cell, nine-argument spills, a string, fuel yields PASS', flush=True)


if __name__ == '__main__':
    main()
