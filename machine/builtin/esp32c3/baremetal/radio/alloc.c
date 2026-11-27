#include "alloc.h"
#include <stdbool.h>
#include <stdint.h>

enum { ALIGNMENT = 16, ARENA_BYTES = 24 * 1024 };

typedef struct __attribute__((may_alias)) {
    size_t bytes;
    bool used;
} block;

_Static_assert(sizeof(block) <= ALIGNMENT, "Radio allocation header");
static _Alignas(ALIGNMENT) uint8_t arena[ARENA_BYTES];
static size_t allocated, peak;
static bool initialized;

static block *at(size_t offset) {
    return (block *)(void *)(arena + offset);
}

void *c3_radio_alloc(size_t bytes) {
    if (!bytes || bytes > ARENA_BYTES - ALIGNMENT) return NULL;
    bytes = (bytes + ALIGNMENT - 1) & ~(size_t)(ALIGNMENT - 1);
    if (!initialized) {
        at(0)->bytes = ARENA_BYTES - ALIGNMENT;
        initialized = true;
    }
    for (size_t offset = 0; offset < ARENA_BYTES;) {
        block *b = at(offset);
        if (!b->used && b->bytes >= bytes) {
            if (b->bytes - bytes >= 2 * ALIGNMENT) {
                block *tail = at(offset + ALIGNMENT + bytes);
                tail->bytes = b->bytes - bytes - ALIGNMENT;
                tail->used = false;
                b->bytes = bytes;
            }
            b->used = true;
            allocated += b->bytes;
            if (allocated > peak) peak = allocated;
            return arena + offset + ALIGNMENT;
        }
        offset += ALIGNMENT + b->bytes;
    }
    return NULL;
}

void c3_radio_free(void *ptr) {
    if (!ptr) return;
    for (size_t offset = 0, previous = ARENA_BYTES; initialized && offset < ARENA_BYTES;) {
        block *b = at(offset);
        size_t next = offset + ALIGNMENT + b->bytes;
        if (b->used && arena + offset + ALIGNMENT == ptr) {
            b->used = false;
            allocated -= b->bytes;
            if (next < ARENA_BYTES && !at(next)->used)
                b->bytes += ALIGNMENT + at(next)->bytes;
            if (previous < ARENA_BYTES && !at(previous)->used)
                at(previous)->bytes += ALIGNMENT + b->bytes;
            return;
        }
        previous = offset;
        offset = next;
    }
    __builtin_trap();
}

size_t c3_radio_allocated(void) { return allocated; }
size_t c3_radio_peak(void) { return peak; }
