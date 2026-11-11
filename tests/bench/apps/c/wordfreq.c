/* wordfreq: word counts, top 10 (SPEC.md) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef struct {
    const char *word;   /* points into the input buffer */
    size_t len;
    int64_t count;
} Entry;

static Entry *table;
static size_t cap, used;

static uint64_t hash(const char *s, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= (unsigned char)s[i]; h *= 1099511628211ULL; }
    return h;
}

static void grow(void) {
    size_t oldcap = cap; Entry *old = table;
    cap = cap ? cap * 2 : 1024;
    table = calloc(cap, sizeof(Entry));
    for (size_t j = 0; j < oldcap; j++) {
        if (!old[j].word) continue;
        size_t i = hash(old[j].word, old[j].len) & (cap - 1);
        while (table[i].word) i = (i + 1) & (cap - 1);
        table[i] = old[j];
    }
    free(old);
}

static void bump(const char *s, size_t n) {
    if ((used + 1) * 2 > cap) grow();
    size_t i = hash(s, n) & (cap - 1);
    for (;;) {
        Entry *e = &table[i];
        if (!e->word) { e->word = s; e->len = n; e->count = 1; used++; return; }
        if (e->len == n && memcmp(e->word, s, n) == 0) { e->count++; return; }
        i = (i + 1) & (cap - 1);
    }
}

static int cmp(const void *a, const void *b) {
    const Entry *x = a, *y = b;
    if (x->count != y->count) return x->count > y->count ? -1 : 1;
    size_t m = x->len < y->len ? x->len : y->len;
    int c = memcmp(x->word, y->word, m);
    if (c) return c;
    return x->len < y->len ? -1 : x->len > y->len ? 1 : 0;
}

static int is_space(char c) { return c == ' ' || c == '\n' || c == '\t' || c == '\r'; }

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "data/corpus.txt";
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }
    fseek(f, 0, SEEK_END); long size = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = malloc(size + 1);
    if (fread(buf, 1, size, f) != (size_t)size) { perror("fread"); return 1; }
    fclose(f);
    grow();

    int64_t total = 0;
    long i = 0;
    while (i < size) {
        while (i < size && is_space(buf[i])) i++;
        if (i >= size) break;
        long start = i;
        while (i < size && !is_space(buf[i])) i++;
        bump(buf + start, i - start);
        total++;
    }

    Entry *list = malloc(used * sizeof(Entry));
    size_t n = 0;
    for (size_t j = 0; j < cap; j++) if (table[j].word) list[n++] = table[j];
    qsort(list, n, sizeof(Entry), cmp);
    printf("distinct %zu total %lld\n", n, (long long)total);
    for (size_t j = 0; j < n && j < 10; j++)
        printf("%.*s %lld\n", (int)list[j].len, list[j].word, (long long)list[j].count);
    return 0;
}
