/* devtable.h -- `device "name"`: the board's devices, and a HAL's.
 *
 * hal.c knows the two devices the runtime stands on (uart, clint).  A HAL
 * built above this machine layer -- QOS Native -- knows the rest, and says
 * so by DEFINING hal_devtable_ext; the default is weak and empty.  No
 * registry and no capacity: the extension is the HAL's own static table.
 *
 * Device classes (2026-11-18, QOS docs/2026-11-18-DEVICE-CLASSES.md): an
 * entry may also name its CLASS, an OPS table for that class and the driver
 * STATE the ops take, so one generic primitive per class operation serves
 * every driver of the class.  `device "name"` still returns &entry->dev, and
 * devtable_entry_of turns that Device back into its entry.  Entries written
 * before the class fields existed leave them zero: class FPR_DEV_NONE. */
#ifndef FPR_DEVTABLE_H
#define FPR_DEVTABLE_H
#include <stddef.h>
#include "fpr.h"

/* Class ids shared by every machine layer and HAL. A class's contract (its
 * ops struct and the behaviour the ops must keep) lives with the HAL that
 * declares it (QOS hal/classes/). */
enum {
  FPR_DEV_NONE = 0,
  FPR_DEV_SERIAL = 1,    /* a byte stream device (UART) */
  FPR_DEV_TIMER = 2,     /* CLINT-style timebase */
  FPR_DEV_BLOCK = 3,     /* 4 KiB pages */
  FPR_DEV_CONSOLE = 4,   /* text in and out for a user */
  FPR_DEV_INPUT = 5,     /* key and pointer events */
  FPR_DEV_DISPLAY = 6,   /* a framebuffer */
  FPR_DEV_CLOCK = 7,     /* wall-clock time */
  FPR_DEV_HOSTFS = 8,    /* files on a development host */
  FPR_DEV_AUDIO = 9,     /* sound out */
  FPR_DEV_NET = 10,
  FPR_DEV_TRANSPORT = 11 /* a link that carries other devices (QOS qlink) */
};

typedef struct {
  const char *name;
  fpr_dev_t dev;
  void (*setup)(void);     /* optional: one-time device init, or NULL */
  V (*ioctl)(V op, V arg); /* optional: device-specific escape hatch, or NULL */
  /* ---- class fields (zero in entries that predate them) ---------------- */
  uint16_t cls;            /* FPR_DEV_* */
  uint16_t irq;            /* interrupt source, 0 = none */
  const void *ops;         /* the class's ops struct, or NULL */
  void *state;             /* the driver's state, passed to every op */
  void (*irq_top)(void *state); /* optional: drain the device in trap context
                                 * before the IRQ is posted to its actor */
} devtable_entry_t;

const devtable_entry_t *hal_devtable_ext(uw *count);

/* The entry a Device value came from (every Device is &entry->dev). */
static inline const devtable_entry_t *devtable_entry_of(V d) {
  return (const devtable_entry_t *)((const char *)d - offsetof(devtable_entry_t, dev));
}

/* The idx-th entry of class cls across the machine's table and the HAL's,
 * or NULL. */
const devtable_entry_t *hal_dev_by_class(uint16_t cls, uw idx);

#endif
