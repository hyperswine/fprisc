/* treemap: map inserts and lookups (SPEC.md); C has no ordered map, so an
   open-addressing hash map plus a sort of the keys for the key hash. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define M 1000000007LL

typedef struct { int64_t key, value; int used; } Slot;

static Slot *table;
static size_t cap, used;

static int64_t lcg(int64_t x) { return (x * 1103515245 + 12345) % 2147483648LL; }

static size_t slot_of(int64_t k) {
    uint64_t h = (uint64_t)k * 0x9E3779B97F4A7C15ULL;
    return (size_t)(h >> 32) & (cap - 1);
}

static void grow(void) {
    size_t oldcap = cap; Slot *old = table;
    cap = cap ? cap * 2 : 1024;
    table = calloc(cap, sizeof(Slot));
    for (size_t j = 0; j < oldcap; j++) {
        if (!old[j].used) continue;
        size_t i = slot_of(old[j].key);
        while (table[i].used) i = (i + 1) & (cap - 1);
        table[i] = old[j];
    }
    free(old);
}

static void put(int64_t k, int64_t v) {
    if ((used + 1) * 2 > cap) grow();
    size_t i = slot_of(k);
    while (table[i].used) {
        if (table[i].key == k) { table[i].value = v; return; }
        i = (i + 1) & (cap - 1);
    }
    table[i].used = 1; table[i].key = k; table[i].value = v; used++;
}

static Slot *get(int64_t k) {
    size_t i = slot_of(k);
    while (table[i].used) {
        if (table[i].key == k) return &table[i];
        i = (i + 1) & (cap - 1);
    }
    return NULL;
}

static int cmp(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : x > y;
}

int main(void) {
    grow();
    int64_t x = 7;
    for (int64_t i = 0; i < 500000; i++) { x = lcg(x); put(x % 1000000, i); }
    int64_t hits = 0, sum = 0;
    for (int64_t i = 0; i < 500000; i++) {
        x = lcg(x);
        Slot *s = get(x % 1000000);
        if (s) { hits++; sum += s->value; }
    }
    int64_t *keys = malloc(used * sizeof(int64_t));
    size_t n = 0;
    for (size_t j = 0; j < cap; j++) if (table[j].used) keys[n++] = table[j].key;
    qsort(keys, n, sizeof(int64_t), cmp);
    int64_t k = 0;
    for (size_t j = 0; j < n; j++) k = (k * 31 + keys[j]) % M;
    printf("size %zu hits %lld sum %lld keyhash %lld\n", n, (long long)hits, (long long)sum, (long long)k);
    return 0;
}
