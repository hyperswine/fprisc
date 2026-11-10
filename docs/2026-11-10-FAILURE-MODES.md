# Failure modes: what traps, what overflows, what is silently wrong

Date: 2026-11-10. Kind: audit and proposal. Applies to `540ba57` (main after
PR #59). Every behaviour marked **verified** was run on this date: native is
`fpr build` for the posix system on x86-64 Linux, Sol is `fpr sol` on the same
file. A64 and RV64 were **not executed** (no QEMU on the audit machine); where
this page says something about them it cites the existing record and says so.

This page answers one question: where does a program fail abruptly, and where
does it fail *silently* (a wrong value, a clamp, a default, or two backends
disagreeing)? It then proposes one policy for each kind of failure: return
`Option`/`Result`, a precondition in the signature (discharged statically where
possible), an explicit wrapping operation, or a typed trap that stays.

## What already exists (read before the table)

Most of the machinery this audit wants is already in the tree. The gaps are
in reach and consistency, not in mechanism.

- **Int overflow traps by default** on native ([2026-10-12-INT-OVERFLOW.md](2026-10-12-INT-OVERFLOW.md)):
  `+ - * /` and negation check the 63-bit fit in the C primitives, the inline
  fast paths, the vector kernels and the NEON lanes. `I64` is the type that
  wraps; `I32` wraps too ([2026-10-12-MEMORY-I32-REFINEMENTS.md](2026-10-12-MEMORY-I32-REFINEMENTS.md)).
- **Preconditions in signatures exist** (`compiler/Precond.hs`):
  `d : Int -> (y : Int | y != 0) -> Int`. The predicate fragment is
  comparisons over `+ - *` of variables and literals, with `and2`/`or2`.
  Facts come from the function's own preconditions, clause guards, case
  discrimination and literal binds. A discharged obligation emits no code. An
  undischarged one becomes a call-site check with blame:
  `precondition violated: d requires (y != 0), got y=0 (in main)`.
  `std/math` already uses it: `mod`, `rem : Int -> (b : Int | b != 0) -> Int`.
- **The builtin `/` has the same axiom** (`divisor != 0`). It is analyzed and
  counted, but an undischarged divisor falls back on the runtime trap rather
  than a blamed check (`BuiltinTrap`). `FPR_PRECOND_NOTES=1 fpr compile ...`
  prints every obligation; the summary line always prints.
- **Interval discharge** ([2026-10-28-INTERVAL-DISCHARGE.md](2026-10-28-INTERVAL-DISCHARGE.md),
  [2026-11-03-BUILTIN-TYPE-SPEC-AND-INTERVAL.md](2026-11-03-BUILTIN-TYPE-SPEC-AND-INTERVAL.md),
  [2026-10-31-STRING-SCAN-RANGES.md](2026-10-31-STRING-SCAN-RANGES.md)) removes overflow checks on
  `i + 1` under `i < n`, threads guards decided by dominating facts, and has
  loop-induction and `strlen >= 0` facts. It works on machine IR, inside one
  function; the INTERVAL page names `Precond` as the place for caller facts.
- **std already prefers `Option`/`Result` for absence and failure**:
  `L.head`, `L.tail`, `L.last`, `L.get`, `L.minimum`, `M.get`, `S.indexOf`
  answer `Option`; `S.toInt`, `I64.toInt`, `I32.toInt`, `wireInt` answer
  `Result`. The 2026-10-11 [edge battery](2026-10-11-EDGE-CASES.md) fixed the
  wrapping parse, `chr` range, `Sys.exit` range, SIGPIPE and the HTTP bounds.
- **The semantic policy** ([2026-11-07-PIPELINE-SEMANTIC-POLICY.md](2026-11-07-PIPELINE-SEMANTIC-POLICY.md))
  already classes `Int` `+ - *`, `/`, indexing and allocation as trapping
  operations whose first-trap order passes must preserve.

## Top silent failures (verified unless marked)

1. **Sol and native disagree on Int overflow, and Sol disagrees with itself.**
   Native traps at 63 bits. The Sol interpreter's `Int` is a Haskell `Integer`
   (`compiler/Sol/Val.hs`: `VInt !Integer`), so `big + 1` prints
   `4611686018427387904` and exits 0. The Sol JIT computes the same fold in
   64-bit registers and **wraps silently**:
   `foldl (fn a x -> a + x * 1000000000000000) 0 (L.range 1 100000)` printed
   `4678588804905828352` with the JIT and `5000050000000000000000000` with
   `SOL_JIT=0`. The native build of the same fold traps by name. A program's
   answer depends on the backend and on whether a loop got hot.
2. **Strings are bytes on native and code points on Sol.** `strlen "é"` is
   `2` natively and `1` on Sol; `charAt "é" 0` is `195` and `233`.
3. **`S.fromCodes` is byte-only on native.** It maps `chr` over the codes, so
   `S.fromCodes [233]` is a single byte `0xE9` (invalid UTF-8; `strlen` 1), and
   `S.fromCodes [233, 8364]` panics with `chr: 8364 is not a byte (0..255);
   chr makes one byte, String.fromCodes makes UTF-8`. That message points at
   the function that failed.
4. **The rebinding type-check gap.** In a body with no signature,
   `v = [1, 2]; v = "x" :: v; print "{L.length v}"` compiles on both
   frontends and prints `3`. The same rebinding into a *new* name is refused
   (`(::): cannot unify Int with String`). Recorded in the MutMap PR as
   pre-existing at `95e2fbc`; still present at `540ba57`.
5. **A duplicate clause is silently unreachable.** `f x = 1. f x = 2.`
   compiles, and `f 5` is `1` on both (edge battery #38, still open).
6. **Lenient helpers that answer a default.** `parseInt "abc"` is `0`,
   `parseInt "12x"` is `12`, `parseInt "99999999999999999999"` is
   `999999999999999999` (stops at the digit that would overflow) natively;
   on Sol `parseInt "abc"` panics. `Math.powInt 2 (-1)` is `0`. `I32.ofInt`
   of a 63-bit value is its low 32 bits (`-1` for `intMax`), as documented.
7. **Sol crashes in the host for `chr` outside Unicode.** `chr (-1)` and
   `S.fromCodes [1114112]` end Sol with `fpr: Prelude.chr: bad argument`
   (a Haskell exception, not a Sol panic). `chr 256` on Sol answers a
   one-character string, where native refuses it by name.
8. **A literally violated precondition compiles.** `d 100 0` against
   `(y : Int | y != 0)` is reported as `runtime check inserted` and traps at
   run time. The obligation is decidably false at compile time.
9. **Builtin `/` obligations do not reach the caller.** `d x = 100 / x` with no
   precondition compiles silently; the `y != 0` requirement exists only as a
   runtime trap inside `d`, invisible in `d`'s type.

## The table

Columns: native / Sol behaviour (V = verified here, D = from an existing doc,
U = unverified), whether it is silent, the proposal, effort (S under a day,
M a few days, L a week or more; estimates), and the pipeline phase from
[2026-11-07-PIPELINE-REFACTORING-ROADMAP.md](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md).

### Integer arithmetic

| Operation | Native x86-64 | Sol | Silent? | Proposal | Effort | Phase |
| --- | --- | --- | --- | --- | --- | --- |
| `intMax + 1`, `intMin - 1`, `*` past 63 bits | V: named trap `Int overflow: a + b does not fit an Int (...)`, exit 1 | V: exact bignum, exit 0 (interpreter); V: wraps at 2^64 in a JIT `foldl` | **Sol: yes** | Keep the trap (2026-10-12 decision). Make Sol trap at the same 63-bit bound in the interpreter (`arith`) and the JIT (an overflow-flag branch to the existing `fuelTrap` poison, as division by zero does) | M | Sol VM (outside P-phases); differential test in P0 corpus |
| `intMin / (-1)`, `0 - intMin`, `Math.abs intMin` | V: named overflow trap | V: exact bignum (`abs` not run: `std/math` does not load on Sol, see below) | **Sol: yes** | As above | with above | - |
| `2 ^ 63` | V: overflow trap (from the squaring `*`) | V: `9223372036854775808` | **Sol: yes** | As above | with above | - |
| `x ^ n`, `n < 0` | V: `(^): negative exponent` | V: same, plus a hint | no | Precondition `(n : Int | n >= 0)` on `intPow` so it is discharged or blamed at the caller | S | P1 (caller facts) |
| `Math.powInt a n`, `n < 0` | V: answers `0` | not run (std/math needs F64) | **yes** | Same precondition as `^`, or `Option Int` | S | - |
| `x / 0`, `x % 0` (Int) | V: `division by zero`, exit 1 (literal `7 / 0` too) | V: `SOL PANIC: division by zero` | no | Undischarged builtin `/` becomes a visible precondition (Decision 3); a literal zero divisor is a compile error | S-M | P1 |
| `Math.mod 7 0` (has `(b : Int | b != 0)`) | V: `precondition violated: mod@... requires (b != 0), got b=0 (in main)` | not run (std/math) | no | Already the target style; refuse the literal case at compile time | S | P1 |
| `(0 - 7) % 2` | V: `-1` (`%` is `Int.mod`, which truncates: the sign of the dividend); `Math.mod` gives `1`, `Math.rem` `-1` | not run | surprising, documented in code | Rename: `%` stays truncating but the struct field becomes `rem`; or make `%` the floored `Math.mod` (Decision 6) | S | - |
| `BITSHIFTL 1 62` | V: `-4611686018427387904` | not available on Sol (type error) | by design (bit ops act on the 63-bit word) | Keep; say so in the `band`/`BITSHIFTL` docs | S | - |
| `BITSHIFTL 1 63` | V: `0` | n/a | yes, but the panic text for `-1` says "shift must be 0..63" | Make the message and the rule agree (0..62 refused past, or 63 documented) | S | - |
| `BITSHIFTL 1 (-1)` | V: `BITSHIFTL: shift must be 0..63` | n/a | no | Precondition `(k : Int | k >= 0 and k < 63)` so it can be discharged | S | P1 |
| `I64` `*` past 64 bits | V: wraps (`-4`) | n/a | by design | Keep (I64's contract) | - | - |
| `I64 / 0`, `I32 / 0` | V: `I64: division by zero`, `I32: division by zero` | n/a | no | Preconditions as Int | S | P1 |
| `I64.toInt` too big | V: `Err I64.toInt: does not fit an Int (63 bits)` | n/a | no | Keep | - | - |
| `I32.ofInt intMax` | V: `-1` (low 32 bits) | n/a | **yes, by design** (MEMORY-I32 page) | Add `I32.ofIntChecked : Int -> Option I32` beside it; consider renaming the wrapping one `I32.wrapInt` | S | - |
| A64/RV64 inline checks, NEON lanes | D: same traps (INT-OVERFLOW page); RVV Int kernels decline Int bodies | - | U here | Run `tests/base/intovf.fpr` under QEMU in CI legs that have it | - | P0 |

### Floating point and conversions

| Operation | Native x86-64 | Sol | Silent? | Proposal | Effort | Phase |
| --- | --- | --- | --- | --- | --- | --- |
| `1.0 / 0.0`, `0.0 / 0.0`, `sqrt (-1)`, `log 0` | V: `Inf`, `NaN`, `NaN`, `-Inf`; `NaN == NaN` is `False` | n/a in fpr source (F64 is not in the Sol profile; Sol's own `Num` real `/` panics on zero, `VM.hs` `arithN`) | IEEE, by design | Keep IEEE for F64; document that Sol's `Num.div` refuses where F64 answers `Inf` | S (doc) | - |
| `F64.toInt NaN`, `F64.toInt 1e30` | V: `float.toInt: does not fit an Int` | n/a | no | Add `F64.toIntChecked : F64 -> Option Int`; keep the trapping form with a precondition-shaped name in its message | S | - |
| `F64.toInt (-2.7)` | V: `-2` (truncates toward zero) | n/a | by design | Document; `floor`/`round` exist in `std/math` | - | - |
| `F64.ofInt 9007199254740993` | V: round-trips to `...992` | n/a | **yes** (precision) | Keep (IEEE); add `F64.ofIntExact : Int -> Option F64` only if asked | S | - |
| `F32.ofInt 16777217` | V: `16777216` | n/a | **yes** (precision) | As F64 | S | - |
| `F32.ofF64 1e300` | V: `Inf` | n/a | IEEE | Keep | - | - |
| `7.5 % 2.0` | V: compile error `(%) is not defined for F64` | - | no | Keep | - | - |

### Strings, lists, vectors

| Operation | Native x86-64 | Sol | Silent? | Proposal | Effort | Phase |
| --- | --- | --- | --- | --- | --- | --- |
| `strlen "é"`, `charAt "é" 0` | V: `2`, `195` (bytes) | V: `1`, `233` (code points) | **yes, backends disagree** | One definition. The docs say strings are bytes (edge battery #5); Sol should follow, with code-point functions named as such (Decision 2) | M | Sol VM |
| `S.fromCodes [233]`, `[233, 8364]` | V: one byte `0xE9`; trap `chr: 8364 is not a byte ...` | V: `1` code point; `[1114112]` crashes the host (`Prelude.chr`) | **yes** | Make `fromCodes` encode UTF-8 (it is what its name and `chr`'s message promise); refuse a non-scalar code by name (`Result`) | S | - |
| `chr 256`, `chr (-1)` | V: named refusal | V: `chr 256` a one-char string; `chr (-1)` host crash `Prelude.chr: bad argument` | **Sol: yes** | Sol `chr` refuses outside 0..255 by name like native | S | Sol VM |
| `charAt "" 0`, `charAt s (-1)` | V: `charAt: index out of range (0, length 0)` | V: `SOL PANIC: charAt: index out of range` | no | Keep the trapping form with precondition `0 <= i and i < strlen s` (needs `strlen` atoms, see below); add `S.byteAt : Int -> String -> Option Int` | M | P1 + P5 |
| `xs ! 5`, `xs ! (-1)` (List) | V: `!: index out of range (5)` | V: same text, no index | no | Same as `charAt`: keep with precondition; `L.get` already answers `Option` | M | P1 + P5 |
| `substr "abc" (-1) 5`, `substr "abc" 5 2`, negative length | V: `abc`, empty, empty (clamps) | V: same | **yes** (documented clamping) | Keep as the total, clamping form, and name it so (Decision 6); add `S.slice : Int -> Int -> String -> Option String` that refuses | S | - |
| `S.dropLeft 10 "abc"`, `S.dropRight 10 "abc"` | V: empty | V: empty | clamps, total | Keep (total is reasonable here) | - | - |
| `L.take (-2)`, `L.drop (-2)` | V: `[]`, whole list | V: same | clamps, total | Keep | - | - |
| `L.head Nil`, `L.get 7`, `M.get` missing, `L.minimum` empty | V: `None` | V: `None` | no | Already the policy | - | - |
| `Vec.get 10 v` (len 3), `Vec.get (-1)` | V: `Vec.get: index out of range (10, length 3)` | not run (Vec is linear native; not in the probe) | no | Precondition with `Vec.len` atom; an `Option` read beside it | M | P1 + P5 |
| `Vec.slice 2 5 v` (len 3) | V: `Vec.slice: out of range` (no offsets in the text) | not run | no | Same; also print the offsets (`fpr_trap_range`) | S | - |
| `SStr.push` on a full 128-byte SString | D: `SStr.push: SString full (128B)` (`runtime/sstr.c`) | - | no, U | `SStr.push : ... -> Option SString`; capacity is a fixed bound, so `None` is honest | S | - |
| `parseInt "abc"`, `"12x"`, 20 nines | V: `0`, `12`, `999999999999999999` | V: `SOL PANIC: parseInt: not an integer: "abc"` | **native: yes; backends disagree** | Deprecate `parseInt` for `S.toInt` (already `Result`); keep the lenient one under a lenient name if anything needs it | S | - |
| `S.toInt "abc"`, 20 nines, `""`, `"+5"`, `" 5"` | V: `Err not a number` / `Err out of range` | V: identical | no | Keep: the model | - | - |
| print of a 5000-char interpolation | V: prints (no 4096-byte refusal reached) | V: prints | no | - | - | - |

### Memory, stack, fuel, exit

| Operation | Native x86-64 | Sol | Silent? | Proposal | Effort | Phase |
| --- | --- | --- | --- | --- | --- | --- |
| Non-tail recursion 10M deep | V: `10000000` (stack grows) | V: same | no | - | - | - |
| 100M deep under `ulimit -v 2000000` | V: `stack overflow -- no memory to grow the actor's stack by 524287 KiB` | V: `fpr: out of memory`, exit 251 (GHC RTS) | no | Keep as a typed trap; WCET/stack bounds prove it absent where declared | - | P6/P7 |
| Keep a 200M-element list under `ulimit -v 1000000` | V: `heap exhausted (no block for a slab)` after `510 MiB taken` | V: `fpr: out of memory`, exit 251 | no | Keep as a typed trap; `alloc`/`live` contracts prove it absent where declared | - | P6/P7 |
| Same, 20M with `FPR_HEAP_MB=64` | V: `heap exhausted` after `62 MiB taken` | V: ignores the variable, prints the sum | **Sol: limit ignored** | Sol honours `FPR_HEAP_MB` or refuses it by name | S | Sol VM |
| Fuel | D: preemption, not a failure (`fpr_fuel_exhausted` yields, `FUEL_QUANTUM` 2000) | D: same contract (`fuelTick`) | no | `Sys.confine` budgets kill by name (`actors.c`) | - | P6 |
| `spin n = spin (n + 0)` in a safe program | V: refused: `spin is unsafe (recursive) but has no explicit unsafe signature` (both) | V: same | no | Keep | - | - |
| Same in an `unsafe` program | V: runs for ever (killed by the 20 s probe timeout) | V: same | by design | Keep | - | - |
| `Sys.exit 300` | V: `Sys.exit: status 300 is not 0..255` | n/a on Sol (type error) | no | Precondition `(n : Int | n >= 0 and n <= 255)` | S | P1 |
| `error "boom"` | V: `[ERR] boom` + panic, exit 1 | V: `SOL PANIC: boom` | no | Keep | - | - |
| `sortWith` comparator not an `Ordering` | U: runtime text exists (`runtime.c`), unreachable from typed source | - | no | Keep as an invariant panic | - | - |
| `MutMap` key of the wrong kind | D: runtime panic `an Int-keyed map got a non-Int key` on `perf/mutmap` (reachable only through the rebinding gap) | - | no | Fix the gap; keep the panic as a backstop | - | - |

### Compiler-side gaps

| Gap | Behaviour | Silent? | Proposal | Effort | Phase |
| --- | --- | --- | --- | --- | --- |
| Rebinding in a body with no signature skips the type check | V: `v = "x" :: v` with `v : List Int` compiles and runs (both frontends) | **yes** | Check every rebinding against its new right-hand side in `Infer` | M | P2 (typed lowering needs sound types) |
| Duplicate clause | V: compiles; second clause unreachable | **yes** | Coverage pass refuses an unreachable clause, as it refuses an unreachable arm | S | - |
| Non-exhaustive `case` | V: refused (`add a catch-all arm`) | no | - | - | - |
| Heterogeneous list literal | V: refused | no | - | - | - |
| Literal-false precondition (`d 100 0`) | V: `runtime check inserted`, traps at run time | **yes (late)** | `Precond`: an obligation that evaluates to False from literals and facts is a compile error | S | P1 |
| Builtin `/` in an unannotated function | V: `runtime trap (builtin)`; the caller sees nothing | **yes (invisible)** | Decision 3 | S-M | P1 |
| Discharged precondition does not reach codegen | V: in `d : Int -> (y : Int | y != 0) -> Int`, the x86-64 code tests `y` at the boundary and then tests it again before `idivq` | no (cost) | Pass the precondition fact to `Codegen.Interval` as an entry fact; the zero test goes | S-M | P1 + P5 |
| `std/math` does not load on Sol | V: `unbound name: F64.toInt` (and the rest of the F64 functions) when imported by a Sol run | no (refused) | Split `std/math` into Int and F64 modules, or gate the F64 half by profile | S | - |

## Proposed policy

One rule per kind of failure. Each is a direction already taken somewhere in
the tree, made consistent.

1. **Absence is an `Option`, failure to convert is a `Result`.** Lookups,
   parses and "first/last/minimum" already follow this. Extend it to every
   index read by adding the `Option` form beside the trapping form
   (`S.byteAt`, `Vec.get?`-style `Vec.lookup`, `S.slice`, `F64.toIntChecked`,
   `I32.ofIntChecked`, `SStr.push`, `MutMap.fixed` insert as already decided).
   A lenient total helper that clamps (`substr`, `take`, `drop`) may stay,
   but its doc line says it clamps.
2. **Domain errors are preconditions, not traps.** Division, `%`, `^`,
   shifts, `chr`, `Sys.exit`, and index reads with the trapping form carry a
   signature predicate: `(/) : Int -> (y : Int | y != 0) -> Int`,
   `(!) : (xs : List a) -> (i : Int | i >= 0 and i < len xs) -> a`. The
   compiler:
   - discharges it from guards, case arms, own preconditions and (new) the
     interval facts, emitting nothing;
   - refuses it when it is decidably false (a literal zero divisor);
   - otherwise inserts the blamed call-site check, and **lifts the
     obligation onto the enclosing function's signature when the operand is
     one of its parameters** (Decision 3), so the requirement is visible in
     the type the caller sees and moves outward until a guard discharges it.
   This is Jack's "divide should just say `y != 0`".
3. **Overflow is checked by default** (unchanged from 2026-10-12). Wrapping
   is explicit: `I64`, `I32`, and the bit operations. If wanted, add
   `Int.checkedAdd/Sub/Mul : Int -> Int -> Option Int` for code that prefers
   `None` to a trap, and (Decision 5) `Int.wrappingAdd` etc. The checks are
   removed only by proof (interval discharge), never by a flag.
4. **Resource exhaustion stays a typed trap**: heap, stack, fuel budgets,
   ring capacities. Where a function declares `work`/`alloc`/`live` bounds
   the WCET pass proves the trap absent; elsewhere it is a named panic that
   supervision can catch. Nothing returns a default.
5. **Invariant violations stay panics** (`fpr_cpanic`): layout tables,
   scheduler states, "not the current actor's handle". They are compiler or
   runtime bugs, not program failures.
6. **Every backend gives the same answer or the same named failure.** Sol's
   interpreter, Sol's JIT and native agree on Int width, string length,
   `chr`, `parseInt` and heap limits, enforced by a differential corpus
   (the probes of this page) in P0.

### What the precondition language can express today, and what it needs

| Need | Today | Needed |
| --- | --- | --- |
| `y != 0`, `n >= 0`, `0 <= k and k < 63` | Yes (fragment: comparisons over `+ - *` of variables and literals) | - |
| `i < len xs`, `i < strlen s`, `i < Vec.len v` | No: the fragment has no function atoms. `len` exists as a measure in `size` annotations (`size map <= len xs`) and `strlen` facts exist in `Codegen.Interval` | Allow `len`/`strlen`/`Vec.len` of a parameter as an atom; discharge from guards like `i < strlen s` (Precond) and from loop induction (Interval) |
| Facts from the caller's arguments | Precond: yes for guards/literals in the caller; Interval: no (intraprocedural, noted on its page) | P1 summaries: Precond's obligations as entry facts for Interval |
| Builtin `/` blamed at the caller | No: `BuiltinTrap` falls back on the runtime trap because `/` is dispatched by operand type after Precond runs | Run the lifting after type dispatch, or type-direct the inserted comparison (P2 typed lowering gives the typed site) |
| Refuse a false obligation | No | A constant-fold of the predicate under the facts; if False, a compile error with blame |
| Visible in the type | The predicate is in the signature the programmer wrote; an inferred one is not shown | `fpr check --editor-json` reports lifted predicates as part of the inferred signature |

## Cost of overflow checking (measured, x86-64, this box)

`/workspace/out/fprisc-failure-audit/bench` (not committed): two 300M-iteration
loops, median of 5 runs after one warm-up, the box otherwise lightly loaded.
`hash`: `acc = band (acc * 31 + i) 1073741823`; `sum`: `acc = acc + i`. The C
versions are `gcc -O2`, plain and with `__builtin_*_overflow` plus the 63-bit
fit test (the shape fprisc emits). Outputs identical across all eight.

| Loop | fprisc default | fprisc `FPR_NO_INTERVAL=1` | C plain | C checked |
| --- | --- | --- | --- | --- |
| hash | 0.878 s | 1.033 s | 0.320 s | 0.423 s |
| sum | 0.374 s | 0.408 s | 0.082 s | 0.206 s |

Reading (estimates, labelled as such):

- In C the checks cost 1.32x on `hash` and 2.5x on `sum`; the `sum` figure is
  most likely lost vectorization (plain C at 0.082 s for 300M adds is 0.27 ns per iteration; the assembly was not inspected),
  not the branch itself.
- fprisc's interval discharge already removes part of its check cost: 15%
  on `hash`, 8% on `sum`. fprisc's gap to plain C (2.7x and 4.6x) is larger
  than the whole check cost in C, so the remaining gap is mostly other fixed
  costs (tagging, fuel ticks, calls), which the
  [performance priorities](2026-11-09-PERFORMANCE-PRIORITIES.md) already order.
- None of the proposals adds checks to native code: native already checks.
  Preconditions *remove* checks where discharged, and the lifted form moves a
  check outward (once per call instead of once per operation). The one added
  cost is in Sol: a JIT overflow branch per `AddI/SubI/MulI` (not measured;
  expected to be of the same order as the C row above) and 63-bit fit tests
  in the interpreter, which already pays for `Integer`.

## Order of work

| # | Item | Effort | Phase | Depends on |
| --- | --- | --- | --- | --- |
| 1 | Sol Int = native Int: 63-bit trap in the interpreter and the JIT | M | Sol VM | Decision 1 |
| 2 | Differential failure corpus (this page's probes) native vs Sol in CI | S | P0 | 1 |
| 3 | Rebinding type-check gap | M | P2 | - |
| 4 | Refuse literal-false preconditions and literal zero divisors | S | P1 | - |
| 5 | Sol strings follow the byte definition; `fromCodes` encodes UTF-8; Sol `chr` refuses by name | M | Sol VM / std | Decision 2 |
| 6 | Duplicate clause refused | S | - | - |
| 7 | Lift undischarged builtin and parameter preconditions onto signatures; report them in `--editor-json` | M | P1 (+P2 typed sites) | Decision 3 |
| 8 | `Option` forms beside trapping index/convert operations; preconditions on `^`, shifts, `chr`, `Sys.exit`, `powInt` | S-M | std + P1 | Decision 4 |
| 9 | `len`/`strlen`/`Vec.len` atoms in the predicate fragment; Precond facts as Interval entry facts (drops duplicate zero tests and index checks) | L | P1 + P5 | 7 |
| 10 | `parseInt` deprecated for `S.toInt`; `%` naming | S | std | Decision 6 |
| 11 | Sol honours `FPR_HEAP_MB`; `std/math` loads on Sol | S | Sol VM / std | - |
| 12 | `intovf.fpr` under QEMU A64/RV64 where CI has it | S | P0 | - |

## Decisions for Jack

1. **Sol Int width.** Trap at 63 bits like native (recommended: one
   language), or keep Sol exact (then Sol and native disagree by design, and
   the JIT still has to stop wrapping).
2. **What a string's length is.** Bytes everywhere (recommended: the
   documented definition and native's), with named code-point functions; or
   code points everywhere (native cost: UTF-8 scans for `strlen`/`charAt`).
3. **Undischarged builtin preconditions.** (a) Lift them onto the
   enclosing signature as inferred predicates, shown by the editor
   (recommended); (b) warn; (c) refuse in safe code unless written.
4. **Index reads.** Keep `!`/`charAt`/`Vec.get` trapping with
   preconditions and add `Option` siblings (recommended), or make the
   `Option` form the default name.
5. **Explicit overflow operations on Int.** `Int.checkedAdd -> Option`
   (cheap, recommended), and/or `Int.wrappingAdd` (the 2026-10-12 page says
   none is planned: "I64 is the type that wraps").
6. **Lenient helpers.** Keep `substr`/`take`/`drop` clamping as documented
   total functions (recommended), deprecate `parseInt`, and choose whether
   `%` is truncating `rem` (today) or floored `mod` like `Math.mod`.

## Evidence

Probe harness and raw results: `/workspace/out/fprisc-failure-audit/`
(`probe.py`, `cases_int.json`, `cases_more.json`, `*.results.jsonl`, sources
in `p/`), built with this tree's `fpr`. Every probe is one file: a shared
header (`big`, `small`, `zero`, `one` helpers to defeat constant folding,
std imports as used) and one `main`. Native runs record exit status, stdout
and stderr; Sol runs the same file with `fpr sol`. The two precondition
probes:

```
profile base.
d : Int -> (y : Int | y != 0) -> Int .
d x y = x / y.
main = print "{d 100 0}".
```

```
profile base.
d : Int -> (y : Int | y != 0) -> Int .
d x y = x / y.
safe : Int -> Int .
safe y = case y != 0 of True -> d 100 y | False -> 0.
main = print "{safe 0} {safe 5}".
```

The first reports `main -> d requires (y != 0): runtime check inserted` and
traps; the second reports both obligations `discharged statically` and prints
`0 20`.
