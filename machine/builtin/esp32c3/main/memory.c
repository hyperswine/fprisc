#include "machine.h"

/* Builtin's checked Addr primitives validate alignment before calling here. */
#define MEMORY(width, type) \
    uintptr_t fpr_machine_read##width(uintptr_t addr) { return *(volatile type *)addr; } \
    void fpr_machine_write##width(uintptr_t addr, uintptr_t value) { *(volatile type *)addr = (type)value; }

MEMORY(8, uint8_t)
MEMORY(16, uint16_t)
MEMORY(32, uint32_t)
MEMORY(Word, uintptr_t)
