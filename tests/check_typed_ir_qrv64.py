#!/usr/bin/env python3
"""Typed QOS RISC-V apps (qrv64): emission and a freestanding execution oracle.

A loaded QOS app or plugin on RV64 borrows the host's thread-local hart cell
through the displacement QOS publishes in `fpr_g_tlsoff`: the hart is
`*(tp + fpr_g_tlsoff)`, read at every entry, after a stack-segment change and
at every safepoint (RV64.lowerQosRV64's form). This check compiles an app with
the typed backend, asserts that form and nothing else (no TLS relocations, no
`mv tp`, no PIC), then links its native functions statically against a C oracle
whose crt sets tp to a block and whose fuel hook moves `fpr_g_tlsoff` between
two cells holding two harts, so a stale hart read would be caught, and runs it
under qemu-system-riscv64. A loaded QOS image on RISC-V hardware is not
available here; the real plane is the acceptance gate.
"""
import argparse, os, re, shutil, subprocess, tempfile
from pathlib import Path
from fuel_wrapper import fuel_wrapper

ROOT = Path(__file__).resolve().parents[1]
NAMES = ['qArith', 'qChoose', 'qLoop', 'qWide', 'qWideCall', 'qString', 'qFloat', 'qDeep']
TOOLS = ['riscv64-unknown-elf-gcc', 'riscv64-unknown-elf-readelf', 'qemu-system-riscv64']

APP = '''unsafe base.
qArith : Int -> Int -> Int.
qArith a b = a * b + a - b.
qChoose : Int -> Int -> Int.
qChoose a b = if a < b then a else b.
qLoop : Int -> Int -> Int -> Int.
qLoop n a b = if n == 0 then a else qLoop (n - 1) b (a + b).
qWide : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int.
qWide a b c d e f g h i = a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g + 8*h + 9*i.
qWideCall : Int -> Int.
qWideCall n = qWide n 2 3 4 5 6 7 8 9.
qString : Unit -> String.
qString u = "qos".
qFloat : F64 -> F64.
qFloat x = x * 2.0 + 0.5.
qDeep : Int -> Int.
qDeep n = if n == 0 then 0 else 1 + qDeep (n - 1).
main = Unit.
'''

CRT = '''
.section .text.entry,"ax",@progbits
.globl _start
_start:
    la sp, _stack_top
    la tp, probe_block
    la t0, trap
    csrw mtvec, t0
    li t0, 0x6000
    csrs mstatus, t0
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
    sd ra, 8(sp)
    call oracle_tick
    ld ra, 8(sp)
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
 .bss (NOLOAD) : { *(.bss .bss.* COMMON) } > RAM
 _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
'''

ORACLE = r'''
#include <stdint.h>
typedef intptr_t V;
/* tp points at probe_block; the hart cell is at tp + fpr_g_tlsoff. Two harts
   in two cells: the fuel hook moves the displacement between them. */
static V hartA[64], hartB[64];
V probe_block[8];
uintptr_t fpr_g_tlsoff = 2 * sizeof(V);
static unsigned yields, swaps;
static uintptr_t heap[8192];
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
static V bits(double d) { union { double d; V v; } c; c.d=d; return c.v; }
static V *current(void) { return *(V **)((char *)probe_block + fpr_g_tlsoff); }
void oracle_tick(void) {
    V *h = current();
    CHECK(h == hartA || h == hartB);
    h[0] = 1; yields++;
    for (int i=1; i<=56; i++) h[i]=tag(-777);
    /* the next read must see the other cell's hart */
    fpr_g_tlsoff = (fpr_g_tlsoff == 2 * sizeof(V)) ? 5 * sizeof(V) : 2 * sizeof(V);
    swaps++;
}
uintptr_t fpr_stack_grow(void) { oracle_finish(2); }
V fpr_prim_fn__x2b(V a,V b) { return tag((a>>1)+(b>>1)); }
V fpr_prim_fn__x2d(V a,V b) { return tag((a>>1)-(b>>1)); }
V fpr_prim_fn__x2a(V a,V b) { return tag((a>>1)*(b>>1)); }
V fpr_prim_fn_F64_x2e_x2a(V a,V b) { union { double d; V v; } x={.v=a}, y={.v=b}; return bits(x.d*y.d); }
V fpr_prim_fn_F64_x2e_x2b(V a,V b) { union { double d; V v; } x={.v=a}, y={.v=b}; return bits(x.d+y.d); }
struct Bool { uint32_t tid,var; } fpr_unit={0,0}, fpr_false={1,0}, fpr_true={1,1};
V fpr_prim_fn__x3d_x3d(V a,V b) { return (V)(a==b ? &fpr_true : &fpr_false); }
V fpr_prim_fn__x3c(V a,V b) { return (V)(a<b ? &fpr_true : &fpr_false); }
V fpr_alloc(V bytes) { CHECK(used+(bytes+7)/8 < 8192); V r=(V)&heap[used]; used+=(bytes+7)/8; return r; }
V fpr_panic(V x) { (void)x; oracle_finish(3); }
struct Str { uint32_t tid,var; uintptr_t len; unsigned char bytes[]; };
extern V fpr_fn_qArith(V,V), fpr_fn_qChoose(V,V), fpr_fn_qLoop(V,V,V), fpr_fn_qWideCall(V), fpr_fn_qString(V), fpr_fn_qFloat(V), fpr_fn_qDeep(V);
int main(void) {
    for (int i = 0; i < 2; i++) { V *h = i ? hartB : hartA; h[57]=0; h[58]=(V)UINTPTR_MAX; h[0]=1; }
    probe_block[2] = (V)hartA; probe_block[5] = (V)hartB;
    unsigned cases=0;
    for (V a=-20;a<=20;a++) for(V b=-10;b<=10;b++) {
        CHECK(fpr_fn_qArith(tag(a),tag(b))==tag(a*b+a-b)); cases++;
        CHECK(fpr_fn_qChoose(tag(a),tag(b))==tag(a<b?a:b)); cases++;
    }
    for (V n=0;n<60;n++) {
        V a=1, b=1; for (V i=0;i<n;i++) { V t=a+b; a=b; b=t; }
        CHECK(fpr_fn_qLoop(tag(n),tag(1),tag(1))==tag(a)); cases++;
    }
    for (V n=-50;n<=50;n++) {
        CHECK(fpr_fn_qWideCall(tag(n))==tag(n+2*2+3*3+4*4+5*5+6*6+7*7+8*8+9*9)); cases++;
        CHECK(fpr_fn_qFloat(bits((double)n*0.25))==bits((double)n*0.5+0.5)); cases++;
        CHECK(fpr_fn_qDeep(tag(n<0?-n:n))==tag(n<0?-n:n)); cases++;
    }
    struct Str *s=(void *)fpr_fn_qString((V)&fpr_unit);
    CHECK(s->tid==9000 && s->len==3 && s->bytes[0]=='q' && s->bytes[1]=='o' && s->bytes[2]=='s'); cases++;
    CHECK(yields>cases && swaps==yields && hartA[0]==1 && hartB[0]==1);
    say("TYPED_QRV64_PASS\n");
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
    with tempfile.TemporaryDirectory(prefix='fpr-qrv64-') as d:
        tmp = Path(d)
        env['XDG_CACHE_HOME'] = str(tmp / 'cache')
        source = tmp / 'app.fpr'
        source.write_text(APP)
        asm = tmp / 'app.s'
        run([ROOT / 'fpr', 'compile', '--target=qrv64', source, asm], dict(env, FPR_TYPED_IR_STRICT='all'))
        text = asm.read_text()
        units = [Path(p).read_text() for p in Path(str(asm) + '.units').read_text().split()]
        whole = text + ''.join(units)
        bodies = re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# (?:wcet|native-insns-v1):)', text)
        chosen = {title.split()[0]: body for title, body in bodies if title.split()[0] in NAMES}
        assert sorted(chosen) == sorted(NAMES), sorted(chosen)
        assert '# typed IR: no translation' in text
        borrow = re.compile(r'lla t3, fpr_g_tlsoff\n\s*ld t3, 0\(t3\)\n\s*add t3, t3, tp\n\s*ld t3, 0\(t3\)')
        for name, body in chosen.items():
            assert borrow.search(body) and 'tprel' not in body and 'la.tls' not in body and not re.search(r'\bmv\s+t\d,\s*tp\b', body), name
        assert '.option pic' not in whole and '%tprel' not in whole and not re.search(r'\bmv\s+t\d,\s*tp\b', whole)
        assert not re.search(r'^\s*j\s+(?!\.L)\S+', whole, re.M)
        # a plugin for the same host: the same form; the legacy rollback: separate units
        plugin = tmp / 'plugin.s'
        run([ROOT / 'fpr', 'compile', '--target=qrv64', '--plugin', source, plugin], dict(env, FPR_TYPED_IR_STRICT='all'))
        assert borrow.search(plugin.read_text())
        print('Native hart access and complete typed emission PASS',flush=True)
        missing = [t for t in TOOLS if not shutil.which(t)]
        if missing:
            assert not args.require_execution, missing
            print('qrv64 execution SKIP: ' + ', '.join(missing))
            return
        obj = tmp / 'app.o'
        run(['riscv64-unknown-elf-gcc', '-march=rv64imafd_zicsr_zifencei', '-mabi=lp64', '-c', asm, '-o', obj], env)
        relocs = run(['riscv64-unknown-elf-readelf', '-rW', obj], env)
        kinds = set(re.findall(r'R_RISCV_[A-Z0-9_]+', relocs))
        assert not any('TLS' in k or 'TPREL' in k for k in kinds), kinds
        objects = re.findall(r'(?ms)^    \.balign 8\n\.Ltirstr[^:\n]*:\n    \.long 9000\n.*?(?=^$)', text)
        probe = tmp / 'probe.s'
        # the scalar workers the unit emitted for its loops come along (unit-local symbols)
        workers = [body for title, body in bodies if title.split()[0].startswith('$worker.')]
        probe.write_text('.text\n' + ''.join(f'    .globl fpr_fn_{n}\n' for n in NAMES)
                         + '\n'.join([chosen[n] for n in NAMES] + workers) + fuel_wrapper(whole) + '\n.section .rodata\n' + '\n'.join(objects) + '\n')
        crt = tmp / 'crt.S'; crt.write_text(CRT)
        ld = tmp / 'link.ld'; ld.write_text(LINK)
        oracle = tmp / 'oracle.c'; oracle.write_text(ORACLE)
        exe = tmp / 'app.elf'
        run(['riscv64-unknown-elf-gcc', '-march=rv64imafd_zicsr_zifencei', '-mabi=lp64', '-mcmodel=medany',
             '-msmall-data-limit=0', '-O2', '-ffreestanding', '-nostdlib', '-fno-builtin', '-static',
             '-T', ld, crt, probe, oracle, '-o', exe], env)
        result = run(['qemu-system-riscv64', '-machine', 'virt', '-smp', '1', '-m', '16M',
                      '-nographic', '-bios', 'none', '-kernel', exe], env)
        assert 'TYPED_QRV64_PASS' in result, result
        print('typed qrv64 executes under QEMU: 2,125 cases through the borrowed hart cell, the displacement moved at every fuel yield, nine-argument spills, a string, F64 PASS', flush=True)


if __name__ == '__main__':
    main()
