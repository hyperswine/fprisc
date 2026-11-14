/* Benchmarks Game fasta. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE 60
#define IM 139968
#define IA 3877
#define IC 29573

static const char ALU[] =
    "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGG"
    "TCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGG"
    "GCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAG"
    "GCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";

typedef struct { char c; double p; } Entry;

static Entry iub[] = {
    {'a', 0.27}, {'c', 0.12}, {'g', 0.12}, {'t', 0.27},
    {'B', 0.02}, {'D', 0.02}, {'H', 0.02}, {'K', 0.02}, {'M', 0.02},
    {'N', 0.02}, {'R', 0.02}, {'S', 0.02}, {'V', 0.02}, {'W', 0.02}, {'Y', 0.02},
};

static Entry homosapiens[] = {
    {'a', 0.3029549426680}, {'c', 0.1979883004921},
    {'g', 0.1975473066391}, {'t', 0.3015094502008},
};

static long seed = 42;

static double next_random(void) {
    seed = (seed * IA + IC) % IM;
    return (double)seed / IM;
}

static void repeat(const char *s, long n) {
    size_t len = strlen(s);
    char line[LINE + 1];
    size_t k = 0;
    while (n > 0) {
        int m = n < LINE ? (int)n : LINE;
        for (int i = 0; i < m; i++) {
            line[i] = s[k];
            if (++k == len) k = 0;
        }
        line[m] = '\n';
        fwrite(line, 1, m + 1, stdout);
        n -= m;
    }
}

static void random_seq(Entry *t, int count, long n) {
    double cum[16];
    double acc = 0;
    for (int i = 0; i < count; i++) { acc += t[i].p; cum[i] = acc; }
    char line[LINE + 1];
    while (n > 0) {
        int m = n < LINE ? (int)n : LINE;
        for (int i = 0; i < m; i++) {
            double r = next_random();
            int j = 0;
            while (j < count - 1 && cum[j] <= r) j++;
            line[i] = t[j].c;
        }
        line[m] = '\n';
        fwrite(line, 1, m + 1, stdout);
        n -= m;
    }
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 2500000;
    fputs(">ONE Homo sapiens alu\n", stdout);
    repeat(ALU, 2 * n);
    fputs(">TWO IUB ambiguity codes\n", stdout);
    random_seq(iub, sizeof iub / sizeof iub[0], 3 * n);
    fputs(">THREE Homo sapiens frequency\n", stdout);
    random_seq(homosapiens, sizeof homosapiens / sizeof homosapiens[0], 5 * n);
    return 0;
}
