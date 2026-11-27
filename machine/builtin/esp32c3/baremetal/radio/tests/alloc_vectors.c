#include "alloc.h"
#include <assert.h>
#include <stdint.h>

int main(void) {
    assert(c3_radio_alloc(0) == 0 && c3_radio_alloc(SIZE_MAX) == 0);
    void *a = c3_radio_alloc(17);
    void *b = c3_radio_alloc(32);
    void *c = c3_radio_alloc(16);
    assert(a && b && c && !((uintptr_t)a & 15));
    assert(c3_radio_allocated() == 80 && c3_radio_peak() == 80);
    c3_radio_free(b);
    c3_radio_free(a);
    a = c3_radio_alloc(64);
    assert(a && c3_radio_allocated() == 96 && c3_radio_peak() == 96);
    c3_radio_free(c);
    c3_radio_free(a);
    void *all = c3_radio_alloc(24 * 1024 - 16);
    assert(all && c3_radio_alloc(1) == 0);
    c3_radio_free(all);
    assert(c3_radio_allocated() == 0);
}
