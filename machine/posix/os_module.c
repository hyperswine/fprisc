/* Trusted host modules share the executable's runtime. Never dlclose an
 * adopted image: function values may outlive its registry entry. */
#include "fpr.h"
#include <dlfcn.h>
#include <string.h>
extern int fpr_mod_attach(const uw *);
extern int fpr_mod_registered(const uw *);
#ifndef FPR_POSIX_CODEGEN_REV
#error host build must provide its compiler codegen revision
#endif
static V attach(V pathv) {
  if (ISINT(pathv) || TID(pathv) != T_STR) fpr_cpanic("Native.attach: path must be a String");
  const str_t *p = (const str_t *)pathv;
  if (!p->len || memchr(p->bytes, 0, p->len)) return fpr_mkresult(1, "module path is empty or contains NUL");
  char *path = (char *)fpr_alloc(p->len + 1);
  memcpy(path, p->bytes, p->len); path[p->len] = 0;
  void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!handle) return fpr_mkresult(1, dlerror());
  const uw *abi = dlsym(handle, "fpr_posix_module_nativeabi");
  const uw *rev = dlsym(handle, "fpr_posix_module_codegen");
  const uw *table = dlsym(handle, "fpr_modtab");
  const char *why = !abi || !rev || !table ? "not an FP-RISC host module" :
                    *abi != FPR_NATIVE_ABI || *rev != FPR_POSIX_CODEGEN_REV ? "host module ABI mismatch (rebuild module)" : 0;
  if (!why && fpr_mod_registered(table)) why = "module already attached";
  if (!why && fpr_mod_attach(table)) why = "unsupported module interface schema";
  if (why) { dlclose(handle); return fpr_mkresult(1, why); }
  return fpr_mkresult(0, "");
}
FPR_FN(fpr_g_Native_x2eattach, attach, 1);
