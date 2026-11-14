/* Benchmarks Game binarytrees: one malloc and one free per node. */
#include <stdio.h>
#include <stdlib.h>

typedef struct Node {
    struct Node *left, *right;
} Node;

static Node *make(int d) {
    Node *n = malloc(sizeof *n);
    if (!n) { perror("malloc"); exit(1); }
    if (d > 0) {
        n->left = make(d - 1);
        n->right = make(d - 1);
    } else {
        n->left = n->right = NULL;
    }
    return n;
}

static long check(const Node *t) {
    if (!t) return 0;
    return 1 + check(t->left) + check(t->right);
}

static void release(Node *t) {
    if (!t) return;
    release(t->left);
    release(t->right);
    free(t);
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 18;
    int minDepth = 4;
    int maxDepth = n > minDepth + 2 ? n : minDepth + 2;
    int stretch = maxDepth + 1;

    Node *t = make(stretch);
    printf("stretch tree of depth %d\t check: %ld\n", stretch, check(t));
    release(t);

    Node *longLived = make(maxDepth);
    for (int d = minDepth; d <= maxDepth; d += 2) {
        long iters = 1L << (maxDepth - d + minDepth);
        long sum = 0;
        for (long i = 0; i < iters; i++) {
            Node *x = make(d);
            sum += check(x);
            release(x);
        }
        printf("%ld\t trees of depth %d\t check: %ld\n", iters, d, sum);
    }
    printf("long lived tree of depth %d\t check: %ld\n", maxDepth, check(longLived));
    release(longLived);
    return 0;
}
