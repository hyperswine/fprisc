/* sim: particle simulation (SPEC.md) */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define NP 20000
#define STEPS 2000

typedef struct { int64_t px, py, vx, vy; } Particle;

static int64_t lcg(int64_t x) { return (x * 1103515245 + 12345) % 2147483648LL; }

int main(void) {
    Particle *ps = malloc(NP * sizeof(Particle));
    int64_t x = 1;
    for (int i = 0; i < NP; i++) {
        x = lcg(x); ps[i].px = x % 1000000;
        x = lcg(x); ps[i].py = x % 1000000;
        x = lcg(x); ps[i].vx = x % 2001 - 1000;
        x = lcg(x); ps[i].vy = x % 2001 - 1000;
    }
    for (int s = 0; s < STEPS; s++) {
        for (int i = 0; i < NP; i++) {
            Particle *p = &ps[i];
            p->vy -= 1;
            p->px += p->vx;
            if (p->px < 0) { p->px = -p->px; p->vx = -p->vx; }
            else if (p->px > 1000000) { p->px = 2000000 - p->px; p->vx = -p->vx; }
            p->py += p->vy;
            if (p->py < 0) { p->py = -p->py; p->vy = -p->vy; }
            else if (p->py > 1000000) { p->py = 2000000 - p->py; p->vy = -p->vy; }
        }
    }
    int64_t sx = 0, sy = 0, e = 0;
    for (int i = 0; i < NP; i++) {
        sx += ps[i].px; sy += ps[i].py;
        e += ps[i].vx * ps[i].vx + ps[i].vy * ps[i].vy;
    }
    printf("particles %d steps %d sx %lld sy %lld energy %lld\n", NP, STEPS,
           (long long)sx, (long long)sy, (long long)e);
    return 0;
}
