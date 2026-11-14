/* Benchmarks Game reverse-complement. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char comp[256];

static void init_comp(void) {
    static const char *from = "ACGTUMRWSYKVHDBN";
    static const char *to   = "TGCAAKYWSRMBDHVN";
    for (int i = 0; i < 256; i++) comp[i] = (unsigned char)i;
    for (int i = 0; from[i]; i++) {
        comp[(unsigned char)from[i]] = (unsigned char)to[i];
        comp[(unsigned char)(from[i] + 32)] = (unsigned char)to[i];
    }
}

static void flush_seq(char *seq, size_t len) {
    char line[61];
    size_t i = len;
    while (i > 0) {
        int m = 0;
        while (m < 60 && i > 0) line[m++] = (char)comp[(unsigned char)seq[--i]];
        line[m++] = '\n';
        fwrite(line, 1, m, stdout);
    }
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "data/fasta-2500000.txt";
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return 1; }
    init_comp();

    size_t cap = 1 << 20, len = 0;
    char *seq = malloc(cap);
    char *line = NULL;
    size_t lineCap = 0;
    ssize_t n;
    while ((n = getline(&line, &lineCap, f)) > 0) {
        if (line[0] == '>') {
            flush_seq(seq, len);
            len = 0;
            fwrite(line, 1, (size_t)n, stdout);
            if (line[n - 1] != '\n') fputc('\n', stdout);
            continue;
        }
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) n--;
        if (len + (size_t)n > cap) {
            while (len + (size_t)n > cap) cap *= 2;
            seq = realloc(seq, cap);
        }
        memcpy(seq + len, line, (size_t)n);
        len += (size_t)n;
    }
    flush_seq(seq, len);
    fclose(f);
    free(line);
    free(seq);
    return 0;
}
