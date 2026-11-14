/* Benchmarks Game k-nucleotide: open-addressing hash table keyed by the
   k-mer packed two bits per base into a uint64 (k <= 32). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint64_t key; uint32_t count; } Slot;   /* count 0 = empty */

typedef struct {
    Slot *slots;
    size_t cap, used;   /* cap is a power of two */
} Table;

static size_t slot_of(uint64_t key, size_t cap) {
    return (size_t)((key * 0x9E3779B97F4A7C15ULL) >> 32) & (cap - 1);
}

static void table_init(Table *t, size_t cap) {
    t->cap = cap;
    t->used = 0;
    t->slots = calloc(cap, sizeof(Slot));
    if (!t->slots) { perror("calloc"); exit(1); }
}

static void table_grow(Table *t) {
    Slot *old = t->slots;
    size_t oldCap = t->cap;
    table_init(t, oldCap * 2);
    for (size_t i = 0; i < oldCap; i++) {
        if (old[i].count == 0) continue;
        size_t s = slot_of(old[i].key, t->cap);
        while (t->slots[s].count != 0) s = (s + 1) & (t->cap - 1);
        t->slots[s] = old[i];
        t->used++;
    }
    free(old);
}

static void table_add(Table *t, uint64_t key) {
    size_t s = slot_of(key, t->cap);
    for (;;) {
        Slot *sl = &t->slots[s];
        if (sl->count == 0) {
            sl->key = key;
            sl->count = 1;
            if (++t->used * 2 > t->cap) table_grow(t);
            return;
        }
        if (sl->key == key) { sl->count++; return; }
        s = (s + 1) & (t->cap - 1);
    }
}

static uint32_t table_get(const Table *t, uint64_t key) {
    size_t s = slot_of(key, t->cap);
    for (;;) {
        const Slot *sl = &t->slots[s];
        if (sl->count == 0) return 0;
        if (sl->key == key) return sl->count;
        s = (s + 1) & (t->cap - 1);
    }
}

static int code(char c) {
    switch (c) {
    case 'A': return 0;
    case 'C': return 1;
    case 'G': return 2;
    default: return 3;  /* 'T' */
    }
}

static uint64_t pack(const char *s, int k) {
    uint64_t key = 0;
    for (int i = 0; i < k; i++) key = (key << 2) | (uint64_t)code(s[i]);
    return key;
}

static void unpack(uint64_t key, int k, char *out) {
    for (int i = k - 1; i >= 0; i--) { out[i] = "ACGT"[key & 3]; key >>= 2; }
    out[k] = 0;
}

static Table count_kmers(const char *seq, size_t len, int k) {
    Table t;
    table_init(&t, 64);
    if (len < (size_t)k) return t;
    uint64_t mask = k == 32 ? ~0ULL : ((1ULL << (2 * k)) - 1);
    uint64_t key = pack(seq, k - 1);
    for (size_t i = k - 1; i < len; i++) {
        key = ((key << 2) | (uint64_t)code(seq[i])) & mask;
        table_add(&t, key);
    }
    return t;
}

static int cmp_slot(const void *a, const void *b) {
    const Slot *x = a, *y = b;
    if (x->count != y->count) return x->count > y->count ? -1 : 1;
    /* A<C<G<T in both the packing and ASCII, so packed order is string order */
    return x->key < y->key ? -1 : x->key > y->key;
}

static void frequencies(const char *seq, size_t len, int k) {
    Table t = count_kmers(seq, len, k);
    Slot *list = malloc((t.used ? t.used : 1) * sizeof(Slot));
    size_t m = 0;
    for (size_t i = 0; i < t.cap; i++)
        if (t.slots[i].count) list[m++] = t.slots[i];
    qsort(list, m, sizeof(Slot), cmp_slot);
    double total = (double)(len - k + 1);
    char buf[33];
    for (size_t i = 0; i < m; i++) {
        unpack(list[i].key, k, buf);
        printf("%s %.3f\n", buf, 100.0 * list[i].count / total);
    }
    printf("\n");
    free(list);
    free(t.slots);
}

static void count_one(const char *seq, size_t len, const char *kmer) {
    int k = (int)strlen(kmer);
    Table t = count_kmers(seq, len, k);
    printf("%u\t%s\n", table_get(&t, pack(kmer, k)), kmer);
    free(t.slots);
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "data/fasta-1000000.txt";
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return 1; }

    size_t cap = 1 << 20, len = 0;
    char *seq = malloc(cap);
    char line[4096];
    int inThree = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '>') {
            if (inThree) break;
            inThree = strncmp(line, ">THREE", 6) == 0;
            continue;
        }
        if (!inThree) continue;
        for (char *p = line; *p && *p != '\n' && *p != '\r'; p++) {
            if (len == cap) { cap *= 2; seq = realloc(seq, cap); }
            char c = *p;
            seq[len++] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
        }
    }
    fclose(f);

    frequencies(seq, len, 1);
    frequencies(seq, len, 2);
    static const char *queries[] = {
        "GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"};
    for (int i = 0; i < 5; i++) count_one(seq, len, queries[i]);
    free(seq);
    return 0;
}
