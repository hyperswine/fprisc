# Typed IR: merging M2, M3 and the coverage increments into main

Date: 2026-10-21. Kind: merge record.
Status: merged on branch `typed-ir-merge`, cut from main at `0b6e8df`.

Three branches carried the typed native IR and none was in main:

| Branch | Tip | What it carries | Page |
|---|---|---|---|
| `codex/a64-overflow-checks-20261020` | `34c3ff9` | the plan, M1, its repairs (codegenRev 67), the M0 register, M2's direct A64 and x86-64 backends, four opt-in legacy modes | [plan](2026-10-20-TYPED-NATIVE-IR-PLAN.md), [M2-A64](2026-10-21-TYPED-IR-M2-A64.md), [M2-X64](2026-10-21-TYPED-IR-M2-X64.md) |
| `typed-ir-m3` | `38227ed` | liveness, the allocator, saved-register prologues, the loop form, the investment review | [M3](2026-10-21-TYPED-IR-M3.md) |
| `typed-ir-coverage` | `475e8ae` | bit operations and shifts, arities 9 to 64, dead arms and function values, simplification, direct C entries | [coverage](2026-10-21-TYPED-IR-COVERAGE.md) |

They were merged in that order, with merge commits. M3 and coverage were
both cut from `34c3ff9` and given separate files, but both changed
`emitFnA64`/`emitFnX64`, the selection revisions and the shared fixtures.

## Textual merges (both sides kept)

- `compiler/Compile.hs` (M2 against main): the strict-mode check before
  the unit is written, and main's whole write of a cached unit (temp file,
  then rename, `66e358d`), both.
- `tests/check_base.py` (M2 against main): main's parallel runner, with the
  branch's eleven sub-checks added as jobs in the branch's order. The three
  that run `cabal exec` (`check_typed_ir.py`, `check_self_loops.py`,
  `check_frame_placement.py`) take the `cabal` lock as main's other cabal
  users do. The branch's `--skip-typed-ir-native` flag (CI runs those two
  in their own step) is now a filter on the job list.
- Fixtures and checks (M3 against coverage): `tests/typed_ir/scalarlib.fpr`
  and `scalar_mod.fpr` carry both sets of functions and cases;
  `tests/check_typed_ir_native.py` both function lists and both sets of
  expectations; `tests/base/x64_scalar_oracle.c` both sets of cases (13
  traps, coverage's count; M3 added none); `tests/check_x64_scalar.py` the
  union of the two strict lists and M3's allocation assertions.
- `docs/README.md` and the plan: every line and every tick from each side.

## Reconciliations in the Target files

Both branches rewrote the same part of `emitFnA64` and `emitFnX64`: how
the parameters get from the caller into the function.

- M3 replaced M2's conservative slot placement with the allocator. The
  parameters arrive through the target's `acArrival`: one `params` pseudo
  that defines them in the argument registers, and on x86-64 a `load.cell`
  per parameter seven and eight. The allocator then decides where each one
  lives.
- Coverage still used M2's placement and added a prologue `paramStores`
  list. It copies parameters 9 and up from the per-hart spill cells into
  their slots: `hart.x9` once, then `park.spill` per cell through x10 on
  A64, and `park.spill` through `%r11` on x86-64.

The merge keeps M3's structure, because coverage's slots no longer exist
there, and carries coverage's contract into it. Each parameter 9+j arrives
by a new `load.spill` pseudo in `acArrival`. The pseudo reads cell j at
W*(1+j) in the hart block into the parameter's own virtual register, and
the allocator places that register like any other. This is what M3 did to
M2's `park.cell` when it made it `load.cell`. Each page's claims still
hold:

- Coverage: the cell layout, which side writes and which reads, and the
  rule that the callee reads the cells before the entry sequence's calls
  (the arrival comes before the entry pseudo). The caller's `store.spill`
  and `bl`/`tailjump` fixing only x0..x7 are unchanged.
- M3: all parameters arrive through `acArrival`, the oracle checks the
  physical stream, and saves and restores are as before.

What changed in the details:

- A64: `load.spill` reads the hart for each cell (`hartRead` into x9, then
  `ldr`/`ldur` into the parameter's register). It declares x9, x16 and x17
  as implicit definitions, the same as `store.spill`, so the allocator never
  gives the loaded parameter x9 and never keeps a value there across it.
  Coverage read the hart once per function. With x28 the extra cost is one
  `mov` per parameter above eight. With the Mach-O TLV read it is one TLV
  call per parameter above eight. Only functions of arity 9 or more pay it.
  `hartX9`, `parkCell` and their render forms are removed.
- x86-64: `load.spill` loads `%fs:fpr_posix_hart@tpoff` into the
  parameter's register, then the cell through it, so it needs no scratch
  register. Before the merge, M3's arrival made a `load.cell` for every
  parameter from the seventh on, which would have named non-existent
  `fpr_x64_a8...` cells once coverage allowed nine or more parameters. It
  now makes a `load.cell` for seven and eight only. `park.cell` and
  `park.spill` are removed.
- The loop form is M3's, unchanged. A self tail call of arity 9 or more
  stays a tail transfer through the cells and is not turned into a loop.
  The loop form counts fixed arguments: there are 8 on A64, and 6 plus the
  two cells on x86-64. A function of arity 9 or more never matches that
  count, so its re-entry re-reads the cells through the arrival. This
  limit is new to the merge. Neither branch alone had a self tail call
  above eight that the loop form could see.
- Selection revisions: A64 7 (M3 3, coverage 6) and x86-64 6 (M3 2,
  coverage 5) at the merge commit, then A64 8 and x86-64 7 with the fix
  below. Each is above both branches' values, so every cached typed-IR
  unit from either branch is invalidated.

## A defect the merge exposed: `store.spill` and the allocator

The first suite run on the merged tree failed in two places.

- A64, `check_typed_ir_a64.py`: `tailWide 5` returned 6553002561 where
  255 was expected. `tailWide` makes a tail call to the 10-parameter
  `rot9`.
- x86-64, `check_x64_scalar.py` under Rosetta: the typed-IR oracle failed
  on the 9- and 64-argument rotations.

Cause: coverage's `store.spill` writes the hart block into x9 (A64) or
%r10 (x86-64) before it reads the value it stores. M3's allocator assumes
an A64 form never does that; its `acEarlyDef = const False` relies on it.
So the allocator gave the outgoing tenth argument x9 itself, and the
expansion stored the hart pointer into the cell. On x86-64 a spilled
argument is reloaded into %r10, the allocator's first scratch register,
and the same thing happened. Neither branch could show this alone. Under
coverage's slot placement no value lives in x9 or %r10 across an
instruction. M3 had no `store.spill`. M3's `checkAllocation` oracle did
not catch it, because it does not model an expansion that writes a
register before reading its operands. That gap is still open.

Fix (selection revisions A64 8, x86-64 7):

- A64: `acEarlyDef` is true for `store.spill`. The allocator then keeps
  its operand out of x9, x16 and x17, its declared implicit definitions.
  This is a narrow exception to the claim in M3's A64 configuration, now
  written in the comment there.
- x86-64: `store.spill` declares %r10 and %r11, both scratch and never
  allocated. It reads the hart block into whichever of the two does not
  hold the value. It is also an early-def form.

After the fix, `tailWide 5` = 255, and no `store.spill` in the 64-argument
rotation stores its own base register.

## Test expectation changed

`tests/check_x64_scalar.py` asserted the bytes of coverage's x86-64
prologue copy (`movq 8(%r11), %r11` and `movq 448(%r11), %r11`). The
arrival now loads into the parameter's own register, so the check accepts
`movq 8(%R), %R` and `movq 448(%R), %R` for any one register R. It
still requires the first and last cell. After the `store.spill` fix
above, the caller's stores go through %r10 or through %r11 (%r11 when the
value was reloaded into %r10), and the check accepts either register; it
used to require %r10. The combined line it prints no longer says "shifts and
arities 9/64 explicitly legacy" (that was M3's text from before coverage).
It says "including arities 9 and 64".

## Validation

Compiler at `a5c4c6f` (the merge plus the fix). Run on the M1 Mac mini
(arm64, macOS, Rosetta), as this project's suites are, from a fresh
worktree with a fresh `make fpr`:

| Check | Result |
|---|---|
| `tests/check_typed_ir.py` | PASS (verifier 24 malformations, bits/shifts, dead arms, generic application, simplification, M1 on a64/x64/rv64) |
| `tests/check_typed_ir_a64.py` | PASS (SelectedIR, AllocIR, the whole-unit fixture with both branches' functions under strict mode, harts, caches) |
| `tests/check_typed_ir_x64.py` | host skip, as designed on arm64; its shared SelectedIR and AllocIR checks passed |
| `tests/check_x64_local.py --require-execution` | PASS under Rosetta (scalar/ABI, self loops, vectors) |
| `tests/check_x64_scalar.py` | PASS, all modes including typed-ir (24 strict functions, arities 9 and 64, pressure spills 9, rotate6 a loop) |
| `tests/check_registers.py`, `check_self_loops.py`, `check_workers.py` | PASS |
| `tests/check_typed_ir_bench.py` (coverage) | PASS: 12 programs, 1544/3707 functions native, every output equal to `.expected` (the coverage page's count) |
| `tests/check_base.py` | PASS: 105 jobs in 280 s on 8 workers |

Not verified here:

- Native Linux x86-64. CI runs it after the push; Rosetta substitutes the
  Linux TLS and runtime hooks.
- A64 ELF execution, boards, performance. No timing was claimed for the
  merge.
- The Mach-O TLV hart read inside `store.spill` and `load.spill`. It is
  assembled by the A64 pipeline check but not executed: the host uses x28.
- QOS, which is recorded with its pin in the qos repository.
