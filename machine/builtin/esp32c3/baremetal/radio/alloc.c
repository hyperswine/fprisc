#include "alloc.h"
#include <stdbool.h>
#include <stdint.h>

#ifndef C3_RADIO_ARENA_BYTES
#define C3_RADIO_ARENA_BYTES (24 * 1024)
#endif

enum { ALIGNMENT = 16, ARENA_BYTES = C3_RADIO_ARENA_BYTES };
_Static_assert(ARENA_BYTES >= 32 && ARENA_BYTES % ALIGNMENT == 0,
               "Radio allocation arena alignment");

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

void *c3_radio_calloc(size_t count, size_t bytes) {
    if (!bytes || count > SIZE_MAX / bytes) return NULL;
    size_t size = count * bytes;
    uint8_t *ptr = c3_radio_alloc(size);
    if (ptr) for (size_t i = 0; i < size; ++i) ptr[i] = 0;
    return ptr;
}

void *c3_radio_realloc(void *ptr, size_t bytes) {
    if (!ptr) return c3_radio_alloc(bytes);
    if (!bytes) {
        c3_radio_free(ptr);
        return NULL;
    }
    for (size_t offset = 0; initialized && offset < ARENA_BYTES;) {
        const block *b = at(offset);
        if (b->used && arena + offset + ALIGNMENT == ptr) {
            if (b->bytes >= bytes) return ptr;
            uint8_t *replacement = c3_radio_alloc(bytes);
            if (!replacement) return NULL;
            for (size_t i = 0; i < b->bytes; ++i) replacement[i] = ((const uint8_t *)ptr)[i];
            c3_radio_free(ptr);
            return replacement;
        }
        offset += ALIGNMENT + b->bytes;
    }
    __builtin_trap();
}

size_t c3_radio_available(void) {
    if (!initialized) return ARENA_BYTES - ALIGNMENT;
    size_t available = 0;
    for (size_t offset = 0; offset < ARENA_BYTES;) {
        const block *b = at(offset);
        if (!b->used) available += b->bytes;
        offset += ALIGNMENT + b->bytes;
    }
    return available;
}
