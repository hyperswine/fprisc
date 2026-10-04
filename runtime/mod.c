/* mod.c — dynamic dispatch over the compile-time module table.
 *
 * Codegen emits `fpr_modtab`: schema header followed by zero-terminated
 * (hash, name, PAP, checked-interface) word rows, one per remote-callable export.  `Mod.fn hash name`
 * resolves a function value from a module HASH and an export name —
 * the same (hash, name) pair FPRLive ships over the wire, so a remote
 * call and a local one go through the identical lookup.  The hash of a
 * used module is at hand because the module alias itself evaluates to
 * its hash string:
 *
 *     M = use "mymod#4f2a...".
 *     f = Mod.fn M "double".      # == M.double, resolved at runtime
 *
 * Pinned hashes make this safe to do late: the table can only ever
 * contain the exact code the hash names.
 */
#include "fpr.h"

/* weak empty-table default: only the root unit of a build with modules
 * emits a real fpr_modtab (strong .globl data from Codegen); a
 * module-free image overrides nothing and just sees this empty table.
 * (A plain `extern ... weak` declaration with no definition anywhere
 * is what Apple's ld refuses to leave unresolved in a main executable
 * -- an actual weak definition is required, coalesced the same way on
 * both ELF and Mach-O.) */
__attribute__((weak)) const uw fpr_modtab[1] = {0};

/* ---- attached tables: DYNAMICALLY LOADED module tables --------------
 * A loaded plugin image (qos_abi.h's plugin slot) carries its own
 * checked module table; fpr_mod_attach registers it and every
 * lookup below searches the static table first, then attachments in
 * attach order.  Mod.find resolves BY NAME ONLY across attachments --
 * the caller of a runtime-loaded library has no hash to pin (the whole
 * point is not knowing the code in advance), so absence is data. */
static const uw **xtabs; /* doubles: a program attaches as many libraries as it has memory for */
static int nxtabs, capxtabs;

#define MOD_MAGIC ((uw)0x4650524d)
#define MOD_SCHEMA ((uw)1)
#define MOD_HEADER 3
#define MOD_ROW 4
static const uw *rows(const uw *tab) {
  if (!tab || !tab[0]) return 0;
  if (tab[0] != MOD_MAGIC || tab[1] != MOD_SCHEMA)
    fpr_cpanic("module table: unsupported interface schema (rebuild image)");
  return tab + MOD_HEADER;
}
int fpr_mod_registered(const uw *tab) {
  for (int i = 0; i < nxtabs; i++) if (xtabs[i] == tab) return 1;
  return 0;
}
int fpr_mod_attach(const uw *tab) {
  /* Reject legacy tables before publishing or walking their old row layout. */
  if (!tab || tab[0] != MOD_MAGIC || tab[1] != MOD_SCHEMA) return -1;
  if (!tab[2] || ISINT(tab[2]) || TID(tab[2]) != T_STR) return -1;
  for (int i = 0; i < nxtabs; i++)
    if (xtabs[i] == tab) return 0; /* re-attach: idempotent */
  if (nxtabs == capxtabs) {
    int cap = capxtabs ? capxtabs * 2 : 8;
    /* the old table is NOT freed: a Mod.find on another hart may be walking
     * it, and doubling wastes at most the final table's size again */
    const uw **t = (const uw **)fpr_alloc((uw)cap * sizeof *t);
    for (int i = 0; i < nxtabs; i++) t[i] = xtabs[i];
    xtabs = t;
    capxtabs = cap;
  }
  xtabs[nxtabs++] = tab;
  return 0;
}

static int str_eq(const str_t *a, const str_t *b) {
  if (a->len != b->len) return 0;
  for (uw i = 0; i < a->len; i++)
    if (a->bytes[i] != b->bytes[i]) return 0;
  return 1;
}

static const uw *tab_at(int i) { /* -1 = the static table */
  return rows(i < 0 ? fpr_modtab : xtabs[i]);
}

static V h_modfn(V hash, V name) {
  if (ISINT(hash) || TID(hash) != T_STR) fpr_cpanic("Mod.fn: hash not a String");
  if (ISINT(name) || TID(name) != T_STR) fpr_cpanic("Mod.fn: name not a String");
  const str_t *h = (const str_t *)hash, *n = (const str_t *)name;
  for (int t = -1; t < nxtabs; t++)
    for (const uw *p = tab_at(t); p && p[0]; p += MOD_ROW)
      if (str_eq((const str_t *)p[0], h) && str_eq((const str_t *)p[1], n))
        return (V)p[2];
  fpr_cpanic("Mod.fn: no such (hash, name) in the module table");
}

/* does the image carry this module at all? (a remote node answering an
 * FPRLive resolve probe wants exactly this predicate) */
static V h_modhas(V hash) {
  if (ISINT(hash) || TID(hash) != T_STR) fpr_cpanic("Mod.has: hash not a String");
  const str_t *h = (const str_t *)hash;
  for (int t = -1; t < nxtabs; t++)
    for (const uw *p = tab_at(t); p && p[0]; p += MOD_ROW)
      if (str_eq((const str_t *)p[0], h)) return BOOL(1);
  return BOOL(0);
}

/* Mod.resolve hash name -> (1, fn) | (0, 0)  -- the URL-service
 * resolver contract: a MISS IS DATA, not a panic.  /services/modules
 * (system.fpr) answers through this; an FPRLive remote resolver
 * answers probes with exactly this shape.  Mod.fn keeps its loud
 * contract for callers who pinned a hash and consider absence a bug. */
static V mktup2(V a, V b) {
  hdr_t *t = (hdr_t *)fpr_alloc(8 + 2 * sizeof(uw));
  t->tid = T_TUP2;
  t->var = 0;
  *(V *)((char *)t + 8) = a;
  *(V *)((char *)t + 8 + sizeof(uw)) = b;
  return (V)t;
}
static V h_modresolve(V hash, V name) {
  if (ISINT(hash) || TID(hash) != T_STR) fpr_cpanic("Mod.resolve: hash not a String");
  if (ISINT(name) || TID(name) != T_STR) fpr_cpanic("Mod.resolve: name not a String");
  const str_t *h = (const str_t *)hash, *n = (const str_t *)name;
  for (int t = -1; t < nxtabs; t++)
    for (const uw *p = tab_at(t); p && p[0]; p += MOD_ROW)
      if (str_eq((const str_t *)p[0], h) && str_eq((const str_t *)p[1], n))
        return mktup2(TAG(1), (V)p[2]);
  return mktup2(TAG(0), TAG(0));
}

/* Mod.plugs () -> the number of attached tables; Mod.findAt i name ->
 * (1, fn) | (0, 0) searching table i ONLY.  The app-launcher contract
 * uses one fixed export-name set (appMeta, appInit, ...) in EVERY app
 * plugin, so cross-table search would always find the first app --
 * scoped search is what makes N apps coexist. */
static V h_modplugs(V u) { (void)u; return TAG(nxtabs); }

/* Root source identity from a trusted compiled image. Empty means invalid index. */
static V h_modhashat(V iv) {
  if (!ISINT(iv)) fpr_cpanic("Mod.hashAt: index not an Int");
  sw i = UNTAG(iv);
  if (i < 0 || i >= nxtabs) return (V)fpr_mkstr((const unsigned char *)"", 0);
  return (V)xtabs[i][2];
}
FPR_FN(fpr_g_Mod_x2ehashAt, h_modhashat, 1);

static V h_modfindat(V iv, V name) {
  if (!ISINT(iv)) fpr_cpanic("Mod.findAt: index not an Int");
  if (ISINT(name) || TID(name) != T_STR) fpr_cpanic("Mod.findAt: name not a String");
  sw i = UNTAG(iv);
  if (i < 0 || i >= nxtabs) return mktup2(TAG(0), TAG(0));
  const str_t *n = (const str_t *)name;
  for (const uw *p = rows(xtabs[i]); p && p[0]; p += MOD_ROW)
    if (str_eq((const str_t *)p[0], (const str_t *)xtabs[i][2]) &&
        str_eq((const str_t *)p[1], n)) return mktup2(TAG(1), (V)p[2]);
  return mktup2(TAG(0), TAG(0));
}

/* Mod.find name -> (1, fn) | (0, 0): name-only, ATTACHED tables only.
 * NEWEST ATTACHMENT WINS: the search runs newest-first, which is the
 * whole live-reload story -- attach Math.v2 alongside Math.v1 and
 * every actor that re-resolves after the LiveReload message binds the
 * new code, while in-flight calls into v1 keep running v1 to
 * completion (the old table and image stay mapped; no W^X, no GOT --
 * a resolve is a table walk and a call is a PAP apply). */
static V h_modfind(V name) {
  if (ISINT(name) || TID(name) != T_STR) fpr_cpanic("Mod.find: name not a String");
  const str_t *n = (const str_t *)name;
  for (int t = nxtabs - 1; t >= 0; t--)
    for (const uw *p = rows(xtabs[t]); p && p[0]; p += MOD_ROW)
      if (str_eq((const str_t *)p[1], n)) return mktup2(TAG(1), (V)p[2]);
  return mktup2(TAG(0), TAG(0));
}

/* Mod.compatAt: compare the root module's checked exports. Dependency
 * closures are private to their image; nominal dependency IDs are retained
 * in the root interface. Old images/closures remain mapped. Stamps are
 * compiler-generated claims for trusted images, not cryptographic signatures. */
static V mkstr_c(const char *m) {
  uw n = 0;
  while (m[n]) n++;
  return (V)fpr_mkstr((const unsigned char *)m, n);
}
static V h_modcompatat(V iov, V inv) {
  if (!ISINT(iov) || !ISINT(inv)) fpr_cpanic("Mod.compatAt: indices must be Ints");
  sw io = UNTAG(iov), in = UNTAG(inv);
  if (io < 0 || io >= nxtabs || in < 0 || in >= nxtabs)
    return mktup2(TAG(0), mkstr_c("no such attached table"));
  int checked = 0;
  for (const uw *p = rows(xtabs[io]); p && p[0]; p += MOD_ROW) {
    if (!str_eq((const str_t *)p[0], (const str_t *)xtabs[io][2])) continue;
    checked++;
    const str_t *nm = (const str_t *)p[1];
    if (!p[3] || ISINT(p[3]) || TID(p[3]) != T_STR || !((const str_t *)p[3])->len)
      return mktup2(TAG(0), mkstr_c("old export has no checked interface"));
    uw want = ((const pap_t *)p[2])->arity;
    int hit = 0;
    for (const uw *q = rows(xtabs[in]); q && q[0]; q += MOD_ROW)
      if (str_eq((const str_t *)q[0], (const str_t *)xtabs[in][2]) && str_eq((const str_t *)q[1], nm)) {
        if (((const pap_t *)q[2])->arity != want)
          return mktup2(TAG(0), mkstr_c("arity changed for an export"));
        if (!q[3] || ISINT(q[3]) || TID(q[3]) != T_STR || !((const str_t *)q[3])->len)
          return mktup2(TAG(0), mkstr_c("new export has no checked interface"));
        if (!str_eq((const str_t *)p[3], (const str_t *)q[3]))
          return mktup2(TAG(0), mkstr_c("checked type, contract or ABI changed for an export"));
        hit = 1;
        break;
      }
    if (!hit) return mktup2(TAG(0), mkstr_c("export missing in the new module"));
  }
  if (!checked) return mktup2(TAG(0), mkstr_c("old module has no callable root exports"));
  return mktup2(TAG(1), mkstr_c(""));
}

FPR_FN(fpr_g_Mod_x2efn, h_modfn, 2);
FPR_FN(fpr_g_Mod_x2efind, h_modfind, 1);
FPR_FN(fpr_g_Mod_x2eplugs, h_modplugs, 1);
FPR_FN(fpr_g_Mod_x2efindAt, h_modfindat, 2);
FPR_FN(fpr_g_Mod_x2ehas, h_modhas, 1);
/* Mod.detachLast: pop the NEWEST attachment out of the registry --
 * the refuse path of the live-reload gate.  The plugin image stays
 * mapped (no unload in v1; the sub-slot is spent), but resolution
 * falls back to the previous version, which is the property that
 * matters: a refused swap leaves every binding exactly as it was. */
static V h_moddetachlast(V u) {
  (void)u;
  if (nxtabs > 0) nxtabs--;
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Mod_x2ecompatAt, h_modcompatat, 2);
FPR_FN(fpr_g_Mod_x2edetachLast, h_moddetachlast, 1);
FPR_FN(fpr_g_Mod_x2eresolve, h_modresolve, 2);
