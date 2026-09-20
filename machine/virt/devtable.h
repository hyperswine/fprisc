/* devtable.h -- `device "name"`: the board's devices, and a HAL's.
 *
 * hal.c knows the two devices the runtime stands on (uart, clint).  A HAL
 * built above this machine layer -- QOS Native -- knows the rest, and says
 * so by DEFINING hal_devtable_ext; the default is weak and empty.  No
 * registry and no capacity: the extension is the HAL's own static table. */
#ifndef FPR_DEVTABLE_H
#define FPR_DEVTABLE_H
#include "fpr.h"

typedef struct {
  const char *name;
  fpr_dev_t dev;
  void (*setup)(void);     /* optional: one-time device init, or NULL */
  V (*ioctl)(V op, V arg); /* optional: device-specific escape hatch, or NULL */
} devtable_entry_t;

const devtable_entry_t *hal_devtable_ext(uw *count);

#endif
