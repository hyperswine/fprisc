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
 * checked module table; fpr_mod_attach registers it.  This file is the
 * REGISTRY and a ROW READER, nothing more: which table to search, in
 * which order, what counts as a match and when two versions are
 * compatible is FP-RISC in core/prelude.fpr (Mod.find, Mod.findAt,
 * Mod.resolve, Mod.has, Mod.compatAt).  Table -1 is the image's own
 * static table; 0.. are attachments in attach order.
 *
 * Attach and detach take a lock; readers on any hart load the count
 * with acquire, and an attach publishes the slot and the array before
 * the count.  A replaced array is never freed: a reader may still be
 * walking it, and doubling wastes at most the final array again. */
static const uw **xtabs; /* doubles: a program attaches as many libraries as it has memory for */
static uw *xrows;        /* row count of each attached table, counted once at attach */
static int nxtabs, capxtabs;
static fpr_lock_t xlock;

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
static uw count_rows(const uw *tab) {
  uw n = 0;
  for (const uw *p = rows(tab); p && p[0]; p += MOD_ROW) n++;
  return n;
}
static int ntabs(void) { return __atomic_load_n(&nxtabs, __ATOMIC_ACQUIRE); }

int fpr_mod_registered(const uw *tab) {
  int n = ntabs();
  const uw **t = __atomic_load_n(&xtabs, __ATOMIC_ACQUIRE);
  for (int i = 0; i < n; i++) if (t[i] == tab) return 1;
  return 0;
}
int fpr_mod_attach(const uw *tab) {
  /* Reject legacy tables before publishing or walking their old row layout. */
  if (!tab || tab[0] != MOD_MAGIC || tab[1] != MOD_SCHEMA) return -1;
  if (!tab[2] || ISINT(tab[2]) || TID(tab[2]) != T_STR) return -1;
  uw nrows = count_rows(tab);
  fpr_lock(&xlock);
  for (int i = 0; i < nxtabs; i++)
    if (xtabs[i] == tab) { fpr_unlock(&xlock); return 0; } /* re-attach: idempotent */
  if (nxtabs == capxtabs) {
    int cap = capxtabs ? capxtabs * 2 : 8;
    const uw **t = (const uw **)fpr_alloc((uw)cap * sizeof *t);
    uw *r = (uw *)fpr_alloc((uw)cap * sizeof *r);
    for (int i = 0; i < nxtabs; i++) { t[i] = xtabs[i]; r[i] = xrows[i]; }
    __atomic_store_n(&xrows, r, __ATOMIC_RELEASE);
    __atomic_store_n(&xtabs, t, __ATOMIC_RELEASE);
    capxtabs = cap;
  }
  xtabs[nxtabs] = tab;
  xrows[nxtabs] = nrows;
  __atomic_store_n(&nxtabs, nxtabs + 1, __ATOMIC_RELEASE);
  fpr_unlock(&xlock);
  return 0;
}

/* table t's rows and their count; 0 for an index that names no table */
static const uw *tab_rows(sw t, uw *count) {
  static uw static_rows = (uw)-1; /* the image's own table never changes: a race only recounts it */
  if (t == -1) {
    if (static_rows == (uw)-1) static_rows = count_rows(fpr_modtab);
    *count = static_rows;
    return rows(fpr_modtab);
  }
  if (t < 0 || t >= ntabs()) { *count = 0; return 0; }
  *count = __atomic_load_n(&xrows, __ATOMIC_ACQUIRE)[t];
  return rows(__atomic_load_n(&xtabs, __ATOMIC_ACQUIRE)[t]);
}
/* row i of table t, or 0 */
static const uw *row_at(V tv, V iv, const char *who) {
  if (!ISINT(tv) || !ISINT(iv)) fpr_cpanic(who);
  uw n;
  const uw *p = tab_rows(UNTAG(tv), &n);
  sw i = UNTAG(iv);
  return (p && i >= 0 && (uw)i < n) ? p + (uw)i * MOD_ROW : 0;
}
static V empty_str(void) { return (V)fpr_mkstr((const unsigned char *)"", 0); }

/* Mod.plugs () -> the number of attached tables */
static V h_modplugs(V u) { (void)u; return TAG(ntabs()); }
/* Mod.rows t -> the number of rows in table t (0 for no such table) */
static V h_modrows(V tv) {
  if (!ISINT(tv)) fpr_cpanic("Mod.rows: table not an Int");
  uw n;
  tab_rows(UNTAG(tv), &n);
  return TAG((sw)n);
}
/* a row's module hash, export name and checked interface; "" for no row
 * (and for a row with no checked interface) */
static V h_modrowhash(V t, V i) { const uw *p = row_at(t, i, "Mod.rowHash: indices must be Ints"); return p ? (V)p[0] : empty_str(); }
static V h_modrowname(V t, V i) { const uw *p = row_at(t, i, "Mod.rowName: indices must be Ints"); return p ? (V)p[1] : empty_str(); }
static V h_modrowiface(V t, V i) {
  const uw *p = row_at(t, i, "Mod.rowIface: indices must be Ints");
  return (p && p[3] && !ISINT(p[3]) && TID(p[3]) == T_STR) ? (V)p[3] : empty_str();
}
/* a row's function value and its arity; for no row, 0 -- the placeholder a
 * miss has always carried in `(0, 0)` */
static V h_modrowfn(V t, V i) { const uw *p = row_at(t, i, "Mod.rowFn: indices must be Ints"); return p ? (V)p[2] : TAG(0); }
static V h_modrowarity(V t, V i) {
  const uw *p = row_at(t, i, "Mod.rowArity: indices must be Ints");
  return p ? TAG((sw)((const pap_t *)p[2])->arity) : TAG(0);
}

/* Root source identity from a trusted compiled image. Empty means invalid index. */
static V h_modhashat(V iv) {
  if (!ISINT(iv)) fpr_cpanic("Mod.hashAt: index not an Int");
  sw i = UNTAG(iv);
  if (i < 0 || i >= ntabs()) return empty_str();
  return (V)__atomic_load_n(&xtabs, __ATOMIC_ACQUIRE)[i][2];
}

/* Mod.fn hash name: the LOUD lookup, for a caller who pinned a hash and
 * considers absence a bug.  It stays here only because `fn` is a keyword,
 * so a prelude structure cannot have a field of that name; Mod.resolve
 * in the prelude is the same search with the miss as data. */
static int str_eq(const str_t *a, const str_t *b) {
  if (a->len != b->len) return 0;
  for (uw i = 0; i < a->len; i++)
    if (a->bytes[i] != b->bytes[i]) return 0;
  return 1;
}
static V h_modfn(V hash, V name) {
  if (ISINT(hash) || TID(hash) != T_STR) fpr_cpanic("Mod.fn: hash not a String");
  if (ISINT(name) || TID(name) != T_STR) fpr_cpanic("Mod.fn: name not a String");
  const str_t *h = (const str_t *)hash, *n = (const str_t *)name;
  for (sw t = -1; t < ntabs(); t++) {
    uw c;
    const uw *p = tab_rows(t, &c);
    for (uw i = 0; i < c; i++, p += MOD_ROW)
      if (str_eq((const str_t *)p[0], h) && str_eq((const str_t *)p[1], n))
        return (V)p[2];
  }
  fpr_cpanic("Mod.fn: no such (hash, name) in the module table");
}

/* Mod.detachLast: pop the NEWEST attachment out of the registry --
 * the refuse path of the live-reload gate.  The plugin image stays
 * mapped (no unload in v1; the sub-slot is spent), but resolution
 * falls back to the previous version, which is the property that
 * matters: a refused swap leaves every binding exactly as it was. */
static V h_moddetachlast(V u) {
  (void)u;
  fpr_lock(&xlock);
  if (nxtabs > 0) __atomic_store_n(&nxtabs, nxtabs - 1, __ATOMIC_RELEASE);
  fpr_unlock(&xlock);
  return (V)&fpr_unit;
}

FPR_FN(fpr_g_Mod_x2efn, h_modfn, 2);
FPR_FN(fpr_g_Mod_x2eplugs, h_modplugs, 1);
FPR_FN(fpr_g_Mod_x2ehashAt, h_modhashat, 1);
FPR_FN(fpr_g_Mod_x2erows, h_modrows, 1);
FPR_FN(fpr_g_Mod_x2erowHash, h_modrowhash, 2);
FPR_FN(fpr_g_Mod_x2erowName, h_modrowname, 2);
FPR_FN(fpr_g_Mod_x2erowIface, h_modrowiface, 2);
FPR_FN(fpr_g_Mod_x2erowFn, h_modrowfn, 2);
FPR_FN(fpr_g_Mod_x2erowArity, h_modrowarity, 2);
FPR_FN(fpr_g_Mod_x2edetachLast, h_moddetachlast, 1);
