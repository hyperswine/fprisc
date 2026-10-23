#!/usr/bin/env python3
"""Typed RV64 posix modules: emission, relocations and a freestanding execution oracle.

A loaded module (`--module` on rv64) reads the hart through initial-exec TLS
(`la.tls.ie fpr_posix_hart`, the GOT entry its host resolves) and is assembled
under `.option pic`, so its external references are GOT/PLT relocations. This
check compiles a module with the typed backend, asserts those forms and the
relocations the assembler produces, then links the module's native functions
statically against a C oracle whose crt sets tp to a TLS block holding
`fpr_posix_hart`, and runs them under qemu-system-riscv64. The real loader,
the host's TLS and 1/4-hart scheduling are check_rv64_linux.py's (Linux CI).
"""
import argparse, os, re, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = ['hartOK', 'mathOp', 'floatOp', 'greeting', 'twice']
TOOLS = ['riscv64-unknown-elf-gcc', 'riscv64-unknown-elf-readelf', 'qemu-system-riscv64']

MODULE = '''unsafe module.
nativeHart : Unit -> Bool.
hartOK u = nativeHart u.
mathOp : Int -> Int.
mathOp x = x * 3.
floatOp : F64 -> F64.
floatOp x = x * 2.0.
greeting : Unit -> String.
greeting u = "mod".
twice : Int -> Int.
twice x = mathOp x + mathOp x.
'''

CRT = '''
.section .text.entry,"ax",@progbits
.globl _start
_start:
    la sp, _stack_top
    la tp, __tls_start
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

# The TLS segment starts at .tdata; tp is its start (RISC-V's TP offset is 0),
# so a static link's initial-exec GOT entry is the cell's offset from tp.
LINK = '''OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M }
SECTIONS {
 .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
 .rodata : { *(.rodata .rodata.*) } > RAM
 .data.rel.ro : { *(.data.rel.ro .data.rel.ro.*) } > RAM
 .data : { *(.data .data.*) } > RAM
 .got : { *(.got .got.*) } > RAM
 .tdata : { __tls_start = .; *(.tdata .tdata.*) } > RAM
 .tbss : { *(.tbss .tbss.*) } > RAM
 .bss (NOLOAD) : { *(.bss .bss.* COMMON) } > RAM
 _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
'''

ORACLE = r'''
#include <stdint.h>
typedef intptr_t V;
/* Both cells are INITIALISED so they live in .tdata: a static freestanding
   image gives .tbss no memory of its own (it would alias .bss). */
__thread V tls_anchor = 1;
__thread V *fpr_posix_hart = (V *)8; /* the cell the module reads through la.tls.ie */
static V hart[64];
static unsigned yields, reads;
static uintptr_t heap[4096];
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
void oracle_tick(void) { hart[0]=1; yields++; for (int i=1; i<=56; i++) hart[i]=tag(-777); }
uintptr_t fpr_stack_grow(void) { oracle_finish(1); }
V fpr_prim_fn__x2b(V a,V b) { return tag((a>>1)+(b>>1)); }
V fpr_prim_fn__x2a(V a,V b) { return tag((a>>1)*(b>>1)); }
V fpr_prim_fn_F64_x2e_x2a(V a,V b) { union { double d; V v; } x={.v=a}, y={.v=b}; return bits(x.d*y.d); }
struct Bool { uint32_t tid,var; } fpr_unit={0,0}, fpr_false={1,0}, fpr_true={1,1};
V fpr_alloc(V bytes) { CHECK(used+(bytes+7)/8 < 4096); V r=(V)&heap[used]; used+=(bytes+7)/8; return r; }
V fpr_panic(V x) { (void)x; oracle_finish(1); }
/* the module's HAL import: true when the oracle's hart cell is set, read
   through the SAME TLS cell the module reads */
V fpr_g_nativeHart_call1(V u) { (void)u; reads++; return (V)(fpr_posix_hart ? &fpr_true : &fpr_false); }
struct Str { uint32_t tid,var; uintptr_t len; unsigned char bytes[]; };
extern V fpr_fn_hartOK(V), fpr_fn_mathOp(V), fpr_fn_floatOp(V), fpr_fn_greeting(V), fpr_fn_twice(V);
int main(void) {
    fpr_posix_hart = hart;
    hart[57]=0; hart[58]=(V)UINTPTR_MAX;
    unsigned cases=0;
    for (V x=-300; x<=300; x++) {
        hart[0]=1;
        CHECK(fpr_fn_mathOp(tag(x))==tag(3*x)); cases++;
        hart[0]=1;
        CHECK(fpr_fn_twice(tag(x))==tag(6*x)); cases++;
        hart[0]=1;
        CHECK(fpr_fn_floatOp(bits((double)x*0.25))==bits((double)x*0.5)); cases++;
    }
    hart[0]=1;
    CHECK(fpr_fn_hartOK((V)&fpr_unit)==(V)&fpr_true && reads==1); cases++;
    hart[0]=1;
    struct Str *s=(void *)fpr_fn_greeting((V)&fpr_unit);
    CHECK(s->tid==9000 && s->len==3 && s->bytes[0]=='m' && s->bytes[1]=='o' && s->bytes[2]=='d'); cases++;
    /* the hart was read through the TLS cell: every entry tick with fuel 1 yielded */
    CHECK(yields>=cases);
    say("TYPED_RV64_MODULE_PASS\n");
    return 0;
}
'''


def run(args, env, ok=True):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=600)
    assert (p.returncode == 0) == ok, (args, p.returncode, p.stdout[-3000:], p.stderr[-3000:])
    return p.stdout + p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--require-execution', action='store_true', help='fail when the RISC-V toolchain or QEMU is missing')
    args = ap.parse_args()
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig', '/usr/local/opt/libarchive/lib/pkgconfig'):
        if Path(keg).is_dir():
            env['PKG_CONFIG_PATH'] = keg + ':' + env.get('PKG_CONFIG_PATH', '')
            break
    run(['make', 'fpr'], env)
    with tempfile.TemporaryDirectory(prefix='fpr-rv64-module-') as d:
        tmp = Path(d)
        env['XDG_CACHE_HOME'] = str(tmp / 'cache')
        source = tmp / 'math.fpr'
        source.write_text(MODULE)
        asm = tmp / 'module.s'
        # the default backend, strict: every function of the module is native
        run([ROOT / 'fpr', 'compile', '--system=posix', '--target=rv64', '--plugin', source, asm],
            dict(env, FPR_TYPED_IR_STRICT='all'))
        text = asm.read_text()
        units = [Path(p).read_text() for p in Path(str(asm) + '.units').read_text().split()]
        whole = text + ''.join(units)
        bodies = re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# (?:wcet|native-insns-v1):)', text)
        chosen = {title.split()[0]: body for title, body in bodies if title.split()[0] in NAMES}
        assert sorted(chosen) == sorted(NAMES), sorted(chosen)
        assert '# typed IR: no translation' in text and text.count('    .option pic') == 1, text[:400]
        assert '.option pic' in whole and 'la.tls.ie' in whole
        for name, body in chosen.items():
            assert 'la.tls.ie t3, fpr_posix_hart' in body and 'tprel' not in body and not re.search(r'\bmv\s+t\d,\s*tp\b', body), name
        assert re.search(r'^\s*lla\s+\w+,\s*\.L', text, re.M), 'a unit-local label stays PC-relative under .option pic'
        assert not re.search(r'^\s*j\s+(?!\.L)\S+', whole, re.M), 'no short jumps to external symbols'
        # the legacy rollback keeps its own forms and a separate unit identity
        legacy = tmp / 'legacy.s'
        run([ROOT / 'fpr', 'compile', '--system=posix', '--target=rv64', '--plugin', source, legacy],
            dict(env, FPR_TYPED_IR_BACKEND='legacy'))
        assert '# typed IR: no translation' not in legacy.read_text()
        assert set(Path(str(asm) + '.units').read_text().split()).isdisjoint(Path(str(legacy) + '.units').read_text().split())
        print('typed RV64 module: every function native, la.tls.ie hart, .option pic, local labels PC-relative, legacy rollback separate PASS', flush=True)
        missing = [t for t in TOOLS if not shutil.which(t)]
        if missing:
            assert not args.require_execution, missing
            print('RV64 module relocations and execution SKIP: ' + ', '.join(missing))
            return
        # the assembler's relocations: the hart through the TLS GOT, calls through
        # the PLT, no local-exec TLS
        obj = tmp / 'module.o'
        run(['riscv64-unknown-elf-gcc', '-march=rv64imafd_zicsr_zifencei', '-mabi=lp64', '-c', asm, '-o', obj], env)
        relocs = run(['riscv64-unknown-elf-readelf', '-rW', obj], env)
        kinds = set(re.findall(r'R_RISCV_[A-Z0-9_]+', relocs))
        assert 'R_RISCV_TLS_GOT_HI20' in kinds and 'R_RISCV_CALL_PLT' in kinds, kinds
        assert not any(k.startswith('R_RISCV_TPREL') for k in kinds), kinds
        print('typed RV64 module assembles: R_RISCV_TLS_GOT_HI20 for the hart, R_RISCV_CALL_PLT for calls, no TPREL PASS', flush=True)
        # execution: the module's functions, statically linked against an oracle
        # whose crt sets tp to the TLS block holding fpr_posix_hart
        objects = re.findall(r'(?ms)^    \.balign 8\n\.Ltirstr[^:\n]*:\n    \.long 9000\n.*?(?=^$)', text)
        probe = tmp / 'probe.s'
        probe.write_text('    .option pic\n.text\n' + ''.join(f'    .globl fpr_fn_{n}\n' for n in NAMES)
                         + '\n'.join(chosen[n] for n in NAMES) + '\n.section .rodata\n' + '\n'.join(objects) + '\n')
        crt = tmp / 'crt.S'; crt.write_text(CRT)
        ld = tmp / 'link.ld'; ld.write_text(LINK)
        oracle = tmp / 'oracle.c'; oracle.write_text(ORACLE)
        exe = tmp / 'module.elf'
        run(['riscv64-unknown-elf-gcc', '-march=rv64imafd_zicsr_zifencei', '-mabi=lp64', '-mcmodel=medany',
             '-msmall-data-limit=0', '-O2', '-ffreestanding', '-nostdlib', '-fno-builtin', '-static',
             '-T', ld, crt, probe, oracle, '-o', exe], env)
        result = run(['qemu-system-riscv64', '-machine', 'virt', '-smp', '1', '-m', '16M',
                      '-nographic', '-bios', 'none', '-kernel', exe], env)
        assert 'TYPED_RV64_MODULE_PASS' in result, result
        print('typed RV64 module executes under QEMU: 1,805 cases through the initial-exec hart cell, a HAL import, a string, fuel yields PASS', flush=True)


if __name__ == '__main__':
    main()
