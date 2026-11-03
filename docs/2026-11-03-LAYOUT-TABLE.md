# Layout table and the runtime layout check (C1 piece 2a, slice 1)

Date: 3 November 2026. Kind: implementation record. Applies to
`compiler/Compile.hs`, `compiler/Compiler/Options.hs`, `compiler/Build.hs`,
`runtime/runtime.c`, and `tests/check_layout_table.py`. Changes no observable
behaviour; the table is inert rodata and the check compiles out.

## Slice 1 of piece 2a

C1 piece 2 plans to drop the 16-byte allocation preheader. Every walker in the
posix runtime derives a constructor's field count from it
(`nfields = (total - 16 - 8) / W`, nine sites across `dc_release`, `dc_size_in`,
`dc_budget`, `dc_dup`, `kp_dup`, `kp_reaches`, `has_vec`, `vec_release_in`), so
the count has to come from somewhere else first. Slice 1 builds and proves that
source without changing any layout:

1. **The compiler emits it.** The root unit carries `fpr_layout_table` — a
   count, then `(tid, variant, fields)` triples — from `consAll` plus record
   shapes, next to the constructor-name table it already emits for the whole
   image. Emitted under the same owner conditions (no library unit, no builtin
   profile) because only `runtime/runtime.c`'s allocator reads it.
2. **A check build reads it.** `FPR_LAYOUT_CHECK=1` (a build-time define, like
   `FPR_COST_PROBE`) makes `alloc_in`/walker paths assert that the capacity
   implied by the table, `round16(8 + W*arity)`, equals the `total - 16` the
   allocator produced, on every object a walker sees. `FPR_LAYOUT_FAULT=1` adds
   a row of slack to the lookup so the check is shown to stop the program
   instead of passing vacuously.

The assertion is on **capacity, not the derived count**: `nfields` is the arity
*plus* whatever rounding pad `fpr_alloc` zeroed (a 2-field cell is 24 payload
bytes in a 32-byte slot, so `nfields = 3`). The pad is zeroed at allocation and
walked as a zero word, never recursed, so the invariant the table must
reproduce is the rounded capacity.

## What the check found before it went green

- **Record cells carry their field count in the variant word**
  (`Core.Typed.Erase.RecordValue` emits `CMk tid (length fs)`), so a
  `(shape, 0)` entry is never looked up: the table is keyed `(sid, nfields)`,
  with the `(sid, 0)` row kept for the name table's benefit. Without this the
  message program below panicked `the layout table has no entry`.
- **The table cannot be emitted by library units or the builtin profile.**
  `machine/builtin/heap.fpr` compiles through the same root path, so
  `make bare-metal-builtin` produced `multiple definition of fpr_layout_table`
  from `heap.s` and `builtin.s`. It now follows the constructor-name table's
  owner conditions.

## Gate

`tests/check_layout_table.py` (registered at 600 s): for `tests/actors.fpr` and
a message program carrying a nominal ADT, a record and lists, the plain and
`FPR_LAYOUT_CHECK` builds must agree on stdout and exit status, and the
`FPR_LAYOUT_FAULT` build must panic with `layout check`. Re-run alongside:
35/35 Haskell suites, `check_raw`, `check_pair_raw`, `check_list_fusion`.

## What slice 1 deliberately does not do

- **Other object classes.** `PAP`, `TSTR`/`TBITS`, vectors and actor handles have
  their own sizes (arity, `len`, columns, fixed structs); a size function over
  them is slice 2's work, and `total` cannot go before it.
- **The slab word.** Word 8 of the preheader is the owning `fpr_slab_t *`, read
  by `fpr_free`; it is a per-object fact no type table can supply, so it stays.
- **Alignment.** A payload 24-byte cell with an 8-byte preheader starts 8-aligned
  and rounds back to 48 under the current 16-byte buckets: the promised
  48 $\to$ 32 needs the bucket granularity at 8 (or an accepted 8-byte payload
  alignment). That decision, and the `abirev` bump with the walker rewrite, are
  slice 3.
