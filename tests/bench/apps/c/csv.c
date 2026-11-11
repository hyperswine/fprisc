/* csv: parse and aggregate (SPEC.md) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef struct {
    char *key;      /* NUL-terminated copy */
    size_t len;
    int64_t count, suma, maxb;
} Entry;

static Entry *table;
static size_t cap, used;

static uint64_t hash(const char *s, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= (unsigned char)s[i]; h *= 1099511628211ULL; }
    return h;
}

static void grow(void);

static Entry *lookup(const char *s, size_t n) {
    if ((used + 1) * 2 > cap) grow();
    size_t i = hash(s, n) & (cap - 1);
    for (;;) {
        Entry *e = &table[i];
        if (!e->key) {
            e->key = malloc(n + 1);
            memcpy(e->key, s, n); e->key[n] = 0;
            e->len = n; e->count = 0; e->suma = 0; e->maxb = 0;
            used++;
            return e;
        }
        if (e->len == n && memcmp(e->key, s, n) == 0) return e;
        i = (i + 1) & (cap - 1);
    }
}

static void grow(void) {
    size_t oldcap = cap; Entry *old = table;
    cap = cap ? cap * 2 : 1024;
    table = calloc(cap, sizeof(Entry));
    for (size_t j = 0; j < oldcap; j++) {
        if (!old[j].key) continue;
        size_t i = hash(old[j].key, old[j].len) & (cap - 1);
        while (table[i].key) i = (i + 1) & (cap - 1);
        table[i] = old[j];
    }
    free(old);
}

static int cmp(const void *a, const void *b) {
    const Entry *x = *(const Entry *const *)a, *y = *(const Entry *const *)b;
    if (x->suma != y->suma) return x->suma > y->suma ? -1 : 1;
    return strcmp(x->key, y->key);
}

static int64_t parse_int(const char *s, const char *end) {
    int64_t v = 0;
    for (; s < end; s++) v = v * 10 + (*s - '0');
    return v;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "data/sales.csv";
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }
    fseek(f, 0, SEEK_END); long size = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = malloc(size + 1);
    if (fread(buf, 1, size, f) != (size_t)size) { perror("fread"); return 1; }
    fclose(f);
    buf[size] = 0;
    grow();

    int64_t lines = 0;
    char *p = buf, *end = buf + size;
    while (p < end) {
        char *nl = memchr(p, '\n', end - p);
        if (!nl) nl = end;
        if (nl > p) {
            char *c1 = memchr(p, ',', nl - p);
            char *c2 = memchr(c1 + 1, ',', nl - c1 - 1);
            int64_t a = parse_int(c1 + 1, c2);
            int64_t b = parse_int(c2 + 1, nl);
            Entry *e = lookup(p, c1 - p);
            e->count++; e->suma += a;
            if (b > e->maxb) e->maxb = b;
            lines++;
        }
        p = nl + 1;
    }

    Entry **list = malloc(used * sizeof(Entry *));
    size_t n = 0;
    for (size_t i = 0; i < cap; i++) if (table[i].key) list[n++] = &table[i];
    qsort(list, n, sizeof(Entry *), cmp);
    printf("keys %zu lines %lld\n", n, (long long)lines);
    for (size_t i = 0; i < n && i < 10; i++)
        printf("%s %lld %lld %lld\n", list[i]->key, (long long)list[i]->count,
               (long long)list[i]->suma, (long long)list[i]->maxb);
    return 0;
}
