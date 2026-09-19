/* devices.c (posix) -- the device tier a host can honestly offer.
 *
 * Discovery is virt's table-by-name contract, so a program written
 * against `device "uart"` / `device "clint"` runs unchanged: the uart is
 * a 16550 register model over stdio (THR writes, LSR polling, RBR
 * reads), the clint's mtime is hal_mtime.  Registers carry the same
 * reg_t values as virt at pseudo addresses; a read or write outside the
 * modelled offsets panics by name.  The pin bus is absent hardware with
 * present symbols: a program that links Pin.* and never calls it costs
 * nothing, one that calls it gets the honest panic.  Programs that
 * reference capabilities with no stub at all (blk, net) fail at LINK
 * time on the fpr_g_ name -- the image's imports are its capability
 * manifest. */
#include "fpr.h"
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define UART_BASE 0x10000000ul
#define CLINT_BASE 0x2000000ul

typedef struct { const char *name; fpr_dev_t dev; } devtable_entry_t;
static devtable_entry_t devtable[] = {
  {"uart", {T_DEVICE, 0, UART_BASE}},
  {"clint", {T_DEVICE, 0, CLINT_BASE}},
};
#define NDEVICES (sizeof(devtable) / sizeof(devtable[0]))

static V h_device(V nameStr) {
  if (ISINT(nameStr) || TID(nameStr) != T_STR) fpr_cpanic("device: name must be a String");
  str_t *s = (str_t *)nameStr;
  for (size_t i = 0; i < NDEVICES; i++) {
    const char *n = devtable[i].name;
    size_t j = 0;
    for (; j < s->len && n[j] && n[j] == (char)s->bytes[j]; j++) {}
    if (j == s->len && n[j] == '\0') return (V)&devtable[i].dev;
  }
  fpr_cpanic("device: unknown device name (the posix HAL grants: uart clint)");
  return 0;
}
FPR_FN(fpr_g_device, h_device, 1);

static int stdin_ready(void) {
  struct pollfd p = {0, POLLIN, 0};
  return poll(&p, 1, 0) > 0;
}

/* the 16550's eight bytes: THR/RBR at 0 are the console, LSR at 5 is
 * computed, the rest (IER, FCR/IIR, LCR, MCR, MSR, SCR) are a register
 * file that reads back what was written */
static uint8_t uart_regs[8];

static uw mmio_read(uw addr) {
  if (addr == UART_BASE + 5) return 0x60u | (stdin_ready() ? 1u : 0u); /* LSR: THR empty, DR */
  if (addr == UART_BASE + 0) { int c = getchar(); return c < 0 ? 0 : (uw)c; } /* RBR */
  if (addr >= UART_BASE && addr < UART_BASE + 8) return uart_regs[addr - UART_BASE];
  if (addr == CLINT_BASE + 0xBFF8) return (uw)hal_mtime();
  fpr_cpanic("read: register not modelled by the posix HAL (uart 0..7, clint mtime)");
  return 0;
}

static void mmio_write(uw addr, uw v) {
  if (addr == UART_BASE + 0) { hal_putc((char)v); return; } /* THR */
  if (addr >= UART_BASE && addr < UART_BASE + 8) { uart_regs[addr - UART_BASE] = (uint8_t)v; return; }
  fpr_cpanic("write: register not modelled by the posix HAL (uart 0..7)");
}

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
static V h_read(V rv) {
  if (ISINT(rv) || TID(rv) != T_REGISTER) fpr_cpanic("read: not a Register");
  return TAG((sw)mmio_read(((reg_t *)rv)->addr));
}
static V h_write(V rv, V x) {
  if (ISINT(rv) || TID(rv) != T_REGISTER) fpr_cpanic("write: not a Register");
  uw v;
  if (ISINT(x)) v = (uw)UNTAG(x);
  else if (TID(x) == T_BITS) v = ((bits_t *)x)->val;
  else fpr_cpanic("write: value must be Int or Array Bit");
  mmio_write(((reg_t *)rv)->addr, v);
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_reg8, h_reg8, 2);
FPR_FN(fpr_g_reg32, h_reg32, 2);
FPR_FN(fpr_g_read, h_read, 1);
FPR_FN(fpr_g_write, h_write, 2);

static V h_pin_mode(V n, V m) { (void)n; (void)m; fpr_cpanic("Pin.mode: no pin bus on the posix HAL"); return (V)&fpr_unit; }
static V h_pin_write(V n, V v) { (void)n; (void)v; fpr_cpanic("Pin.write: no pin bus on the posix HAL"); return (V)&fpr_unit; }
static V h_pin_read(V n) { (void)n; fpr_cpanic("Pin.read: no pin bus on the posix HAL"); return (V)&fpr_unit; }
static V h_pin_wire(V n, V f) { (void)n; (void)f; fpr_cpanic("Pin.wire: no pin bus on the posix HAL"); return (V)&fpr_unit; }
FPR_FN(fpr_g_Pin_x2emode, h_pin_mode, 2);
FPR_FN(fpr_g_Pin_x2ewrite, h_pin_write, 2);
FPR_FN(fpr_g_Pin_x2eread, h_pin_read, 1);
FPR_FN(fpr_g_Pin_x2ewire, h_pin_wire, 2);
