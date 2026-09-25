/* Cross-file hooks used by the hosted HAL and its Unix implementation. */
#ifndef FPR_POSIX_HOST_H
#define FPR_POSIX_HOST_H
#include "fpr.h"
void hal_ipi_send(uw hart); /* park.c: wake the selected hart */
void hal_fault_init(void); /* host.c: signal handler and per-thread stack */
#endif
