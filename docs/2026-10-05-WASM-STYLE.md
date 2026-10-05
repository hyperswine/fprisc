# The WASM VM in the intended style, and what the language made hard

Date: 2026-10-05. Kind: implementation record and issue list. Applies from
revision `76bde75` plus the restyled `examples/wasm/`. Follows
[2026-10-05-WASM-VM.md](2026-10-05-WASM-VM.md) (the port) and applies
[2026-10-03-STYLE-DIRECTION.md](2026-10-03-STYLE-DIRECTION.md).

## What changed in the code

The first port was a working translation of the Haskell with `unsafe
module.` on every file and nested `case` trees. It is now written in the
style: clauses select on shape, guards state when a clause applies, `|>`
shows data flow, measures replace `unsafe` where a loop ends by itself.

| File | Before | After |
|---|---|---|
| `wasmvm.fpr` | whole module unsafe; 216 `case` | one clause per instruction and operand shape in `exec`; 7 unsafe functions (the run loop, which ends when the guest does); 4 measured loops; contracts on shift counts, widths and byte counts; 7 functions with proven `work`/`alloc` bounds |
| `wat.fpr` | whole module unsafe; recursive scanner; 160 `case` | the lexer is a fold over bytes (a state machine, one clause per state and byte), the tree is a fold over tokens (a stack), numbers are folds over digits; 9 unsafe functions, all the tree-walking compiler and its callers |
| `actors.fpr` | whole module unsafe | one clause per host call, descriptor kind and step outcome; 6 unsafe functions (the slice and the rounds) |
| `calc.fpr`, `wasmtest.fpr` | `unsafe program.` | clause-based drivers; unsafe exactly where they reach the run loop |

The guest is input, so every trap stays a value (`Trapped`, `Err`). No
contract is used to reject anything a guest or a `.wat` file can do.

Checked after the change: `wasmtest.fpr` passes 57 of 57;
`calc.fpr` prints the Haskell `WASM.Main` transcript byte for byte;
`calc.fpr "6 * 7" "81 / 9"` prints 42 and 9. `fpr build --cost
examples/wasm/wasmtest.fpr` proves all 14 declared bounds and reports 47
precondition obligations: 11 discharged, 16 runtime-checked, 20 builtin
traps.

## Issues found

Each was reproduced on its own, outside the VM, on this revision.

### Integers are 63 bits, and SEMANTICS.md says 64

`SEMANTICS.md` section 3 says "Ints are 64-bit". They are tagged 63-bit:

    BITSHIFTL 1 62           = -4611686018427387904
    BITSHIFTL 1 63           = 0
    4611686018427387903 + 1  = -4611686018427387904
    BITSHIFTR (0 - 16) 2     = 4611686018427387900

Overflow wraps silently at 2^62, and `BITSHIFTR` is a logical shift on 63
bits, so it neither sign-extends nor matches a 64-bit logical shift. Any
code that needs exact 64-bit arithmetic (wasm i64, hashes, file offsets
past 2^62, protocol fields) must split values. The VM holds an i64 as two
unsigned 32-bit halves and writes add, subtract, multiply (16-bit limbs),
shifts, rotates, comparisons and long division by hand: about 150 lines.

Wanted: the page corrected; an `Int64`/`Word32` pair of fixed-width
types, or at least `mulHi`/`addCarry` primitives; an arithmetic shift.

### F64.pow is not exact on exact inputs

`F64.pow 10.0 1.0` is `9.99999999999999`, so `2.5` parsed as
`25 / pow 10 1` is not 2.5 (`2.0^10` happens to be exact). The VM and
parser use repeated multiplication. `runtime.c` routes `F64.pow`
through its own `fpow_`; it should use the C library's `pow`, or special-case
integral exponents.

### There is no float-to-bits primitive

`f64frombits`/`f32frombits` exist; the reverse does not. `reinterpret`
and float stores compute the IEEE fields by scaling to find the exponent
(`normalize`, `packBits64`): slow and easy to get wrong at subnormals.
Wanted: `F64.bits : F64 -> (Int, Int)` and `F32.bits : F32 -> Int`.

### Arithmetic operators are Int unless a signature says otherwise

Without a signature, `fbin op a b = case op of ... -> a + b` is typed
Int -> Int -> Int, and calling it with F64 is a type error ("cannot unify
Int with F64"). The error is correct, but it surfaces at the call site, far
from the cause. Every float helper in the VM carries a signature for this
reason. ([2026-10-05-WASM-VM.md](2026-10-05-WASM-VM.md) said this happened
"with no diagnostic"; that was wrong.)

### Names that begin with a keyword

`cases = [1, 2]. main = print cases.` does not parse: `cases` is read as
`case` then `s`, and the error points at the following `.`
("expecting ... of"). It cost a long search because the report was at
an earlier binding in a larger file. The lexer should require a keyword to
end at a non-identifier character, as `unsafe` already does.

### Measures: what the checker can and cannot follow

- A floor clause must name every parameter. `divBits _ _ i q r | i < 0 =
  (q, r).` gives "its FLOOR (measure >= 0) is not derivable"; the same
  clause with `a b` for the wildcards is accepted.
- The floor must be the whole guard. `| left <= 0 or isZero64 a` is not
  used as a floor; splitting it into two clauses is.
- Structural descent into sub-lists of a tree, across a mutually recursive
  group, has no measure. The WAT instruction compiler (`compileSeq`,
  `compileFolded`, `blockLike`, `ifForm`) recurses only on strict parts
  of a finite tree and is still unsafe.
- `unsafe` is contagious and must be exact in both directions: every
  caller up to `main` needs the marker, and a marker the analysis does not
  need is an error. Getting it right took four compile rounds for one
  driver, each naming the next layer. A single report of the whole chain
  would do it in one.
- A counter measure is checked for descent, not for meaning. A first
  version bounded a VM slice by a step counter equal to its fuel; it was
  accepted and it was wrong (block exits and returns spend no fuel), and
  it changed the transcript. The slice is unsafe again, with the reason in
  a comment.

### Records across module boundaries

- A record type alias named from another module (`M.Mem`) is nominal
  (`Mem@hash`) and does not unify with a record literal of the same
  fields. Inside its own module it is structural. The VM therefore wraps
  what crosses the boundary in constructors: `Program`, `Instance`, `VM`.
- A tuple type cannot be aliased at top level (`I64 = (Int, Int).` does
  not parse), so `(Int, Int)` is spelled out in every i64 signature.

### Syntax

- `fn` is reserved, so it cannot name a parameter (the host call name
  became `call`).
- A lambda cannot take a tuple pattern: `fn (a, b) -> ...` does not parse.
  The style pushes toward named clause functions instead, which reads
  better anyway.

### The cost pass

- A reference to a named constant (`two31`) is costed as an allocating
  call: `s32` derived `alloc 32` with `two31` and `alloc 0` with the
  literal. Constants should be inlined before costing.
- Destructuring two tuple arguments is costed as 16 bytes of allocation
  (`ltU64`, `ltS64`). Those bounds are declared as 16, with the reason.
- The precondition pass does not know `band x 63` lies in 0..63, so the
  shift-count contracts on `shl64`, `shrU64` and `shrS64` are
  runtime-checked at every call. A range fact for `band` with a constant
  mask would discharge them.
- `FPR_PRECOND_NOTES=1` lists obligations only for the root file, not for
  imported modules, so the 16 runtime checks above cannot be listed one by
  one from the driver.

### Performance

The suite peaks at about 110 MB and nothing is reclaimed while a guest
runs; the calculator stays small. Locals and memory are AVL maps. Both are
unchanged by the restyle. A flat code array with program counters, stepped
under `Sys.loopWith`, and memory in a `Vector`, is the next change if a
real guest is to run.

## Not done

- No negative tests (a broken contract, a non-decreasing measure, an
  understated bound) in the style of `examples/ideal/check.py`.
- The WASM programs are not in a suite; they are run by hand.
