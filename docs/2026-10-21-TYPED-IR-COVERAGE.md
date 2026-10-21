# Typed IR: widening the lowering and both native backends

Branch `typed-ir-coverage`, cut from `codex/a64-overflow-checks-20261020` at
34c3ff9 (M1, M2 both halves); worktree `fprisc-typed-ir-coverage`; five
commits, one per increment, 2026-10-21.  Pages this one continues:
[M1](2026-10-20-TYPED-IR-M1.md), [M1 repairs](2026-10-21-TYPED-IR-M1-REPAIRS.md),
[the contracts](2026-10-21-NATIVE-IR-CONTRACTS.md),
[M2 A64](2026-10-21-TYPED-IR-M2-A64.md), [M2 x64](2026-10-21-TYPED-IR-M2-X64.md).
The M3 branch (`typed-ir-m3`: liveness, allocation, frames) was cut from the
same commit and is not merged here; the last section says where the two
meet.

The task: widen what the typed IR lowers and what the two direct backends
select, in bounded increments, each with its evaluator semantics, its
verifier case, native execution on this Mac (A64) and the x64 check, and a
coverage number before and after; stop where a form needs allocation in
generated code or aggregate layout.  No default changed: everything here is
behind `FPR_TYPED_IR` (the report) and `FPR_TYPED_IR_BACKEND` (the
backend).  No performance claim is made or measured.

## Coverage, before and after

`tools/typed_ir_coverage.py` (new) builds each `tests/bench/<name>.fpr`
with `FPR_TYPED_IR=1` into a fresh private cache, so the root, the prelude
and every std unit it needs report their lowering, and sums the report per
program.  "Emitted" is the number of functions the generator emits for the
program across those units; a column is the number that lower after the
increment named at its head.  (Increment 2's column was measured on a
throwaway worktree of its commit after a concurrent build broke the first
measurement; the other columns were measured in place.)

| Program | emitted | before | 1 bits | 2 arity | 3 symbols | 4 simplify | 5a $-entries | 5b apply |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| byteloop | 358 | 128 | 128 | 128 | 136 | 136 | 136 | 144 |
| fib | 270 | 115 | 115 | 115 | 115 | 115 | 115 | 118 |
| floatcmp | 269 | 113 | 113 | 113 | 113 | 113 | 113 | 116 |
| helpers | 274 | 117 | 118 | 118 | 118 | 118 | 118 | 122 |
| mixed_locals | 269 | 113 | 113 | 113 | 113 | 113 | 113 | 116 |
| nbody | 269 | 113 | 113 | 113 | 113 | 113 | 113 | 116 |
| pingpong | 272 | 113 | 113 | 113 | 113 | 113 | 113 | 117 |
| sha | 640 | 194 | 198 | 199 | 216 | 216 | 216 | 226 |
| specialization | 272 | 116 | 116 | 116 | 116 | 116 | 116 | 120 |
| strbuild | 270 | 113 | 113 | 113 | 113 | 113 | 113 | 116 |
| vecread | 272 | 113 | 113 | 113 | 113 | 113 | 113 | 116 |
| xpingpong | 272 | 113 | 113 | 113 | 113 | 113 | 113 | 117 |
| all | 3707 | 1461 | 1466 | 1467 | 1492 | 1492 | 1492 | 1544 |

The gain is modest in function counts because a function that stops being
refused for one reason is mostly refused for the next: the M4 forms.  The
refusal reasons summed over the corpus (names and numbers removed), before
and after:

| Reason | before | after |
|---|---:|---:|
| a field projection | 723 | 756 |
| a constructor with fields | 720 | 920 |
| the primitive `_` | 435 | 259 (`strlen`, `charAt` only) |
| a string literal | 219 | 228 |
| the primitive or HAL value `_` | 68 | 0 |
| a partial or over-saturated application | 36 | 0 |
| an application of the local `_` | 28 | 0 |
| the function value `_` | 14 | 0 |
| arity above 8 | 2 | 0 |
| the CAF `_` | 1 | 0 |

Every reason that does not need allocation in generated code or aggregate
layout is gone.  What is left is M4's: constructors with fields and field
projections (object layout and the roots contract), string literals and the
two string primitives `strlen` and `charAt` (string objects).  The 170
functions that moved from "primitive `$receiveLoop`" to "a constructor with
fields" are the receive-turn trampolines whose packed state is a tuple.

## The increments

Each increment is one commit, with its evaluator semantics
(`Codegen.Eval`), its verifier case (`Codegen.Verify`, `tests/TypedIR.hs`),
its dump form, its selection on both targets, native execution on this Mac
through `tests/check_typed_ir_a64.py` and the x64 check through
`tests/check_x64_scalar.py` under Rosetta.  The selection revisions moved
a64 2 → 6 and x64 1 → 5 (each is a unit-cache and run-cache identity).

### 1. `band`, `bor`, `bxor`, `BITSHIFTL`, `BITSHIFTR` (2f61dda)

`OBit BitOp` (TInt TInt → TInt, pure) and `OShift ShiftOp` (TInt TInt →
TInt, may trap).  The lowering accepts them only as declared HAL names of
arity two that nothing shadows, which is the legacy inline table's
condition.  The semantics are `runtime/bits.c`'s: the bit operations are
two's complement on the untagged values; a shift count outside 0..63 traps
with `BITSHIFTL: shift must be 0..63` (or `BITSHIFTR`), checked first; the
shift is the 64-bit shift of the untagged value, logical to the right, and
the result keeps its low 63 bits sign-extended (`IR.wrap63`: what the
legacy `slli 1; ori 1` then `srai 1` leave).  Selection: one instruction
for a bit operation; for a shift an unsigned compare of the count against
64 (`b.hs` / `jae`: a negative count is huge), the register-count shift
(`lsl`/`lsr` with a register, `shlq`/`shrq %cl` with the count fixed to
`%rcx` as `tests/SelectedIR.hs` wrote the shape), the 63-bit wrap, and a
slow path that retags both operands and re-enters `fpr_g_<name>_call2`,
which traps with the primitive's text.

### 2. Arities 9 to 64 through the per-hart spill cells (293e694)

`IR.arityCeiling = 64`: eight register arguments and the 56 hart spill
cells (fpr.h `FPR_ARGSPILL`, Codegen `spillCells`).  The lowering, the
verifier (a definition, a call or a tail transfer above it is refused) and
both backends enforce it; the lowering's refusal of a ninth parameter is
gone and strict mode no longer refuses such functions.  The contract is
the legacy one (the contracts page, "Arguments 9–64"): the caller stores
argument j+9 to cell j at `8*(1+j)` from the hart block after every
argument is evaluated and with no call between the stores and the
transfer; the callee copies the cells into its frame before the entry
sequence's calls, so they are dead by the first safepoint.  A64: a
`store.spill` pseudo per cell reads the hart into x9 (x28, or the TLV or
ELF TLS read) and stores; the prologue reads the hart once (`hart.x9`) and
parks each cell through x10 (`park.spill`); `bl` and `tailjump` fix only
the first eight arguments to x0..x7.  x64: the same through `%r10` at the
call and `%r11` in the prologue, after the `fpr_x64_a6/a7` TLS cells for
arguments 7 and 8.  A 65th parameter never reaches the generator (the
front end bundles arguments beyond the convention), so the ceiling check
is exercised by the unit tests.

### 3. Dead arms, nullary definitions, function and HAL values, whole-program lookups (ce6eb87)

`TUnreachable String` is a dead arm (Core's `CErr`, which exhaustiveness
proved unreachable): the evaluator traps with its text if reached; both
backends emit the legacy `la <str>; call fpr_panic` as a `panic` pseudo
that leaves the function; the unit carries one String object per distinct
text after the native text, in the format's read-only section and label
spelling (`Target.Common.stringObject`, `stringLabel`; `Codegen` dedupes
by label).  The lowering closes a dead arm's block in tail position and in
a branch arm of value position, where the live arm then continues without
a join; both arms dead is refused by name.

`OSymbol` is the legacy symbol load for a core primitive's object
(`fpr_prim_obj_`) and a declared HAL contract (`fpr_g_`); `OFunValue`
(from increment 5; increment 3 used `OSymbol` for it) is a program
function's static PAP (`fpr_obj_`), refused for a private worker, which
has none.  A nullary definition is evaluated by a call with no arguments,
local or imported.  The primitive table the lowering receives is now
`Codegen.Lower.Prim` (arity, direct C entry if any, object symbol if any).

The largest effect came from a bug the coverage report exposed:
`lowerProgram` was given the unit's *emitted* functions as its whole
program, so the prelude's nullary constructors and the callees a unit
elides because the shared prelude unit emits them were unknown to it
(53 of sha's refusals named `Nil`, `True` or `Unit` as HAL values).  It now
takes the whole program for lookups and the emitted functions to lower, as
the legacy generator's `known` and `base` see it.

### 4. The simplification the M1 page deferred (25e75dd)

`Codegen.Simplify`: three IR-to-IR passes, each verified, a refusal being a
compiler error naming the pass.  Fold conversion pairs: `untag (tag u)` is
u, `tag (untag v)` is v (a TVal that is an Int by typing is exactly its
retagged payload), `truth (boolof p)` is p.  Branch on the comparison: a
join block whose one parameter feeds only a `truth` that a `condbr` tests
is threaded edge by edge, a Bool constant jumping to its arm, a `boolof p`
edge branching on p itself, the join staying for other edges and going
when none remain.  Share repeated pure operations within a block.  Pure
definitions nothing uses are dropped after each pass; an operation that
may trap, call or tick is never moved, merged or removed, so the order of
traps and effects is the lowered program's.  Both the report and the
backend consume the simplified program.  The differential check is in two
places: `tests/TypedIR.hs` evaluates every fixture program before and
after on fixed inputs and requires identical results, traps and event
order, and the `FPR_TYPED_IR` eval report evaluates every request on both
programs and errors on a difference.  The report names the instructions
removed per function; `sum` and `fib` lose their repeated `untag n`; the
hand-written worker boundary loses its three conversions and the
hand-written Bool join is threaded away with its block.

### 5. The largest remaining reasons (28d6b96)

5a. `$receiveLoop` and `$vec.at/get/len` are direct C entries in both
generators (`fpr_g__x24receiveLoop_call2`, `fpr_g__x24vec_x2eat_call2`);
the M2 lowering excluded every `$`-name from Foreign calls.  The exclusion
now names only the families the legacy generator expands in place
(`$arc.`, `$scalar.`, `$mem.`, `$sym.`, `$fuel`, `F64.`, `F32.` and the
inlined plain names).

5b. The generic application: `OApply head args` (TVal.. → TVal, any
effect) is `fpr_applyN` for a local head, a partial or over-saturated spine
of a known function, or a computed head (a branch answering a function).
The lowering evaluates the head then the arguments left to right as tagged
words, as the legacy `CApp` case does.  The evaluator states
`fpr_applyN`'s rules over `RPap name supplied`: an Int traps `apply:
applied an integer`, an object that is no PAP traps `apply: not a
function value`, fewer arguments than the function still needs make a
larger PAP, exactly enough call it, more call it and apply the result to
the rest; an application of a primitive's object is `Stuck` (the evaluator
models no C).  Both backends push the head and every argument 16 bytes
apart (the last argument at the stack pointer), call `fpr_applyN(head, n,
sp)` and pop; every slot is frame-pointer relative, so the moving stack
pointer touches nothing, and the pushes use the headroom the entry check
guaranteed, as the legacy pushes do.  This needs no allocation in
generated code: the PAPs are the runtime's, as for any primitive that
allocates.  It unlocked 64 functions directly (every "application of the
local" and "partial or over-saturated application" in the corpus) and
let the 170 receive-loop trampolines reach their real reason.

## Evidence

`tests/check_typed_ir_a64.py` (whole-unit strict mode on
`tests/typed_ir/scalarlib.fpr` under the legacy root `scalar_mod.fpr` with
the C harness `tir_probe.c`): 41 of 41 functions native; 64 calls equal
the legacy binary and the independent arithmetic in the script, among
them the shifts at 0, 62, 63, 64 and negative counts, the bit operations
on negative values, a hash loop of shifts and xors, the ten-parameter
rotation as a definition, a non-tail call, a tail call and a self loop of
100000 turns through the cells, the 64-parameter rotation over 200000
turns, the nullary definition, the prelude's `True`/`False` from the
shared unit, a function value and a HAL value handed to C which calls
back through them (`TirProbe.call1`), a function parameter applied, a
partial application made and applied, an over-saturated spine; the dead
arm of a case on `Unit` reached from C through `TirProbe.callU` with an
Int, trapping with the legacy text `case: no matching pattern; arms were
[PCon "Unit" []]`; deep recursion across 8 stack segments; one and four
harts; the cache transitions; the Mach-O TLV and ELF a64 variants
assembled by clang.

`tests/check_x64_local.py --require-execution` (Rosetta, the substitute
runtime in `tests/base/x64_scalar_oracle.c`): the scalar fixture with
`shift`, `rotate8` (nine parameters) and `rotate63` (the 64-parameter
ceiling) native under strict mode, the first and last cell offsets
(`8(%r10)`, `448(%r10)`; `movq 8(%r11)`, `movq 448(%r11)`) present in
`rotate63`; 31710 C-reference cases, 13 exact slow-path traps (the shift
count traps through `fpr_g_BITSHIFTL_call2` with the original operands
retagged), a nullary definition evaluated by a call, the dead arm of `tick`
reached with an Int and its String object's layout checked byte for byte
by the oracle's `fpr_panic`, 22 generic applications through a substitute
`fpr_applyN` that checks the staging (head at `16n`, argument i at
`16(n-1-i)`); the whole unit text including the `.Ltirstr_` objects
assembled for ELF with real TLS relocations; the mixed legacy/native
boundary variants.  The register, self-loop and vector probes of the suite
also pass.

`tests/check_typed_ir_bench.py` (new): every bench program with an
`.expected` output built with `FPR_TYPED_IR_BACKEND=mixed` into a fresh
cache and run on this Mac: 1544 of 3707 functions native across the twelve
programs, every output equal to its `.expected`.  This is the execution
evidence for the forms the fixtures cannot reach: the receive loops
(`pingpong`, `xpingpong`), the std units' partial applications, the
prelude's constructors from an elided unit.

`tests/check_typed_ir.py` (M1): the report leaves the emission unchanged,
dumps equal across targets and runs, the evaluations equal the legacy
binary, and `sum`'s report line names its removed instruction.
`tests/TypedIR.hs`: 24 verifier refusals by name (five new: a shift of a
tagged word, a bit operation declared a predicate, arity above the ceiling,
an unreachable terminator without a reason, an empty symbol); the bits.c
semantics and trap order; 9, 64 and 65 parameters and a 65-argument spine;
dead arms in tail and value position, both arms dead refused; nullary
definitions, function/HAL/primitive values, the private worker refused, a
name with no object refused; whole-program lookups with an elided
definition; the simplification differential on every fixture program and
the three shapes; the generic application's four heads and two traps.
`check_registers.py`, `check_self_loops.py`, `check_workers.py`: PASS.

## What was not verified

- Nothing ran on Linux x86-64: the x64 evidence is Rosetta with the
  substitute runtime (no Linux TLS, no scheduler, no real `fpr_applyN`,
  the saturated case only).  Nothing ran on an ELF AArch64 host, under
  QOS, or on a board.  RV64/RV32 have no direct backend.
- `check_base.py` as a whole was not run; the suites named in the task
  were, each on the final build.
- The evaluator's `RPap`/`RSym` equality is structural; the runtime's deep
  equality of PAP objects was not compared against it (no fixture applies
  `==` to function values).
- The TLV hart read inside `store.spill` (a64mac without `--base`) saves
  and restores x0/x30 on the stack below sp as the entry sequence does;
  the fixture builds use x28, so that variant was only assembled, not run.
- Coverage was measured on `tests/bench`'s programs and the std units they
  pull in; other programs may have other dominant reasons.

## Recorded, not started (M4)

In order of the functions they block in the corpus: constructors with
fields (920) and field projections (756) need object layout, the allocator
entry and the roots contract (the contracts page, "Managed values and
profile-specific roots"); string literals (228) need string objects in the
unit and the same contract for the values they produce; `strlen` and
`charAt` (259) are the legacy guarded expansions over string objects.  The
receive-turn trampolines are behind the constructors.  Nothing else
remains in this corpus.

## Where this meets M3

The M3 branch changed `Target/A64.hs` and `Target/X64.hs` in `emitFn*`,
placement and the render forms for its prologue/epilogue, and added
`Liveness.hs`/`Allocate.hs`; this branch changed the selection parts
(`selectInstr`, `selectTerm`, the builders) and the render forms of its new
pseudos, plus two things that touch the prologue: the spill-cell copies in
`paramStores` (`hart.x9`, `park.spill` on A64; `park.spill` on x64) and
`nfStrings` on `NativeFn`.  Both touched `Codegen.hs` (this branch:
`nativeSelect`'s whole-program argument, `foreignEntries` as `Prim`, the
native string objects in `emNative`, the simplifier), `fp-risc.cabal` (one
module each), `tests/check_x64_scalar.py` and
`tests/base/x64_scalar_oracle.c`.  The new pseudos declare what they touch
(`store.spill`: x9, x16, x17 or %r10; `push`: sp; `applyn`: x0..x2 and the
caller-saved set, or %rdi/%rsi/%rdx/%rsp; `panic`: a non-returning call),
so an allocator that honours `siImplicitDefs` and `siClobbers` keeps
nothing live across them; the `push` sequence moves sp between
instructions, which only matters to code that addresses the frame through
sp, and neither branch does.
