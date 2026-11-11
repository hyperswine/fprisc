/* records: three-key sort and group-by (SPEC.md) */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define N 1000000
#define M 1000000007LL

typedef struct { int64_t id, dept, age, salary; } Record;

static int64_t lcg(int64_t x) { return (x * 1103515245 + 12345) % 2147483648LL; }

static int cmp(const void *a, const void *b) {
    const Record *x = a, *y = b;
    if (x->dept != y->dept) return x->dept < y->dept ? -1 : 1;
    if (x->age != y->age) return x->age > y->age ? -1 : 1;
    if (x->id != y->id) return x->id < y->id ? -1 : 1;
    return 0;
}

int main(void) {
    Record *rs = malloc(N * sizeof(Record));
    int64_t x = 42;
    for (int64_t id = 0; id < N; id++) {
        x = lcg(x);
        rs[id].id = id;
        rs[id].dept = x % 100;
        rs[id].age = 18 + (x / 100) % 63;
        rs[id].salary = 30000 + (x / 6300) % 90000;
    }
    qsort(rs, N, sizeof(Record), cmp);
    int64_t o = 0;
    for (int64_t i = 0; i < N; i++) o = (o * 31 + rs[i].id) % M;
    printf("records %d order %lld\n", N, (long long)o);
    int64_t i = 0;
    while (i < N) {
        int64_t dept = rs[i].dept, first = rs[i].id, count = 0, sum = 0;
        while (i < N && rs[i].dept == dept) { count++; sum += rs[i].salary; i++; }
        printf("%lld %lld %lld %lld\n", (long long)dept, (long long)count, (long long)sum, (long long)first);
    }
    return 0;
}
