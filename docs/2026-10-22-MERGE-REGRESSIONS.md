# Regressions after the typed-IR merge: the x86-64 tied shift, Sol NN, the module registry

Date: 2026-10-22. Kind: fix record.
Base: `origin/main` at `43ffba2`, the
[typed-IR merge](2026-10-21-TYPED-IR-MERGE.md).

## The red CI run on main

The first CI run on main after the merge,
[39599899540](https://github.com/hyperswine/fprisc/actions/runs/39599899540),
failed in the "Typed IR direct backends (Linux x86-64)" step. Building
`tests/typed_ir/scalar_mod.fpr` with `FPR_TYPED_IR_BACKEND=1` under
strict mode stopped with:

```text
fpr: typed-ir backend: mix@97636b9b591605c5: compiler error: allocate mix@97636b9b591605c5: two copies into one place
```

It reproduces on this Mac without x86 execution, by compiling for
`--target=x64`. The merge's local validation did not catch it because the
x86-64 native leg is a host skip on arm64; the Rosetta suite runs probes
built from its own fixtures, not this unit.

### Cause

`mix` uses `BITSHIFTL` and `BITSHIFTR`. The x86-64 selector emits a
variable shift with the result tied to the value (`OV d (Tied 0)`) and the
count fixed in `%rcx`. The allocator realises a tied definition by copying
the tied use into the destination register before the instruction, in
the same parallel copy that stages the fixed operands. Its constraint
(`forbiddenAt` in `Codegen/Allocate.hs`) kept the fixed and read
registers of an instruction away from a value born there only when the
target marks the expansion early-writing (`acEarlyDef`), which shifts are
not. So the scan could give the result `%rcx`, its first caller-saved
preference, and both copies then targeted `%rcx`.

There was a silent variant as well. When the shifted value dies at the
shift and sits in `%rcx`, the result may reuse its register, the tied copy
is skipped, and the count's copy then overwrites the value: the
instruction computes `count << count` with no error anywhere.

Neither branch could show it alone. The coverage branch added the shifts
under M2's slot placement, where nothing lives in `%rcx` across an
instruction. M3's allocator had no shifts to place. A64 has no
instruction with both a tied destination and a fixed operand.

### Fix

- `forbiddenAt` treats a tied definition as written early: the
  destination may not be a register its instruction fixes for another
  operand or reads implicitly.
- The rewrite checks, independently of the scan and of the copy resolver,
  that a tied destination shares a register with no other operand. An
  operand that is the tied use's own value (`x * x`) still shares it.
- `x64SelectionRev` 7 -> 8: x86-64 allocation can differ wherever a tied
  definition met a fixed operand, so cached x86-64 typed-IR units are
  invalidated. The legacy path and `codegenRev` are unchanged.
- `tests/AllocIR.hs` adds a tied shift with the count fixed in the
  synthetic target's first caller-saved register, once with the value
  living on and once with it dying at the shift. With the `forbiddenAt`
  change removed, the test fails at the shift; with it, the simulator
  confirms the value and the count reach their registers.

### Verified

| Check | Result |
|---|---|
| The CI failure's compile, `--target=x64`, strict | 47/47 functions native (was the error above) |
| A64 typed-IR emission, `scalar_mod`, `sha`, `helpers`, mixed mode | byte-identical to the pre-fix compiler |
| x86-64 typed-IR emission, `sha`, `helpers` | byte-identical |
| `tests/check_typed_ir.py` | PASS |
| `tests/check_typed_ir_a64.py` | PASS: 47/47 strict native, 73 calls equal the legacy binary and independent arithmetic, C both ways, 6 stack segments, 1 and 4 harts, caches, mixed mode |
| `tests/check_typed_ir_x64.py` | shared SelectedIR and AllocIR PASS; execution is a host skip on arm64 |
| `tests/check_x64_local.py --require-execution` (Rosetta) | PASS: 31,912 C-reference cases, 13 traps, self loops, vectors |
| `tests/check_registers.py`, `check_self_loops.py`, `check_workers.py` | PASS |

Not verified here: native Linux x86-64 execution, which is CI's leg on the
pushed branch.

## Sol NN: a matrix used twice

QOS's check-all leg "Sol NN" runs `sol/examples/nn.sol` from this
repository and was red with
`nn.sol:104:4: in epoch: linear variable 'z1' used 2 time(s), expected exactly 1`
on the previous QOS pin as well. The refusal is correct: `epoch` gives the
pre-activation matrix `z1` to `M.map relu`, which consumes it, and later
reads its rows again with `mAllRowsOf z1` for the relu gate in the
backward pass. The example now takes the rows first (`mAllRowsOf` hands
the matrix back) and maps relu over the returned matrix; the later
`M.free` of that copy is gone because the map consumes it. The values are
the same rows in the same order.

The leg's three checks pass: `nn: OK`, `compiled vecmap<relu>` (the JIT
still compiles the relu map) and `ok mse<0.02` (5.10e-3).

## The module registry lived in a process's heap

QOS's check-all leg "Editor policies" (`tools/editor-policy-check.py`)
died with `qosp fatal SIGSEGV: addr=0x3` in `editorpolicyprocess`, on the
previous QOS pin as well. The test launches a child plugin that runs out
of its 32 MiB budget and ends, then launches another. The fault is in
`tab_rows` (`runtime/mod.c`): the registry's slot array held `0x3`, the
tagged Int 1, where a table pointer belonged.

Cause: `fpr_mod_attach` grew the registry's two arrays with `fpr_alloc`,
which takes from the calling actor's heap. The registry is the whole
program's, but an attach made from inside a process that later ends, or
inside a receive turn, leaves the arrays in memory that is reclaimed and
reused under it. Separately, QOS's `plug_image_quiet` freed a launched
plugin's image when its process ended without removing its module table
from the registry, so a later walk would read the freed image.

Fix:

- The arrays are `buddy_alloc` blocks, charged to no process. Running out
  of that memory is an attach failure with its own result (`-2`); the
  posix loader reports "no memory for the module registry" (QOS's attach
  does the same in its own change).
- `fpr_mod_detach` empties a table's slot. The slot is kept so the indices
  the prelude's readers hold between calls never shift; an empty slot reads
  as no rows (`tab_rows`) and no hash (`Mod.hashAt`). A slot is 16 bytes
  per image ever attached, for the life of the program.
- `Mod.fn` walks the tables under the registry lock, so a detach, and the
  image's release that follows it, waits for the walk.
- QOS records each plugin's table and detaches it before freeing the
  image (QOS `qos/appside/entry.c`, on its own branch).

Verified: with the fix, the Editor policies leg holds for all four of its
programs on one and four harts. With only the arrays put back on
`fpr_alloc`, `editorpolicyprocess` faults again at `addr=0x3`.

Not closed: a value a reader took from a plugin's table (a hash string, a
function value) still points into that plugin's image after the image is
released. That is the contract every image-held static already has; this
change only stops the registry itself from reaching a released image.
