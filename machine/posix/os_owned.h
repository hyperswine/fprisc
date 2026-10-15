#ifndef FPR_OS_OWNED_H
#define FPR_OS_OWNED_H
#include "os_value.h"
#include <pthread.h>
enum { OWN_SOCKET = 1, OWN_TLS, OWN_DNS_POOL, OWN_DNS_JOB, OWN_CRYPTO };
typedef struct fpr_owned {
  fpr_resource_t resource;
  struct fpr_owned *next;
  uw id;
  void *owner;
  int kind, fd;
  void *data;
  void (*destroy)(void *, int);
} fpr_owned_t;
/* lock returns with the registry mutex held. Never allocate FP-RISC values
 * while held. shared=1 permits a shared pool lookup; close/take stay owned. */
fpr_owned_t *fpr_owned_lock(V id, int kind, int shared, const char **why);
void fpr_owned_unlock(void);
uw fpr_owned_add(int kind, int fd, void *data, void (*destroy)(void *, int));
int fpr_owned_take(V id, int kind, int *fd, void **data, const char **why);
int fpr_owned_close(V id, int kind, const char **why);
#endif
