#include "os_value.h"
/* Strong optional engine definitions override these explicit refusals. */
static V absent_start(V a0,V a1,V a2,V a3,V a4){(void)a0;(void)a1;(void)a2;(void)a3;(void)a4;return os_err("native TLS backend unavailable");}
__attribute__((weak)) const pap0_t fpr_g_TlsHost_x2estart = {T_PAP,0,(uw)(uintptr_t)absent_start,5,0};
__attribute__((weak)) V fpr_g_TlsHost_x2estart_call5(V a0,V a1,V a2,V a3,V a4){return absent_start(a0,a1,a2,a3,a4);}
static V absent_fd(V a0){(void)a0;return os_err("native TLS backend unavailable");}
__attribute__((weak)) const pap0_t fpr_g_TlsHost_x2efd = {T_PAP,0,(uw)(uintptr_t)absent_fd,1,0};
__attribute__((weak)) V fpr_g_TlsHost_x2efd_call1(V a0){return absent_fd(a0);}
static V absent_step(V a0,V a1,V a2,V a3){(void)a0;(void)a1;(void)a2;(void)a3;return os_err("native TLS backend unavailable");}
__attribute__((weak)) const pap0_t fpr_g_TlsHost_x2estep = {T_PAP,0,(uw)(uintptr_t)absent_step,4,0};
__attribute__((weak)) V fpr_g_TlsHost_x2estep_call4(V a0,V a1,V a2,V a3){return absent_step(a0,a1,a2,a3);}
static V absent_pending(V a0){(void)a0;return os_err("native TLS backend unavailable");}
__attribute__((weak)) const pap0_t fpr_g_TlsHost_x2epending = {T_PAP,0,(uw)(uintptr_t)absent_pending,1,0};
__attribute__((weak)) V fpr_g_TlsHost_x2epending_call1(V a0){return absent_pending(a0);}
static V absent_close(V a0){(void)a0;return os_err("native TLS backend unavailable");}
__attribute__((weak)) const pap0_t fpr_g_TlsHost_x2eclose = {T_PAP,0,(uw)(uintptr_t)absent_close,1,0};
__attribute__((weak)) V fpr_g_TlsHost_x2eclose_call1(V a0){return absent_close(a0);}
