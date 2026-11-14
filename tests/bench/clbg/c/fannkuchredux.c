/* Benchmarks Game fannkuch-redux, single-threaded. */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 10;
    int *perm1 = malloc(n * sizeof(int));
    int *perm = malloc(n * sizeof(int));
    int *count = malloc(n * sizeof(int));
    for (int i = 0; i < n; i++) { perm1[i] = i; count[i] = 0; }

    int maxFlips = 0, checksum = 0, permIndex = 0, r = n;
    for (;;) {
        while (r != 1) { count[r - 1] = r; r--; }
        for (int i = 0; i < n; i++) perm[i] = perm1[i];
        int flips = 0, k = perm[0];
        while (k != 0) {
            for (int i = 0, j = k; i < j; i++, j--) {
                int t = perm[i]; perm[i] = perm[j]; perm[j] = t;
            }
            flips++;
            k = perm[0];
        }
        if (flips > maxFlips) maxFlips = flips;
        checksum += (permIndex % 2 == 0) ? flips : -flips;

        for (;;) {
            if (r == n) {
                printf("%d\nPfannkuchen(%d) = %d\n", checksum, n, maxFlips);
                free(perm1); free(perm); free(count);
                return 0;
            }
            int p0 = perm1[0];
            for (int i = 0; i < r; i++) perm1[i] = perm1[i + 1];
            perm1[r] = p0;
            count[r]--;
            if (count[r] > 0) break;
            r++;
        }
        permIndex++;
    }
}
