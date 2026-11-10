# Failure modes: what traps, what overflows, what is silently wrong

Date: 2026-11-10 (revised the same day with Jack's decisions, then again the
same day with D6–D12, the answers to the seven remaining questions; D6–D12
are decided, and open to review or replacement). Kind: audit, decisions and
proposal. Applies to `540ba57` (main after
PR #59). Every behaviour marked **verified** was run on this date: native is
`fpr build` for the posix system on x86-64 Linux, Sol is `fpr sol` on the same
file. A64 and RV64 were **not executed** (no QEMU on the audit machine); where
this page says something about them it cites the existing record and says so.

This page answers one question: where does a program fail abruptly, and where
does it fail *silently* (a wrong value, a clamp, a default, or two backends
disagreeing)? It then proposes one policy for each kind of failure: return
`Option`/`Result`, a precondition in the signature (discharged statically where
possible), an exact result where the first draft had an overflow, or a typed
trap that stays.

## Jack's decisions (2026-11-10)

Recorded from Jack's review of the first draft of this page, 2026-11-10:

> Is it possible to just make Int get checked rather than trap. Or something
> elegant rather than what we have now. I64 is also meant to be the actual
> type for high performance computing so maybe it might be fine to sacrifice
> some of `Int`'s efficiency if it means just simpler and safer execution.
> Strings should be bytes everywhere yes, should be something like Array Byte
> rather than List Char. Index should not trap actually, I think it should
> either return Option or have a precondition instead. No extra checkedAdds or
> wrappingAdds and % should be the real modulo operation - can just change it
> so it actually is

| # | Decision | Status | Section |
| --- | --- | --- | --- |
| D1 | `Int` should neither trap nor fail silently; some `Int` speed may be given up for that. `I64` (and `I32`) are the fixed-width types for high-performance code | **Decided** (direction); mechanism confirmed as D6 | [Int: never wraps, never traps](#int-never-wraps-never-traps), [D6](#d6-exact-int) |
| D2 | Strings are bytes everywhere: a byte array, not a list of characters | **Decided**; D10 splits this into `String` (valid UTF-8) and `Bytes` (any bytes) | [Strings are byte arrays](#strings-are-byte-arrays), [D10](#d10-two-types-bytes-and-string) |
| D3 | Indexing never traps: each index operation returns `Option` or takes a precondition | **Decided** | [Indexing without traps](#indexing-without-traps) |
| D4 | No `Int.checkedAdd` / `Int.wrappingAdd` family | **Decided**; removed from this proposal | - |
| D5 | `%` is the true (floored) modulo, as `Math.mod` is | **Decided**; D8 makes `/` floored too so the identity holds; D9 applies both symbols to `I64`/`I32` | [`%` is floored modulo, `/` is floored division](#-is-floored-modulo--is-floored-division), [D8](#d8--is-floored-division), [D9](#d9--and--on-i64i32-are-floored-too) |
| D6 | `Int` is mathematically exact: never overflows, never wraps, never traps on arithmetic. Small values stay in the tagged 63-bit word (31-bit on RV32) and promote to a heap bignum otherwise. Bounded and no-heap code must prove every `Int` stays small or use `I64`/`I32` | **Decided, open to review/replacement** (2026-11-10) | [D6](#d6-exact-int) |
| D7 | `I32.ofInt` / `I64.ofInt` return `Option` (`None` out of range). No implicit wrapping conversion | **Decided, open to review/replacement** (2026-11-10) | [D7](#d7-i32ofint--i64ofint-return-option) |
| D8 | `/` is floored division; `Math.quot` / `Math.rem` are the truncated pair; the identity `a == (a / b) * b + a % b` always holds | **Decided, open to review/replacement** (2026-11-10) | [D8](#d8--is-floored-division) |
| D9 | `%` and `/` on `I64`/`I32` are floored too (same symbol, same meaning). `I64.quot`/`I64.rem` and `I32.quot`/`I32.rem` are the hardware truncated results. `min / -1` keeps the existing named panic | **Decided, open to review/replacement** (2026-11-10) | [D9](#d9--and--on-i64i32-are-floored-too) |
| D10 | Two explicit types: `Bytes` (immutable `Array Byte`, any bytes) and `String` (immutable byte array, guaranteed valid UTF-8). Length and indexing are in bytes. I/O yields `Bytes` | **Decided, open to review/replacement** (2026-11-10) | [D10](#d10-two-types-bytes-and-string) |
| D11 | Rename in one change; no deprecated aliases. Old names become compile errors that name the replacement | **Decided, open to review/replacement** (2026-11-10) | [D11](#d11-rename-in-one-change-no-deprecated-aliases) |
| D12 | Calculator: `Rem` is truncated remainder (`Math.rem`); add a separate `Mod` that is floored (`%`). Each name means exactly one thing | **Decided, open to review/replacement** (2026-11-10) | [D12](#d12-calculator-rem-is-truncated-mod-is-floored) |

**Naming rule.** Each operator or function name denotes one semantics across
all numeric types (`Int`, `I64`, `I32`) and all backends. Alternative
semantics get their own name (`Math.quot`/`Math.rem`, `I64.quot`/`I64.rem`,
`I32.quot`/`I32.rem`, calculator `Rem` vs `Mod`).

Where the first draft below (the table, the silent-failure list) says
otherwise, these decisions and the sections that implement them win. The
table cells that say "Decision N" refer to the first draft's questions,
which this revision answers:

1. Sol Int width: answered by D1 and D6 (exact everywhere, not a 63-bit trap).
2. String length: answered by D2 and D10 (bytes, on both `String` and `Bytes`).
3. Undischarged builtin preconditions: lifted onto the signature. This is
   still the recommendation and is now part of D3: where lifting stops, the
   program is refused, and no runtime check is inserted.
4. Index reads: answered by D3 (no trapping form).
5. Explicit overflow operations: answered by D4 (none).
6. Lenient helpers: `%` is answered by D5 and D8. `substr`/`take`/`drop` stay
   clamping and documented. `parseInt` is deprecated (work item 16).

The seven remaining questions of the previous revision are answered as
[D6–D12](#decisions-d6d12-2026-11-10-expected-semantics).

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
| `intMax + 1`, `intMin - 1`, `*` past 63 bits | V: named trap `Int overflow: a + b does not fit an Int (...)`, exit 1 | V: exact bignum, exit 0 (interpreter); V: wraps at 2^64 in a JIT `foldl` | **Sol: yes** | **Revised (D1):** exact `Int` everywhere; native promotes to a bignum, the Sol interpreter already agrees, the Sol JIT re-runs in the interpreter on overflow ([Int section](#int-never-wraps-never-traps)) | L | runtime + backend; Sol VM; P0 corpus |
| `intMin / (-1)`, `0 - intMin`, `Math.abs intMin` | V: named overflow trap | V: exact bignum (`abs` not run: `std/math` does not load on Sol, see below) | **Sol: yes** | As above | with above | - |
| `2 ^ 63` | V: overflow trap (from the squaring `*`) | V: `9223372036854775808` | **Sol: yes** | As above | with above | - |
| `x ^ n`, `n < 0` | V: `(^): negative exponent` | V: same, plus a hint | no | Precondition `(n : Int | n >= 0)` on `intPow` so it is discharged or blamed at the caller | S | P1 (caller facts) |
| `Math.powInt a n`, `n < 0` | V: answers `0` | not run (std/math needs F64) | **yes** | Same precondition as `^`, or `Option Int` | S | - |
| `x / 0`, `x % 0` (Int) | V: `division by zero`, exit 1 (literal `7 / 0` too) | V: `SOL PANIC: division by zero` | no | **Decided (D8):** `/` and `%` carry `(b : Int \| b != 0)`. Undischarged obligations are lifted onto the signature (Decision 3); a literal zero divisor is a compile error | S-M | P1 |
| `Math.mod 7 0` (has `(b : Int | b != 0)`) | V: `precondition violated: mod@... requires (b != 0), got b=0 (in main)` | not run (std/math) | no | Already the target style; refuse the literal case at compile time | S | P1 |
| `(0 - 7) % 2`, `(0 - 7) / 2` | V: `%` is `-1` (`Int.mod` truncates: the sign of the dividend); `Math.mod` gives `1`, `Math.rem` `-1`. `/` is `-3` (truncates toward zero) | not run for `Math.*` | surprising, documented in code | **Decided (D5, D8):** `%` is floored (`-7 % 2 == 1`); `/` is floored (`-7 / 2 == -4`); `Math.quot -7 2 == -3`, `Math.rem -7 2 == -1`. Identity `a == (a / b) * b + a % b` holds ([`%` / `/` section](#-is-floored-modulo--is-floored-division)) | S | std + backend |
| `BITSHIFTL 1 62` | V: `-4611686018427387904` | not available on Sol (type error) | by design (bit ops act on the 63-bit word) | Keep; say so in the `band`/`BITSHIFTL` docs | S | - |
| `BITSHIFTL 1 63` | V: `0` | n/a | yes, but the panic text for `-1` says "shift must be 0..63" | With exact `Int` (D1) `BITSHIFTL 1 63` is `2^63`; the only precondition left is `k >= 0` | with D1 | - |
| `BITSHIFTL 1 (-1)` | V: `BITSHIFTL: shift must be 0..63` | n/a | no | Precondition `(k : Int | k >= 0 and k < 63)` so it can be discharged | S | P1 |
| `I64` `*` past 64 bits | V: wraps (`-4`) | n/a | by design | Keep (I64's contract) | - | - |
| `I64 / 0`, `I32 / 0` | V: `I64: division by zero`, `I32: division by zero` | n/a | no | **Decided (D9):** same `b != 0` precondition as `Int` | S | P1 |
| `I64.min / -1`, `I32.min / -1` | D: named panic `I64: division overflow (INT64_MIN / -1)`, `I32: division overflow (INT32_MIN / -1)` ([I64](2026-10-05-I64.md), [I32](2026-10-18-I32.md)); the corresponding remainder is 0 | n/a | no | **Decided (D9):** keep this existing panic, for both floored `/` and `I64.quot`/`I32.quot`. `%` and `rem` of `min` and `-1` are `0`. (Wrapping to `I64.min` / `I32.min` would also match ARM/RISC-V `sdiv`; this page does not change the documented trap.) | - | - |
| `I64` `%` / `/` of ordinary negative values | D: `/` truncates, `%` has the dividend's sign ([I64](2026-10-05-I64.md), [I32](2026-10-18-I32.md)) | n/a | surprising relative to `Int` after D5/D8 | **Decided (D9):** `/` and `%` are floored on `I64`/`I32` too (`(-7 : I64) / 2 == -4`, `(-7 : I64) % 2 == 1`). `I64.quot`/`I64.rem` and `I32.quot`/`I32.rem` keep the hardware truncated results | S | std + backend |
| `I64.toInt` too big | V: `Err I64.toInt: does not fit an Int (63 bits)` | n/a | no | With exact `Int` (D6) this becomes total: every `I64`/`I32` value is an `Int` (a value past 63 bits is a bignum). Today's `Result` form goes away | with D6 | - |
| `I32.ofInt intMax`, `I64.ofInt` of a value past 64 bits | V: `I32.ofInt intMax` is `-1` (low 32 bits); today every `Int` fits `I64.ofInt` | n/a | **yes, by design** (MEMORY-I32 page) | **Decided (D7):** `I32.ofInt : Int -> Option I32`, `I64.ofInt : Int -> Option I64`; `None` out of range (`I32.ofInt 2147483648 == None`; today's `intMax` case becomes `None`). No implicit wrapping | S | - |
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
| `strlen "é"`, `charAt "é" 0` | V: `2`, `195` (bytes) | V: `1`, `233` (code points) | **yes, backends disagree** | **Decided (D2, D10, D11):** length and indexing are in bytes on both `String` and `Bytes`, on every backend (`strlen "é" == 2`, `String.byteAt "é" 0` is `195`). `charAt` is removed (compile error naming `String.byteAt` or `String.codes`). `String.codes "é" == [233]` | M | Sol VM + std |
| `S.fromCodes [233]`, `[233, 8364]` | V: one byte `0xE9`; trap `chr: 8364 is not a byte ...` | V: `1` code point; `[1114112]` crashes the host (`Prelude.chr`) | **yes** | **Decided (D10):** `String.fromCodes : List Int -> Option String` encodes UTF-8 (`String.fromCodes [233]` is `Some "é"`). `None` if any value is not a Unicode scalar (`[1114112]`, `[-1]`, `[0xD800]`). `String.fromBytes` of a lone `0xE9` is `None` (invalid UTF-8 cannot inhabit `String`) | S | - |
| `chr 256`, `chr (-1)` | V: named refusal | V: `chr 256` a one-char string; `chr (-1)` host crash `Prelude.chr: bad argument` | **Sol: yes** | `chr` returns a `Byte` (not a `String`: a lone `0xE9` is not valid UTF-8), with precondition `0 <= n and n < 256`. Sol refuses outside that range by name, like native, and no longer crashes the host | S | Sol VM |
| `charAt "" 0`, `charAt s (-1)` | V: `charAt: index out of range (0, length 0)` | V: `SOL PANIC: charAt: index out of range` | no | **Decided (D3, D11):** `charAt` is removed. `String.byteAt` and `Bytes.byteAt` come in a precondition form (`0 <= i and i < length`) and an `Option` form; neither traps ([Indexing without traps](#indexing-without-traps)) | M | P1 + P5 |
| `xs ! 5`, `xs ! (-1)` (List) | V: `!: index out of range (5)` | V: same text, no index | no | **Decided (D3):** no trapping form. Precondition `0 <= i and i < len xs`, and `L.get` already answers `Option` | M | P1 + P5 |
| `substr "abc" (-1) 5`, `substr "abc" 5 2`, negative length | V: `abc`, empty, empty (clamps) | V: same | **yes** (documented clamping) | Keep as the total, clamping form, and name it so; add `S.slice : Int -> Int -> String -> Option String` that refuses | S | - |
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

## Int: never wraps, never traps

### Options considered

| Option | What `big + 1` does | Elegance in FP style | Safety | WCET | Native cost | Sol | RV32 / QOS |
| --- | --- | --- | --- | --- | --- | --- | --- |
| (a) **Arbitrary precision with a small-int fast path**: the tagged 63-bit word (31 on RV32) as today; on overflow the result is a heap bignum (Lisp fixnum/bignum, Haskell `Integer`, Python `int`) | `4611686018427387904`, exact | Best: `Int` means integer; no new operators, no `Option` plumbing, no annotations | Overflow cannot happen; the only failure left is running out of memory, already a typed trap | Fixed cost where intervals prove the fit (most loop counters, indices, lengths); elsewhere cost grows with limbs, so bounded code must prove a size bound (below) | Fast path keeps `add` + overflow branch; adds an operand tag test where the operand is not known small (measured below) | The interpreter is already exact (`VInt !Integer`): Sol and native agree for free. The JIT needs one change: overflow re-runs the kernel in the interpreter | Small runtime (estimate below); allocating Ints are refused in no-heap units unless proven small |
| (b) `+ - *` return `Option Int` | `None` | Poor: every arithmetic expression becomes a `case` or a monadic chain; `D4` rejects the named-function version of this already | Total, but pushes the failure to every caller | Fixed cost | One branch, plus `Option` boxing unless P3 unboxes it | Needs the same change in both | Fits |
| (c) Range-typed `Int`: every arithmetic result must be proven in range, or the function states a precondition | Compile error unless proven | Precise, but annotation-heavy for application code: accumulators, sums and products of inputs have no static bound, so their signatures fill up with ranges | No runtime failure | Fixed cost | No checks at all | Same checker | Fits |
| (d) Saturating | `intMax` | Simple to state | **Silent wrong answer**, the thing this page exists to remove | Fixed cost | `add` + `cmov` | Change both | Fits |
| (status quo) Trap at 63 bits | named panic | - | Abrupt failure | Fixed cost | `add` + overflow branch | Interpreter disagrees, JIT wraps | Fits |

**Decided (D6): (a), with (c) used where it pays: inside code that declares
WCET bounds, and as the compiler's way of choosing the fast path everywhere.**
`Int` is the mathematical integer: it never overflows, never wraps, and never
traps on arithmetic. The compiler proves "this value fits a
fixnum" wherever it can (the interval facts it already has, plus the length
atoms of D3) and emits exactly today's code there, with no check at all. Where
it cannot prove that, it emits the fast path with a slow path that promotes,
in place of today's slow path that panics. In code with declared
`work`/`alloc`/`live` bounds, and in no-heap units, an Int whose size is not
bounded is a compile error that names the variable and the unproven range. The
fix is a guard, a precondition such as `(n : Int | n < 1000000)`, or `I64`.
That is (c) exactly where WCET needs it and nowhere else. `I64` and `I32` stay
fixed width and wrapping: they are the HPC types, as D1 says. Expected
semantics, including the examples that every backend must agree on, are in
[D6](#d6-exact-int).

Why not (b) or (c) alone: (b) puts failure handling into every arithmetic
expression, and D4 already says no to that family. (c) alone makes ordinary
application code (a running total, a product of two inputs, a parsed number)
need annotations it cannot sensibly have. (d) is silent.

### What changes

- **Runtime**: a bignum object (sign, limb count, limbs; no pointers, so
  region copy-out and message copy are a `memcpy`), and the slow paths of
  `+ - * / %`, comparison, equality, hashing (`MutMap` Int keys, so Sol and
  native must hash bignums the same way), `str`, `S.toInt`, `wireInt`, JSON
  integers, and the bit operations (`band`/`bor`/`bxor`/shifts on
  two's-complement integers of any size, as in Python). The C primitives
  `fpr_prim_fn_+` and the others already are the slow path. They return a
  bignum instead of panicking.
- **Codegen**: the inline fast path keeps `(a0 - 1) + a1` with its overflow
  branch. It also tests `a0 & a1 & 1` when either operand is not known to be
  a fixnum. Comparisons get the same tag test. `*` keeps its 31-bit inline
  rule. P5's "untagged loop Ints" (performance priority #10) applies only to
  Ints proven to fit, which it already needs for the trap.
- **Vectors**: `VR_INT` columns hold fixnums. A bignum stored into one turns
  the column boxed (the representation change that `VR_UNSET -> VR_BOX` is
  already). The unboxed kernels (`genU`, NEON lanes) leave on overflow to the
  scalar path instead of panicking.
- **Things that stop failing**: `intMax + 1`, `abs intMin`, `intMin / -1`,
  `2 ^ 63`, `BITSHIFTL 1 63`, `S.toInt` of 20 digits (`Err out of range`
  goes away), `parseInt` stopping at the digit that would overflow, and
  `I64.toInt` (now total). `intMax Unit` / `intMin Unit` become the fixnum
  bounds, which are a cost fact and not a semantic limit. They are used in 48
  places (17 in std). Most of them are parse bounds that go away.
- **Conversions down (D7):** `I64.ofInt : Int -> Option I64` and
  `I32.ofInt : Int -> Option I32`. `None` when the value is out of range
  (for example `I32.ofInt 2147483648 == None`; today's `I32.ofInt intMax`,
  which is silently `-1`, becomes `None`). No implicit wrapping conversion.
  Bit reinterpretation, if ever needed, would be a separately named explicit
  operation and is not added now. The other direction, `I64.toInt` /
  `I32.toInt`, becomes total once `Int` is exact, because every `I64`/`I32`
  value is an `Int`. Details and examples: [D7](#d7-i32ofint--i64ofint-return-option).
- **Sol**: the interpreter changes nothing for `+ - *`. The JIT
  (`AsmX64`/`AsmA64`: `AddI`/`SubI`/`MulI` are plain `add`/`imul` today)
  gets an overflow branch to a third fuel-cell poison value, after the
  existing `fuelPoison` for division by zero. `withFuelCell` answers it by
  re-running the scheme in the interpreter, so the JIT result never differs.
  Re-running is sound only for the schemes that cannot perform effects,
  which are the numeric `foldl`/`map`/`filter` schemes the JIT accepts; that
  has to be checked when this is implemented.

### WCET: how a contract bounds a bignum

- **Proven small (the common case)**: the cost is today's unit cost. Interval
  discharge already proves `i + 1` under `i < n`. Its facts (loop induction,
  `strlen >= 0`, guards) and the D3 length atoms cover counters, indices,
  lengths and offsets.
- **Bounded but large**: a precondition or guard such as `x < 10^30` gives a
  limb count. The cost language prices `+`/`-` as `c * limbs` and `*` as
  `c * limbs(a) * limbs(b)`, a measure of the same shape as `len` in `size`
  annotations. `Cost.hs` prices `+` as `unit` today, which stays the
  proven-fixnum case.
- **Unbounded, in bounded code**: refused at compile time with blame (for
  example "`acc` in `sumAll` has no size bound; `sumAll` declares
  `work <= ...`").
- **Unbounded, in unbounded code** (no declared bounds): allowed, and costed
  by the region/alloc accounting like any other allocation.

The rule Jack can state in one line: *Int is exact; code with a time bound
has to show that its Ints are small.*

### Measured: C model of the fast path (x86-64, this box)

`/workspace/out/fprisc-failure-audit/intproto/proto.c` (not committed) is a C
model of fprisc's tagged word (`2x+1`). It compares today's trap with
promotion to a minimal bump-allocated bignum, on the same two loops as the
[overflow-cost table](#cost-of-overflow-checking-measured-x86-64-this-box) below. Each figure is the median over 5 to 7 timed runs,
in three separate runs of the harness. The box had load averages of 8 to 22
from other work while this ran, so treat the ranges as noisy. All variants
printed identical results. The promoted `sum` loop to 3.1e9 crosses into
bignums partway and prints the exact `4804999998450000000`.

| Loop (300M iterations) | trap (today's shape) | promote, no proofs | promote, loop versioned | proven fixnum (no check) |
| --- | --- | --- | --- | --- |
| hash (`*` then `+` then `band`) | 0.47-0.64 s | 0.39-0.54 s | 0.48 s | 0.32-0.38 s |
| sum (`acc + i`) | 0.12-0.17 s | 0.25-0.38 s | 0.13 s | 0.17-0.23 s (only `i` proven) |

"Loop versioned" runs a fixnum-only loop with just `add` and the overflow
branch, and continues in the generic loop at the first overflow. The
compiler can do this for any loop whose state starts small, because a value
only becomes a bignum through that branch.

Reading (the fprisc figures are **estimates** from the model, not
measurements of fprisc):

- Where the fit is proven, promotion and trap compile to the same code. That
  is the "proven" column, and it is where interval discharge already
  operates.
- Unproven, a `*`-bound loop shows no difference beyond noise. A tight
  `+`-bound loop pays about 2.1-2.3x in the model, or about 0.5-0.7 ns per
  iteration, for the operand tag tests. Applied to fprisc's measured `sum`
  (0.374 s), that is an estimated +0.15-0.21 s if nothing were proven. With
  `i` proven, as interval discharge does today, the estimate is +0.04-0.06 s
  (about 1.1-1.2x).
- With loop versioning the model matches the trap within noise
  (0.127 s against 0.121 s). Versioning is a P5 pass, so this page counts on
  it for the long-term cost but not for the first slice.
- The bignum regime itself: the Sol overflow probe's loop
  (`acc + i * 10^15`, 10M iterations, two bignum operations each) ran in
  0.42-0.58 s, about 21-29 ns per bignum operation including a bump
  allocation, with no GC. It allocated 170 MB in the model. In fprisc those
  are short-lived leaf objects, so they add to the reclamation problem
  ([performance priorities](2026-11-09-PERFORMANCE-PRIORITIES.md) #2) in
  loops that really are large. The trap answered no number at all there.

### Size on small targets (estimate)

The model's add, subtract, small multiply, compare and normalise compile to
about 0.8 KB of x86-64 text at `-Os`. A complete runtime adds schoolbook
multiply, division with remainder, shifts, the bit operations, decimal
conversion both ways, and hashing. **Estimate: 3-5 KB on RV32 at `-Os`**
(not built: the box has no RISC-V toolchain). On RV32 the fixnum is 31 bits,
so values past about ±1.07e9 promote. Millisecond timestamps and byte
counters reach that. Today they trap there. With this design they promote
in hosted code and are refused at compile time in no-heap units (`--raw`,
the virt PLIC/CLINT units, whose `$arc.add` adapters allocate nothing). QOS
code that wants 32 or 64 wrapping bits should say `I32`/`I64`.

## Strings are byte arrays

Native already stores text as bytes: `str_t` is `{tid, var, len, bytes[]}`
(`runtime/fpr.h`). `strlen` is the byte length, `charAt` reads a byte, and
`std/binary` already uses `String` as a byte buffer (`B.u8 : Int -> String ->
Option Int`). The "list of characters" is Sol's representation:
`VString String Int (Array Int Char)` (`compiler/Sol/Val.hs`) is a Haskell
`String` (a list of code points) with a lazily built code-point array. That
is why `strlen "é"` is 2 natively and 1 on Sol.

**D10 supersedes the earlier one-type recommendation** (one `String` that
may hold any bytes, UTF-8 by convention). The reasoning: invalid text
cannot masquerade as `String`. D2 still holds: length and indexing are in
bytes, on every backend. Expected signatures, conversions and examples are
in [D10](#d10-two-types-bytes-and-string). Rename policy: [D11](#d11-rename-in-one-change-no-deprecated-aliases).

Design:

- **Two explicit types.** `Bytes` is an immutable `Array Byte` and may
  hold any bytes. `String` is an immutable byte array that is guaranteed
  valid UTF-8. `String.toBytes : String -> Bytes` is zero-copy.
  `String.fromBytes : Bytes -> Option String` is `None` if the bytes are
  not valid UTF-8.
- **Literals and I/O.** `"..."` literals and `"{...}"` interpolations are
  `String` (hence valid UTF-8). I/O that reads files or sockets yields
  `Bytes`; decoding to text is an explicit `String.fromBytes` (or a named
  helper built on it). Writing text is an explicit `String.toBytes`.
- **`std/binary`, `wire`, `mqtt` and `fat`** use `Bytes` for binary
  buffers, not `String`. That is why those modules no longer need a
  `String` that can hold arbitrary bytes.
- **std renames and additions** (one change, no deprecated aliases, D11):
  - `S.length`/`strlen` on `String`, and the corresponding length on
    `Bytes`: bytes (unchanged natively).
  - `charAt` is removed. A use of it is a compile error:
    `charAt was removed: use String.byteAt (bytes) or String.codes (code points)`.
    `String.byteAt` and `Bytes.byteAt` each come in two forms, per D3: the
    precondition form `byteAt : (s : String) -> (i : Int | 0 <= i and i <
    strlen s) -> Int`, and `byteAt? : Int -> String -> Option Int`, which
    is today's `B.u8` on `String`. 186 `charAt` call sites in
    std/examples/tests (211 in the repo, 53 files).
  - The old `codes` (bytes on native, code points on Sol) is removed. A
    use of it is a compile error naming the replacement (`String.bytes` /
    `String.toBytes` for bytes, `String.codes` for code points). Existing
    call sites do not silently change meaning. `String.codes : String ->
    List Int` is code points only, from this change onward. 22 old `codes`
    sites.
  - `String.fromCodes : List Int -> Option String` encodes UTF-8 and is
    `None` if any value is not a Unicode scalar (a surrogate, a negative
    value, or a value above `0x10FFFF`). It can become a precondition form
    `(cs : List Int | all valid scalars)` once the precondition language
    has quantifiers. Native today panics above 255, and Sol crashes in the
    host on `chr (-1)`. 4 sites.
  - `chr` returns a `Byte`, not a `String` (a lone `0xE9` is not valid
    UTF-8 and must not inhabit `String`), with the precondition
    `0 <= n and n < 256` (124 sites, mostly literal or masked arguments
    that discharge statically).
  - New UTF-8 helpers live on `String`: `String.decodeAt : Int -> String
    -> Option (Int, Int)` (code point and width at a byte offset),
    `String.codePointCount`. `Bytes.isUtf8 : Bytes -> Bool` is the check
    behind `String.fromBytes`. A valid `String` does not need `isUtf8`.
  - `String.reverse` reverses code points (today's `S.reverse` reverses
    bytes, which breaks multi-byte text; no call sites outside std).
    `toUpper`/`toLower` stay ASCII, as documented.
  - `substr` keeps its clamping behaviour (a documented total function).
    `S.slice` is its refusing form: precondition or `Option`, per D3.
- **Sol parity**: `VString` becomes a strict `ByteString` holding
  validated UTF-8; `Bytes` is the `VBytes` Sol already has. That makes
  `strlen` and `byteAt` O(1) on Sol with no lazy code-point array. 124
  `VStr`/`VString` uses in `compiler/Sol` (100 in `VM.hs`) need review.
  Most are construct or match through the pattern synonym, so the change
  is mostly in `Val.hs`/`VM.hs`'s string primitives (estimate M).
- **Link to performance priority #12 (string slices).** A slice is the same
  representation plus an offset: `{tid, var, len, off, buf}` or a tagged
  view variant. Deciding that both `String` and `Bytes` are byte arrays
  now settles what a slice slices. If #12's investigation favours slices,
  the byte-array change should add the view variant to the `str_t` tag at
  the same time, so `split`/`lines`/`words` do not need a second
  migration. The copy-out rule #12 asks for becomes "copy-out and message
  copy compact a view to its own bytes". A `String` slice stays valid
  UTF-8 only if it is cut at a code-point boundary; otherwise the result
  is `Bytes` (or `None` from the `Option` form). Bytes everywhere is a
  prerequisite for #12, not a competitor.

## Indexing without traps

Every index operation gets one of two forms, and no form traps:

- **Precondition form**: the operation is total on its stated domain. The
  compiler discharges the obligation (guards, case arms, interval and loop
  induction facts, the caller's own preconditions). Otherwise it lifts the
  obligation onto the enclosing function's signature (first draft,
  Decision 3). Where it cannot lift any further (`main`, an actor body, a
  callback), it is a compile error that offers the `Option` form or a guard.
  **No runtime check is ever inserted for these.**
- **`Option` form**: answers `None` out of range. For a linear structure it
  hands the structure back, as `FixedMap` insert does:
  `(Option a, Vector 1 a)`.

| Operation | Precondition form | `Option` form | Sites (std/examples/tests) |
| --- | --- | --- | --- |
| `charAt` -> `String.byteAt` | `0 <= i and i < strlen s` | `String.byteAt?` (today's `B.u8`) | 186 |
| `Bytes.byteAt` (new) | `0 <= i and i < length b` | `Bytes.byteAt?` | new |
| `xs ! i` (List) | `0 <= i and i < len xs` | `L.get` (exists) | 3 (Sol: 29) |
| `Vec.get` | `0 <= i and i < Vec.len v` | `Vec.get? : Int -> Vector 1 a -> (Option a, Vector 1 a)` | 50 |
| `Vec.set` | same | `Vec.set? -> (Bool, Vector 1 a)` | 5 |
| `Vec.slice off n` | `0 <= off and 0 <= n and off + n <= Vec.len v` | `Vec.slice?` | 0 |
| `Vec.burst` | `0 <= off and off + len s <= len d` | `Vec.burst?` | - |
| `S.slice` (new) | `0 <= a and a <= b and b <= strlen s` | `S.slice?` | new |
| `SStr.at`, `SStr.put` | `i < SStr.len s` / `i < 128` | `SStr.at?` | (tangnano tests) |
| `SStr.push` | none: capacity is runtime state | `Option` only, as `FixedMap` | (tangnano tests) |

`take`/`drop`/`substr` stay total and clamping. That is documented, so it
is not silent.

**Until the length atoms exist.** The predicate fragment has no `len`,
`strlen` or `Vec.len` atoms yet (table above; P1 + P5). Order:

1. **Now**: add every `Option` form, and migrate std code that already
   guards before it reads (the `B.u8` pattern) to the `Option` form or to
   the guarded read. The trapping forms stay working but warn ("unproven
   index; use `byteAt?` or a guard"), counted by `fpr check`.
2. **When P1 adds length atoms and passes Precond facts to Interval**: the
   trapping forms become the precondition forms. A call site that cannot be
   discharged or lifted becomes a compile error, and the runtime range
   checks are deleted. This step changes what compiles, so it waits for the
   warning count from step 1 to reach zero in std, examples and tests.

So in the meantime the `Option` form is the only one that never traps.
Nothing becomes silent at any step.

## `%` is floored modulo, `/` is floored division

`%` on `Int` is `Int.mod` in `core/prelude.fpr`, defined as
`a - (a / b) * b` (truncated). It gives `-7 % 3 = -1` and `7 % -3 = 1` on
both native and Sol (verified today, `p2/mod.fpr`). `/` truncates too
(`-7 / 2 = -3`). Change, now decided as D5, D8 and D9 (examples and
signatures: [D8](#d8--is-floored-division), [D9](#d9--and--on-i64i32-are-floored-too)):

- **`/` is floored**: `a / b = floor(a/b)`, with the precondition
  `(b : Int | b != 0)`. So `-7 / 2 == -4` and `7 / -2 == -4`.
- **`%` is floored** (D5): `Int.mod` becomes `Math.mod`'s definition,
  `r = a - (a / b) * b; if r != 0 and ((r < 0) != (b < 0)) then r + b else
  r`, with the same `b != 0` precondition. The remainder takes the sign of
  the divisor: `-7 % 2 == 1`, `7 % -2 == -1`. Sol's `Int.mod` (the
  `Preamble.hs` struct) gets the same definition.
- **The identity** `a == (a / b) * b + a % b` always holds (when `b != 0`).
- **Truncated pair, under their own names** (naming rule):
  `Math.quot` is the truncated quotient, `Math.rem` is the truncated
  remainder. Identity: `a == Math.quot a b * b + Math.rem a b`.
  `Math.quot -7 2 == -3`, `Math.rem -7 2 == -1`.
- **Codegen**: x86-64 `idiv`, A64 `sdiv`+`msub` and RV64 `div`/`rem` all
  give the truncated pair. The floored result adds one fix-up on each of
  `/` and `%` (`test r`; `xor` the signs; conditional `add b` on the
  remainder and `sub 1` on the quotient), about 3-4 instructions next to a
  20-40+ cycle divide. That is an estimate, not measured. With a positive
  constant divisor it is cheaper than today, because floored `x % 2^k` is
  `band x (2^k - 1)` with no sign fix-up, and the interval facts already
  know when `b > 0`.
- **Call sites** (58 `%` sites in std/examples/tests, 100 in the repo
  including Sol). Almost all have a non-negative dividend (time, counters,
  hex digits, LCGs on non-negative state) or test `% k == 0`, which does
  not change. The ones whose meaning changes:
  - `tests/edge/int_edge.fpr:11` expects `-1 1` for `(0-7) % 3` and
    `7 % (0-3)`; that becomes `2 -2`. Update the expected output, and any
    `/` expectations for negative operands (`-7 / 2` becomes `-4`).
  - `sol/examples/algebra.sol:16` expects `-7 % 3 = -1`; update it to `2`.
    (`sol/examples/strings.sol:66` already calls `%` "Numeric.mod".)
  - `examples/wasm/wasmvm.fpr:318` `ibin64 IRemS a b = Ok (a % b)` is WASM
    `rem_s`, which is truncated, so it must become `I64.rem` (or
    `Math.rem` on `Int`). The matching `div_s` must use `I64.quot`, not
    `/`.
  - `std/clientcalc.fpr:70` `Rem a b -> ... % ...`: **decided (D12).**
    `Rem` is the truncated remainder (`Math.rem`). A new `Mod` is the
    floored modulo (`%`). Each name means exactly one thing.
  - `std/view.fpr:775` already takes `abs` first and is not affected.
- **`I64`/`I32` `%` and `/`** (`I64.rem`/`I32.rem` today, used in
  `tests/i64.fpr:48`, `tests/tangnano20k_i32_core.fpr:27-29`, and the I64
  LCG in `tests/dtree.fpr:328`, whose wrapped product can be negative):
  **decided (D9)** floored, so the symbol means one thing on every numeric
  type. `I64.quot`/`I64.rem` and `I32.quot`/`I32.rem` stay as named
  functions for the hardware truncated result, with the same `b != 0`
  precondition.
- **`I64.min / -1` and `I32.min / -1`.** The existing contract
  ([I64](2026-10-05-I64.md), [I32](2026-10-18-I32.md)) is a named panic
  (`I64: division overflow (INT64_MIN / -1)`, `I32: division overflow
  (INT32_MIN / -1)`), and the corresponding remainder is 0. This page
  keeps that policy for both floored `/` and `I64.quot`/`I32.quot` (the
  exact quotient is an integer, so floored and truncated coincide).
  Wrapping to `I64.min` / `I32.min` would also be a defensible reading of
  "fixed-width two's-complement wrapping" and would match ARM and RISC-V
  `sdiv`, but it would change a documented, tested trap, so it is not
  adopted here. `%` and `rem` of `min` and `-1` remain `0`.

## Proposed policy (revised 2026-11-10 with Jack's decisions)

One rule per kind of failure. Each is a direction already taken somewhere in
the tree, made consistent.

1. **Absence is an `Option`, failure to convert is a `Result`.** Lookups,
   parses and "first/last/minimum" already follow this. Every index
   operation gets an `Option` form (D3, [Indexing without
   traps](#indexing-without-traps)), as do capacity-bound writes
   (`SStr.push`, `FixedMap` insert). A total helper that clamps (`substr`,
   `take`, `drop`) stays, and its doc line says that it clamps.
2. **Domain errors are preconditions, and preconditions never become
   runtime traps.** Division, `%`, `^`, shifts, `chr`, `Sys.exit` and the
   precondition form of every index operation carry a signature predicate:
   `(/) : Int -> (y : Int | y != 0) -> Int`, `byteAt : (s : String) -> (i :
   Int | 0 <= i and i < strlen s) -> Int`. The compiler:
   - discharges it from guards, case arms, its own preconditions and (new)
     the interval facts, and emits nothing;
   - refuses it when it is decidably false, such as a literal zero divisor;
   - otherwise lifts it onto the enclosing function's signature when the
     operand is one of its parameters, so the requirement shows up in the
     type the caller sees and moves outward until a guard discharges it;
   - and where it cannot lift further, refuses the program and offers the
     `Option` form or a guard.
   This is Jack's "divide should just say `y != 0`". Until the length atoms
   exist, index reads keep a warning-level runtime check (see [the
   transition](#indexing-without-traps)).
3. **`Int` is exact** (D1, D6, [Int: never wraps, never
   traps](#int-never-wraps-never-traps)). It has no overflow and no trap.
   The compiler picks the fixnum fast path by proof, and code with declared
   bounds must show its Ints are small or use `I64`/`I32`. `I64` and `I32`
   are fixed width and wrap; they are the HPC types. Narrowing conversions
   return `Option` (D7). There is no `checkedAdd` or `wrappingAdd` (D4).
   `/` and `%` are floored on `Int`, `I64` and `I32` (D5, D8, D9); the
   truncated pair has its own names (`Math.quot`/`Math.rem`,
   `I64.quot`/`I64.rem`, `I32.quot`/`I32.rem`).
4. **Resource exhaustion stays a typed trap**: heap, stack, fuel budgets,
   ring capacities. Where a function declares `work`/`alloc`/`live` bounds,
   the WCET pass proves the trap absent; elsewhere it is a named panic that
   supervision can catch. Nothing returns a default.
5. **Invariant violations stay panics** (`fpr_cpanic`): layout tables,
   scheduler states, "not the current actor's handle". They are compiler or
   runtime bugs, not program failures.
6. **Every backend gives the same answer or the same named failure.** Sol's
   interpreter, Sol's JIT and native agree on `Int` (exact everywhere, D6),
   `String`/`Bytes` (bytes everywhere, D2, D10), `/` and `%` (floored on
   every numeric type, D5, D8, D9), `chr`, `parseInt` and heap limits. A
   differential corpus (the probes of this page) enforces it in P0.

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
- First draft: none of the proposals added checks to native code, because
  native already checks. Revised (D1): exact `Int` adds one operand tag test
  where an operand is not proven fixnum. The [C model](#measured-c-model-of-the-fast-path-x86-64-this-box)
  measures that, and loop versioning removes it. Preconditions still
  *remove* checks where discharged, and the lifted form moves a check
  outward (once per call instead of once per operation). Sol's JIT gains one
  overflow branch per `AddI/SubI/MulI` (not measured; expected to be of the
  same order as the C row above). Sol's interpreter is unchanged, because it
  is already exact.

## Order of work (revised 2026-11-10)

Phases are from the [pipeline roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md);
numbers in brackets are the [performance priorities](2026-11-09-PERFORMANCE-PRIORITIES.md)
delivery order. Effort estimates: S under a day, M a few days, L a week or
more.

| # | Item | Effort | Phase | Depends on |
| --- | --- | --- | --- | --- |
| 1 | Differential failure corpus, native against Sol interpreter against Sol JIT (this page's probes plus `%`, bytes and bignum cases) in CI | S | P0 | - |
| 2 | `%` and `/` floored on `Int`, `I64` and `I32` (prelude `Int.mod`, Sol `Int.mod`, I64/I32 operators); add `Math.quot` and keep `Math.rem`, `I64.quot`/`I64.rem`, `I32.quot`/`I32.rem` for the truncated pair; fix-ups: `int_edge` and `algebra.sol` expectations; `wasmvm` `IRemS`/`div_s` moved to `I64.rem`/`I64.quot`; `clientcalc` `Rem` stays truncated (`Math.rem`) and a new `Mod` is floored (`%`) (D12); `band` lowering for positive powers of two. `I64.min / -1` and `I32.min / -1` keep the existing named panic (D9) | S | std + backend | - |
| 3 | Sol JIT stops wrapping: overflow poison and re-run in the interpreter (correct on its own: the interpreter is already exact) | S-M | Sol VM | - |
| 4 | Refuse literal-false preconditions and literal zero divisors | S | P1 | - |
| 5 | `Option` forms for every index operation (`String.byteAt?`, `Bytes.byteAt?`, `Vec.get?`, `Vec.set?`, `Vec.slice?`, `S.slice?`, `SStr.at?`, `SStr.push -> Option`); warnings on unproven trapping reads; migrate std's guarded reads | M | std + frontend | - |
| 6 | Two types, `Bytes` and `String` (D10): Sol `VString` becomes a validated UTF-8 `ByteString`, `Bytes` is existing `VBytes`; `charAt` and the old `codes` removed as compile errors that name the replacement (D11, no aliases); `String.byteAt`/`Bytes.byteAt`, `String.codes` (code points), `String.fromCodes : List Int -> Option String`, `String.toBytes` (zero-copy), `String.fromBytes : Bytes -> Option String`; I/O yields `Bytes`; `chr` returns `Byte`; `String.reverse` reverses code points; `std/binary`/`wire`/`mqtt`/`fat` move to `Bytes`; Sol `chr` refuses by name | M | Sol VM + std | - |
| 7 | Exact `Int`, stage 1: bignum runtime and slow paths (C primitives return a bignum instead of panicking), operand tag tests in the inline paths, `VR_INT` columns go boxed on a bignum, kernels fall back to scalar code, bignum hashing, `str`, parses and JSON; `I32.ofInt`/`I64.ofInt` become `Option` (D7); `I64.toInt`/`I32.toInt` become total | L | runtime + backend (before P3 unboxing, so unboxing is written for the new rule) | 1, 3 |
| 8 | Exact `Int`, stage 2: refuse unbounded Ints in code with declared bounds and in no-heap units; limb-count cost terms in `Cost.hs`; RV32 build-size check | M-L | P1 + P6 | 7 |
| 9 | Rebinding type-check gap | M | P2 | - |
| 10 | Duplicate clause refused | S | - | - |
| 11 | Lift undischarged builtin and parameter preconditions onto signatures; report them in `--editor-json` | M | P1 (+P2 typed sites) | - |
| 12 | `len`/`strlen`/`Vec.len` atoms; Precond facts as Interval entry facts. This drops duplicate zero tests and index checks and, for exact `Int`, proves most indices and counters fixnum [10] | L | P1 + P5 | 11 |
| 13 | Index operations become precondition-only (no runtime range checks left) once item 5's warning count is zero | M | P1 | 5, 12 |
| 14 | Loop versioning for promotable loop state (fixnum loop, generic continuation): removes the unproven tag-test cost measured above | M | P5 | 7 |
| 15 | String view variant, if performance priority #12 favours slices; built on item 6's representation | M | std/runtime | 6, [9] |
| 16 | `parseInt` deprecated for `S.toInt`; Sol honours `FPR_HEAP_MB`; `std/math` loads on Sol | S | std / Sol VM | - |
| 17 | `intovf.fpr` (renamed: Int promotion) under QEMU A64/RV64 where CI has it | S | P0 | 7 |

Items 2, 3, 4, 5, 6 and 10 do not wait on the pipeline. Item 7 is the one
large piece of work. It should land before P3's unboxing slices
(performance order 8), so unboxing is built once, on the "proven fixnum"
rule.

<a id="decisions-d6d12-2026-11-10-expected-semantics"></a>
## Decisions D6–D12 (2026-11-10): expected semantics

Recorded from Jack's review of the seven remaining questions on this page,
2026-11-10:

> For the 7 questions let's choose the answers that make them as explicit
> as possible and also the expected semantics of those operations. And
> write them down (to review or replace later if needed)

Status of each: **decided, open to review or replacement**. Sol, the Sol
JIT and native give the same answer, or the same named failure, for every
example below.

**Naming rule.** Each operator or function name denotes one semantics
across all numeric types (`Int`, `I64`, `I32`) and all backends.
Alternative semantics get their own name.

The seven questions, answered:

| Q | Question | Answer | Decision |
| --- | --- | --- | --- |
| 1 | Exact `Int` (option (a)), including the bounded-code rule? | Yes | [D6](#d6-exact-int) |
| 2 | `I32.ofInt` / `I64.ofInt` of an Int that does not fit? | Return `Option`; no implicit wrapping | [D7](#d7-i32ofint--i64ofint-return-option) |
| 3 | Make `/` floored too, so the identity holds? | Yes; `Math.quot` / `Math.rem` are the truncated pair | [D8](#d8--is-floored-division) |
| 4 | `%` and `/` on `I64`/`I32`? | Floored, same symbols; `quot`/`rem` for hardware truncated results. `min / -1` keeps the existing named panic | [D9](#d9--and--on-i64i32-are-floored-too) |
| 5 | One `String` type, or `String` plus `Bytes`? | Two types: `Bytes` (any bytes) and `String` (valid UTF-8) | [D10](#d10-two-types-bytes-and-string) |
| 6 | Old names during migration? | Rename in one change; no deprecated aliases; old names are compile errors that name the replacement | [D11](#d11-rename-in-one-change-no-deprecated-aliases) |
| 7 | Calculator `Rem`? | Truncated (`Math.rem`); add a separate `Mod` that is floored (`%`) | [D12](#d12-calculator-rem-is-truncated-mod-is-floored) |

<a id="d6-exact-int"></a>
### D6. Exact `Int`

`Int` is the mathematical integer. Arithmetic on `Int` never overflows,
never wraps, and never traps. A value that fits the tagged 63-bit word
(31-bit on RV32) stays in that word; a result that does not fit is
promoted to a heap bignum. The compiler emits today's fixnum code where
it proves the value stays small (range analysis and preconditions).

Code with declared `work`/`alloc`/`live` bounds, and no-heap units, must
prove every `Int` stays small, or must use `I64`/`I32`. Otherwise it is a
compile error that names the variable and the unproven range.

Examples, identical on native, the Sol interpreter and the Sol JIT:

- `intMax + 1 == 4611686018427387904`
- `intMin - 1 == -4611686018427387905`
- `intMin / (-1) == 4611686018427387904`
- `0 - intMin == 4611686018427387904`
- `Math.abs intMin == 4611686018427387904`
- `2 ^ 63 == 9223372036854775808`
- `BITSHIFTL 1 63 == 9223372036854775808`

The only remaining failure of `Int` arithmetic itself is running out of
memory, already a typed trap. Division and remainder still require
`b != 0` (D8). `I64` and `I32` stay fixed-width two's-complement wrapping
types for HPC (D1, D9). The Sol JIT must agree: on overflow it re-runs in
the interpreter (or otherwise produces the exact result), and must never
wrap silently.

<a id="d7-i32ofint--i64ofint-return-option"></a>
### D7. `I32.ofInt` / `I64.ofInt` return `Option`

```
I32.ofInt : Int -> Option I32
I64.ofInt : Int -> Option I64
```

`Some v` when the value is in the destination range; `None` when it is
not. There is no implicit wrapping conversion. Bit reinterpretation, if
ever needed, would be a separately named explicit operation; it is not
added now.

`I32` range is `-2147483648` through `2147483647`. `I64` range is
`-9223372036854775808` (`I64.min`) through `9223372036854775807`
(`I64.max`).

Examples, identical on every backend:

- `I32.ofInt 0 == Some 0`
- `I32.ofInt 2147483647 == Some` of `I32` `2147483647`
- `I32.ofInt 2147483648 == None`
- `I32.ofInt (-2147483648) == Some I32.min`
- `I32.ofInt (-2147483649) == None`
- `I32.ofInt intMax == None` (today this is silently `-1`)
- `I64.ofInt intMax == Some` of that value (it fits in 64 bits)
- `I64.ofInt (2 ^ 63) == None`
- `I64.ofInt (0 - (2 ^ 63)) == Some I64.min`
- `I64.ofInt (0 - (2 ^ 63) - 1) == None`

The other direction, `I32.toInt` / `I64.toInt`, becomes total once `Int`
is exact (D6), because every `I32`/`I64` value is an `Int`. `I64`/`I32`
arithmetic remains fixed-width two's-complement wrapping by type, as the
explicit HPC types (D1, D9).

<a id="d8--is-floored-division"></a>
### D8. `/` is floored division

```
(/) : Int -> (b : Int | b != 0) -> Int
(%) : Int -> (b : Int | b != 0) -> Int
Math.quot : Int -> (b : Int | b != 0) -> Int
Math.rem  : Int -> (b : Int | b != 0) -> Int
```

`a / b = floor(a/b)`: the greatest integer less than or equal to the
exact rational quotient. `%` is floored modulo (D5). The remainder takes
the sign of the divisor: `0 <= |a % b| < |b|`, and either `a % b == 0` or
`a % b` has the same sign as `b`. The identity

```
a == (a / b) * b + a % b
```

always holds when `b != 0`.

`Math.quot` is the truncated (toward-zero) quotient. `Math.rem` is the
truncated remainder (sign of the dividend). Identity:

```
a == Math.quot a b * b + Math.rem a b
```

A zero divisor is a compile error when it is decidably zero; otherwise
the `b != 0` requirement is lifted onto the caller's signature (policy
2).

Examples, identical on every backend:

| `a` | `b` | `a / b` | `a % b` | `Math.quot a b` | `Math.rem a b` |
| --- | --- | --- | --- | --- | --- |
| `-7` | `2` | `-4` | `1` | `-3` | `-1` |
| `7` | `2` | `3` | `1` | `3` | `1` |
| `7` | `-2` | `-4` | `-1` | `-3` | `1` |
| `-7` | `-2` | `3` | `-1` | `3` | `-1` |
| `-7` | `3` | `-3` | `2` | `-2` | `-1` |
| `7` | `-3` | `-3` | `-2` | `-2` | `1` |
| `0` | `2` | `0` | `0` | `0` | `0` |

<a id="d9--and--on-i64i32-are-floored-too"></a>
### D9. `%` and `/` on `I64`/`I32` are floored too

The same symbols have the same meaning on `I64` and `I32` as on `Int`
(naming rule). Each carries the precondition `b != 0`.

```
(/) : I64 -> (b : I64 | b != 0) -> I64    -- floored
(%) : I64 -> (b : I64 | b != 0) -> I64    -- floored
I64.quot : I64 -> (b : I64 | b != 0) -> I64  -- truncated (hardware)
I64.rem  : I64 -> (b : I64 | b != 0) -> I64  -- truncated (hardware)
```

And the same four operations on `I32`. The identity
`a == (a / b) * b + a % b` holds on `I64`/`I32` whenever the quotient is
representable (the `min / -1` case below is the exception, because the
quotient is not). Ordinary examples match the `Int` table, for instance
`(-7 : I64) / 2 == -4`, `(-7 : I64) % 2 == 1`, `I64.quot (-7) 2 == -3`,
`I64.rem (-7) 2 == -1`.

**The `min / -1` case.** `I64.min / -1` and `I32.min / -1` overflow the
representable range (the mathematical result is `2^63` and `2^31`). The
existing `I64` and `I32` contract ([2026-10-05-I64.md](2026-10-05-I64.md),
[2026-10-18-I32.md](2026-10-18-I32.md)) is a named panic:

- `I64.min / -1` and `I64.quot I64.min (-1)` panic with
  `I64: division overflow (INT64_MIN / -1)`
- `I32.min / -1` and `I32.quot I32.min (-1)` panic with
  `I32: division overflow (INT32_MIN / -1)`
- `I64.min % -1 == 0` and `I64.rem I64.min (-1) == 0` (and the same for
  `I32`)

Floored and truncated quotients coincide here, because the exact quotient
is an integer, so the panic applies to both `/` and `quot`. This page
keeps that documented, tested trap rather than wrapping to `I64.min` /
`I32.min`. Wrapping would also be a defensible reading of "fixed-width
two's-complement wrapping" and would match ARM and RISC-V `sdiv` (x86
`idiv` raises `#DE`); it is left open to review if Jack wants wrap
instead.

<a id="d10-two-types-bytes-and-string"></a>
### D10. Two types: `Bytes` and `String`

This supersedes the earlier one-type recommendation on this page (one
`String` that may hold any bytes, UTF-8 by convention). The reasoning:
invalid text cannot masquerade as `String`. D2 still holds: length and
indexing are in bytes on both types, on every backend.

- `Bytes` is an immutable `Array Byte`. It may hold any bytes, with no
  validity invariant.
- `String` is an immutable byte array that is guaranteed valid UTF-8.

Length and indexing on `String` are in bytes, not code points. The same
is true of `Bytes`. Index operations follow D3: an `Option` form and a
precondition form, and neither traps.

Conversions:

```
String.toBytes   : String -> Bytes              -- zero-copy
String.fromBytes : Bytes -> Option String       -- None if invalid UTF-8
String.fromCodes : List Int -> Option String    -- None if any value is
                                                -- not a Unicode scalar
                                                -- (outside 0..0x10FFFF,
                                                -- or a surrogate
                                                -- 0xD800..0xDFFF)
String.codes     : String -> List Int           -- Unicode scalar values
                                                -- (code points)
String.byteAt                                 -- Option and precondition
                                              -- forms, per D3
```

`"..."` literals and `"{...}"` interpolations are `String`, hence valid
UTF-8. I/O that reads files or sockets yields `Bytes`. Decoding to text
is an explicit `String.fromBytes` (or a named helper built on it).
Writing text is an explicit `String.toBytes`. `std/binary`, `wire`,
`mqtt` and `fat` use `Bytes` for binary buffers.

`chr` returns a `Byte`, not a `String`, with precondition
`0 <= n and n < 256`. A lone byte such as `0xE9` is not valid UTF-8 and
must not inhabit `String`.

Examples, identical on every backend:

- `strlen "é" == 2`
- `String.byteAt "é" 0` is `195` (precondition form) and `Some 195`
  (`Option` form); index `1` is `169`; index `2` is `None` / a compile
  error if the index is unproven
- `String.codes "é" == [233]`
- `String.fromCodes [233] == Some "é"` (UTF-8 bytes `0xC3 0xA9`)
- `String.fromCodes [8364] == Some "€"` (UTF-8 bytes `0xE2 0x82 0xAC`)
- `String.fromCodes [1114112] == None`
- `String.fromCodes [-1] == None`
- `String.fromCodes [0xD800] == None`
- `String.fromBytes` of a single byte `0xE9` is `None`
- `String.fromBytes (String.toBytes "é") == Some "é"`
- `String.toBytes "é"` has length 2 and bytes `195`, `169`

<a id="d11-rename-in-one-change-no-deprecated-aliases"></a>
### D11. Rename in one change; no deprecated aliases

There is no compatibility window in which old names keep compiling as
aliases. An alias would hide that the meaning changed on Sol (bytes vs
code points).

In the same change:

- `charAt` is removed. Using it is a compile error whose message names
  the replacement, for example:
  `charAt was removed: use String.byteAt (bytes) or String.codes (code points)`.
- The old `codes` (bytes on native, code points on Sol) is removed.
  Using it is a compile error naming the replacement, for example:
  `codes was removed: use String.bytes or String.toBytes (bytes) or String.codes (code points)`.
  Existing call sites do not silently change meaning. The only `codes`
  from this change onward is `String.codes : String -> List Int` (code
  points).
- Other renamed operations (`String.fromCodes` now returns
  `Option String` and encodes UTF-8, and so on) are the only bindings
  from that change onward.

<a id="d12-calculator-rem-is-truncated-mod-is-floored"></a>
### D12. Calculator: `Rem` is truncated, `Mod` is floored

In `std/clientcalc.fpr`:

- `Rem` is the truncated remainder, i.e. `Math.rem`. `Rem -7 2` answers
  `-1`.
- A new `Mod` is the floored modulo, i.e. `%`. `Mod -7 2` answers `1`.

Each name means exactly one thing (naming rule). The calculator's
division, if it is the `/` operator, is floored (D8). If the calculator
also exposes a truncated quotient, that operation gets its own name
(`Quot`, `Math.quot`).

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
