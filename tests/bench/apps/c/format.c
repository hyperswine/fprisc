/* format: string building (SPEC.md) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define N 1000000
#define M 1000000007LL

int main(void) {
    static const char *status[3] = {"open", "paid", "shipped"};
    char **lines = malloc(N * sizeof(char *));
    char tmp[128];
    for (int64_t i = 0; i < N; i++) {
        int64_t c = (i * 7919) % 10007;
        int64_t q = i % 17 + 1;
        int64_t cents = (i * 104729) % 1000000;
        int n = snprintf(tmp, sizeof tmp, "order %lld cust c%lld qty %lld total %lld.%02lld status %s",
                         (long long)i, (long long)c, (long long)q,
                         (long long)(cents / 100), (long long)(cents % 100), status[i % 3]);
        lines[i] = malloc(n + 1);
        memcpy(lines[i], tmp, n + 1);
    }
    int64_t bytes = 0, h = 0;
    for (int64_t i = 0; i < N; i++) {
        int64_t len = (int64_t)strlen(lines[i]);
        bytes += len;
        h = (h * 31 + len) % M;
    }
    printf("lines %d bytes %lld hash %lld\n", N, (long long)bytes, (long long)h);
    printf("%s\n%s\n%s\n", lines[0], lines[499999], lines[999999]);
    return 0;
}
