/* hal.c — the HAL binding module: the ONLY place hardware addresses live.
 *
 * Exports the discoverable-symbol surface that compiled FPRISC code links
 * against (every unknown name in a .fpr file becomes an extern fpr_g_*):
 *
 *   Devices    : device "name" -> Device            (table lookup by name)
 *   Registers  : reg8 dev off, reg32 dev off  -> Register (width in header)
 *   MMIO       : read reg -> Int, write reg v -> Unit
 *   Array Bit  : bitsLE len v, bitsBE len v, toInt b
 *   Bit ops    : BITSET BITCLEAR BITTEST BITMASK BITSHIFTL BITSHIFTR
 *                band bor bxor   (work on Int and on Array Bit where sensible)
 *
 * Why read/write can never be optimized away or reordered:
 *   1. the FPRISC compiler emits every application as a real `call` — naive
 *      codegen does no CSE/DCE/motion across effects by construction;
 *   2. the loads/stores here are volatile, so THIS compiler can't elide
 *      or reorder them either;
 *   3. fence io,io on each side pins device-visible ordering to program
 *      order even on real hardware with a weaker memory model.
 * Program order == bus order, end of story.
 *
 * ---- The device table --------------------------------------------------
 * Devices are DATA, not link-time symbols. One array, one entry per
 * peripheral, looked up by name at runtime. This is deliberately the same
 * shape the boot ROM's fdt_parse (see qos-boot-poc) would populate: swap
 * the static initializer below for a DTB walk and nothing above this file
 * changes. `setup`/`ioctl` are the escape hatch for device-specific
 * behavior (DMA descriptor init, IRQ enable, ...) that generic read/write
 * on a flat register can't express -- NULL when a device doesn't need one.
 */
#include "fpr.h"

typedef struct {
  const char *name;
  fpr_dev_t dev;
  void (*setup)(void);       /* optional: one-time device init, or NULL */
  V (*ioctl)(V op, V arg);   /* optional: device-specific escape hatch, or NULL */
} devtable_entry_t;

#define UART0_BASE 0x10000000UL
#define CLINT_BASE 0x02000000UL
#define VIRTIO0_BASE 0x10001000UL

extern void net_setup(void); /* net.c: probe virtio slots, bring up queues */
extern void blk_setup(void); /* blk.c: probe virtio slots, bring up disk queue */

static const devtable_entry_t devtable[] = {
  {"uart",  {T_DEVICE, 0, UART0_BASE}, NULL, NULL},
  {"clint", {T_DEVICE, 0, CLINT_BASE}, NULL, NULL},
  {"net",   {T_DEVICE, 0, VIRTIO0_BASE}, net_setup, NULL},
  {"blk",   {T_DEVICE, 0, VIRTIO0_BASE}, blk_setup, NULL},
};
#define NDEVICES (sizeof(devtable) / sizeof(devtable[0]))

/* raw console for the runtime/panic path -- deliberately NOT routed
 * through the table: this must work before any FPRISC code has run. */
static void uart_tx(char c) {
  volatile uint8_t *u = (volatile uint8_t *)UART0_BASE;
  while (!(u[5] & 0x20)) {} /* LSR.THRE */
  u[0] = (uint8_t)c;
}
/* a raw serial line: the core writes '\n', the wire wants "\r\n" */
void hal_putc(char c) {
  if (c == '\n') uart_tx('\r');
  uart_tx(c);
}

/* terminate QEMU with an exit code: the virt machine's sifive test
 * finisher at 0x100000 (0x5555 = pass/exit 0, code<<16|0x3333 = fail
 * with that code).  This is what lets `make run` and the test suite be
 * exit-code driven instead of timeout-killed.  A real-hardware HAL
 * backend makes this a no-op (or a board reset); every caller falls
 * through to a wfi park, so returning is always safe. */
/* ---- GPIO pins (the C HAL tier; docs/PINS.md) -----------------------
 * A 32-pin bank with runtime-settable direction -- the portable
 * contract System.qa serves as /pins/<n> URLs.  THIS backend is the
 * QEMU-virt SIM: out-pin writes latch; an in-pin reads the latch of
 * whatever out-pin it is WIRED to (Pin.wire, the sim's test jumper --
 * how a matrix keypress is emulated with zero hardware).  A silicon
 * backend replaces these bodies with the target's GPIO MMIO; Pin.* is
 * the raw tier every pin service sits on. */
#define NPINS 32
static uint32_t pin_feed_pat[NPINS];
static uint8_t pin_feed_n[NPINS], pin_feed_i[NPINS];
#define PIN_TRACE_CAP 4096
static uint16_t pin_trace[PIN_TRACE_CAP];
static uw pin_trace_n;
static uint8_t pin_mode[NPINS];  /* 0 = in, 1 = out */
static uint32_t pin_out;         /* out latch */
static int8_t pin_src[NPINS];    /* sim wiring: in-pin n fed by out-pin pin_src[n], -1 = float(0) */
static int pins_inited;
static void pins_init(void) {
  if (pins_inited) return;
  for (int i = 0; i < NPINS; i++) pin_src[i] = -1;
  pins_inited = 1;
}
static V h_pin_mode(V nv, V mv) {
  pins_init();
  sw n = UNTAG(nv);
  if (n < 0 || n >= NPINS) fpr_cpanic("Pin.mode: pin out of range");
  pin_mode[n] = UNTAG(mv) ? 1 : 0;
  return (V)&fpr_unit;
}
static V h_pin_write(V nv, V vv) {
  pins_init();
  sw n = UNTAG(nv);
  if (n < 0 || n >= NPINS) fpr_cpanic("Pin.write: pin out of range");
  if (!pin_mode[n]) fpr_cpanic("Pin.write: pin is not an output (Pin.mode first)");
  if (UNTAG(vv)) pin_out |= (1u << n); else pin_out &= ~(1u << n);
  if (pin_trace_n < PIN_TRACE_CAP)
    pin_trace[pin_trace_n++] = (uint16_t)(n * 2 + (UNTAG(vv) ? 1 : 0));
  return (V)&fpr_unit;
}
static V h_pin_read(V nv) {
  pins_init();
  sw n = UNTAG(nv);
  if (n < 0 || n >= NPINS) fpr_cpanic("Pin.read: pin out of range");
  if (pin_mode[n]) return TAG((pin_out >> n) & 1); /* out: read back the latch */
  if (pin_feed_n[n]) { /* pattern stimulus: one bit per read, MSB first */
    int i = pin_feed_i[n];
    if (i < pin_feed_n[n]) pin_feed_i[n] = (uint8_t)(i + 1);
    return TAG((sw)((pin_feed_pat[n] >> (pin_feed_n[n] - 1 - (i < pin_feed_n[n] ? i : pin_feed_n[n] - 1))) & 1));
  }
  int s = pin_src[n];
  return TAG(s >= 0 ? (sw)((pin_out >> s) & 1) : 0);
}
/* SIM ONLY: feed an in-pin from a bit PATTERN, advancing one bit per
 * Pin.read -- the stimulus for serial slaves (a TTP229 answering its
 * 16 clocks, an SPI slave shifting a reply).  MSB first over nbits. */
static V h_pin_feed(V bv, V patv, V nv) {
  pins_init();
  sw b = UNTAG(bv);
  if (b < 0 || b >= NPINS) fpr_cpanic("Pin.feed: pin out of range");
  pin_feed_pat[b] = (uint32_t)UNTAG(patv);
  pin_feed_n[b] = (uint8_t)UNTAG(nv);
  pin_feed_i[b] = 0;
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Pin_x2efeed, h_pin_feed, 3);

static V h_pin_wire(V av, V bv) { /* SIM ONLY: out-pin a -> in-pin b (a<0 unwires) */
  pins_init();
  sw a = UNTAG(av), b = UNTAG(bv);
  if (b < 0 || b >= NPINS) fpr_cpanic("Pin.wire: dst out of range");
  pin_src[b] = (a >= 0 && a < NPINS) ? (int8_t)a : -1;
  return (V)&fpr_unit;
}
/* signal trace: every Pin.write records (pin, value) in order -- the
 * sim's logic analyzer.  Tests decode the captured WAVEFORM back into
 * protocol bytes (see tests/bbspi.fpr), which is how "are the signals
 * generally working" is answerable without silicon. */
static V h_pin_tclear(V d) { (void)d; pin_trace_n = 0; return (V)&fpr_unit; }
static V h_pin_tlen(V d) { (void)d; return TAG((sw)pin_trace_n); }
static V h_pin_tget(V iv) { /* 1-based; -> pin*2 + value */
  sw i = UNTAG(iv);
  if (i < 1 || (uw)i > pin_trace_n) fpr_cpanic("Pin.tget: index out of range");
  return TAG((sw)pin_trace[i - 1]);
}
FPR_FN(fpr_g_Pin_x2etclear, h_pin_tclear, 1);
FPR_FN(fpr_g_Pin_x2etlen, h_pin_tlen, 1);
FPR_FN(fpr_g_Pin_x2etget, h_pin_tget, 1);

FPR_FN(fpr_g_Pin_x2emode, h_pin_mode, 2);
FPR_FN(fpr_g_Pin_x2ewrite, h_pin_write, 2);
FPR_FN(fpr_g_Pin_x2eread, h_pin_read, 1);
FPR_FN(fpr_g_Pin_x2ewire, h_pin_wire, 2);

#define VIRT_TEST_FINISHER 0x100000UL
void hal_poweroff(int code) {
  volatile uint32_t *t = (volatile uint32_t *)VIRT_TEST_FINISHER;
  *t = code ? (((uint32_t)code & 0xffffu) << 16) | 0x3333u : 0x5555u;
}

/* ---- Devices ----------------------------------------------------------
 * `device "name"` : String -> Device. Linear scan of a handful of
 * entries; a real HAL with dozens of peripherals would want a sorted
 * table + binary search, or a perfect hash generated at build time. */
static V h_device(V nameStr) {
  if (ISINT(nameStr) || TID(nameStr) != T_STR) fpr_cpanic("device: name must be a String");
  str_t *s = (str_t *)nameStr;
  for (size_t i = 0; i < NDEVICES; i++) {
    const char *n = devtable[i].name;
    size_t j = 0;
    for (; j < s->len && n[j] && n[j] == (char)s->bytes[j]; j++) {}
    if (j == s->len && n[j] == '\0') {
      if (devtable[i].setup) devtable[i].setup();
      return (V)&devtable[i].dev;
    }
  }
  fpr_cpanic("device: unknown device name");
}

/* ---- Registers ------------------------------------------------------- */
static V mkreg(V dev, V off, uint32_t width) {
  if (ISINT(dev) || TID(dev) != T_DEVICE) fpr_cpanic("reg: not a Device");
  if (!ISINT(off)) fpr_cpanic("reg: offset not an Int");
  reg_t *r = (reg_t *)fpr_alloc(sizeof(reg_t));
  r->tid = T_REGISTER;
  r->var = width;
  r->addr = ((fpr_dev_t *)dev)->base + (uw)UNTAG(off);
  return (V)r;
}
static V h_reg8(V d, V o) { return mkreg(d, o, 1); }
static V h_reg32(V d, V o) { return mkreg(d, o, 4); }

/* ---- MMIO ------------------------------------------------------------ */
static V h_read(V rv) {
  if (ISINT(rv) || TID(rv) != T_REGISTER) fpr_cpanic("read: not a Register");
  reg_t *r = (reg_t *)rv;
  __asm__ volatile("fence io, io" ::: "memory");
  uw v = (r->var == 1) ? *(volatile uint8_t *)r->addr
                             : *(volatile uint32_t *)r->addr;
  __asm__ volatile("fence io, io" ::: "memory");
  return TAG(v);
}

static V h_write(V rv, V x) {
  if (ISINT(rv) || TID(rv) != T_REGISTER) fpr_cpanic("write: not a Register");
  reg_t *r = (reg_t *)rv;
  uw v;
  if (ISINT(x)) v = (uw)UNTAG(x);
  else if (TID(x) == T_BITS) v = ((bits_t *)x)->val;
  else fpr_cpanic("write: value must be Int or Array Bit");
  __asm__ volatile("fence io, io" ::: "memory");
  if (r->var == 1) *(volatile uint8_t *)r->addr = (uint8_t)v;
  else *(volatile uint32_t *)r->addr = (uint32_t)v;
  __asm__ volatile("fence io, io" ::: "memory");
  return (V)&fpr_unit;
}

/* ---- Array Bit ------------------------------------------------------- */
/* Value canonical form is always LSB-0; endianness changes what "bit i"
 * MEANS (LE: i counts from LSB; BE: i counts from MSB within len). */
/* ---- the discoverable-symbol table ----------------------------------- */
FPR_FN(fpr_g_device, h_device, 1);
FPR_FN(fpr_g_reg8, h_reg8, 2);
FPR_FN(fpr_g_reg32, h_reg32, 2);
FPR_FN(fpr_g_read, h_read, 1);
FPR_FN(fpr_g_write, h_write, 2);

/* ---- SMP wake machinery: CLINT software interrupts + one timer -------
 * The hart loop sleeps in wfi instead of spin-polling.  Correctness of
 * the sleep depends on one CSR trick and one ordering rule:
 *
 *   TRICK: mie.MSIE|MTIE are SET but mstatus.MIE stays CLEAR.  A
 *   pending+enabled interrupt makes wfi fall through -- but with global
 *   interrupts off it is never TAKEN, so no trap vector exists in the
 *   whole system.  (This is the canonical M-mode "wfi as event wait".)
 *
 *   ORDERING: the sleeper clears its msip BEFORE its final queue check;
 *   a waker posts work BEFORE setting msip.  Any post after the clear
 *   leaves msip pending and the wfi falls straight through -- the same
 *   shape as the Dekker pairing in actors.c, with msip as the flag.
 *
 * mtimecmp resets to 0 in QEMU, i.e. MTIP PENDING from boot: every
 * hart's compare register is parked at ~0 during init or its wfi would
 * never sleep.  Hart 0 re-arms a short deadline each time it goes idle
 * (the deadlock detector's heartbeat); everyone else sleeps on msip
 * alone.  CLINT_BASE is the devtable's, defined above. */
/* On rv64 the CLINT is clint.fpr: FP-RISC over typed layouts, a raw library
 * unit whose exports are hal_ipi_send / hal_ipi_clear / hal_mtime /
 * hal_timer_park / hal_timer_arm (virt.mk, docs/LAYOUTS.md).  The raw ABI has
 * no rv32 lowering, so an rv32 image keeps this C -- which is also the only
 * place the split 64-bit register dance is needed. */
#if __riscv_xlen == 32
#define CLINT_MSIP(h) ((volatile uint32_t *)(CLINT_BASE + 4 * (uw)(h)))
#define CLINT_MTIMECMP(h) (CLINT_BASE + 0x4000 + 8 * (uw)(h))
#define CLINT_MTIME (CLINT_BASE + 0xBFF8)

void hal_ipi_send(uw hart) { *CLINT_MSIP(hart) = 1; }
void hal_ipi_clear(uw hart) { *CLINT_MSIP(hart) = 0; }

uint64_t hal_mtime(void) {
  for (;;) {
    uint32_t hi = *(volatile uint32_t *)(CLINT_MTIME + 4);
    uint32_t lo = *(volatile uint32_t *)CLINT_MTIME;
    if (hi == *(volatile uint32_t *)(CLINT_MTIME + 4))
      return ((uint64_t)hi << 32) | lo;
  }
}

static void mtimecmp_write(uw hart, uint64_t v) {
  volatile uint32_t *lo = (volatile uint32_t *)CLINT_MTIMECMP(hart);
  volatile uint32_t *hi = lo + 1;
  *lo = 0xFFFFFFFFu; /* no spurious match while the halves are split */
  *hi = (uint32_t)(v >> 32);
  *lo = (uint32_t)v;
}

void hal_timer_park(uw hart) { mtimecmp_write(hart, ~(uint64_t)0); }
void hal_timer_arm(uw hart, uint64_t delta) {
  mtimecmp_write(hart, hal_mtime() + delta);
}
#endif

/* the CLINT is real here: Timer.qa gets the interrupt-driven bridge
 * (actors.c tmr_drain) instead of sleeper-child fallbacks */
int hal_timer_native(void) { return 1; }

/* mie.MSIE (bit 3) | mie.MTIE (bit 7); mstatus.MIE stays 0 on purpose */
void hal_wfi_enable(void) {
  /* MSIE | MTIE | MEIE: external interrupts join the wfi-wake set --
   * mstatus.MIE stays OFF, so an enabled source pends (pops wfi) and
   * the hart loop services it synchronously; no trap is ever taken.
   * MEIP only ever raises on hart 0 (plic.c enables that one M
   * context), so setting MEIE everywhere is harmless. */
  __asm__ volatile("csrs mie, %0" ::"r"((uw)((1 << 3) | (1 << 7) | (1 << 11))));
}
void hal_wfi(void) { __asm__ volatile("wfi"); }
