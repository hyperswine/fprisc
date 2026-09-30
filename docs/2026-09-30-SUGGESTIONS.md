# Suggestions: native performance, and what a WASM/WASI interpreter needs

Date: 2026-09-30. Kind: review with proposals. Scope: the base profile on the
hosted native targets (`fpr build`, x86-64 and AArch64), at source revision
`03ec489`. Evidence: a source reading of `compiler/` (`Codegen.hs`,
`Compile.hs`, `A64.hs`, `Peephole.hs`, `Inline.hs`, `Infer.hs`), `runtime/fpr.h`,
`std/binary.fpr`, and the 2026-09-20 STD and 2026-09-29 NATIVE-IDEAL-AUDIT
pages. **Nothing was built or benchmarked for this page**; every performance
claim below is a prediction to confirm with the benchmark set in section 1.7.

Status: proposals, none implemented.

## 1. Native performance

### 1.1 The generator moves every value through memory

`Codegen.hs` states its own strategy: result always in `a0`, temporaries on
the real stack, locals in frame slots, every effect a real call. Every
intermediate is stored and reloaded, and every call stages its arguments
through slots and opens a full frame. The hosted backends inherit this
unchanged: `A64.hs` (and `X64.hs`) translate the rv64 output 1:1 over about
eight registers, so the host's larger register file goes unused.

That strategy was chosen deliberately (program order is device order, nothing
is elided), and it is the right default for MMIO code. It is not required for
ordinary base-profile code.

### 1.2 The existing optimizations are gated to the builtin `--arc` path

Two passes already remove most of the cost above:

- `Inline.hs` inlines small non-recursive supercombinators at saturated call
  sites (`inlineSmall 3 24`);
- `Peephole.hs` forwards slot reloads within a basic block and drops dead
  stores.

Neither runs for base programs. The inliner is applied inside
`if oArc opts` in `Compile.hs`; the peephole runs only when
`tgtArc tgt && w == 8` in `Codegen.hs`, and `Peephole.hs` notes that the x64
and a64 translators never see its output.

**Proposal:** run both for the base profile, with the peephole applied to the
shared rv64 IR *before* translation so all three targets benefit. This is the
cheapest large gain available: the code exists. The inliner's semantics
argument (arguments let-bound in call order, fresh binders, recursive
functions never inlined) carries over unchanged; what needs checking is that
base-profile Core (with ARC not lowered) has the shape it expects.

### 1.3 Primitives are C calls

"Every effect is a real call" also covers primitives such as `charAt` and
`strlen`, so a byte loop makes one C call per byte. This is the likely reason
SHA-256 written in FP-RISC runs at about 1 MB/s (2026-09-20 STD).

**Proposal:** inline fast paths for the hot primitives -- bounds-checked
byte load, string length, tagged integer arithmetic and comparison -- with the
C call kept as the slow path (bounds failure, non-Int operand).

### 1.4 Values are tagged; unknown calls are generic

Base `Int` carries a tag bit (`ISINT(v) ((v) & 1)` in `runtime/fpr.h`), so
arithmetic untags and retags. Unknown calls go through `fpr_apply`, and a
partial application with remaining arguments becomes a heap PAP
(NATIVE-IDEAL-AUDIT, "Lifting does not eliminate captured function objects").
`Representation.hs` already infers word/tagged/bool representations, but for
the builtin path only.

**Proposal:** extend representation inference so that let-bound locals of
known type `Int` stay untagged within a function, tagging only at the
boundaries (calls to unknown functions, heap stores, message sends).

### 1.5 Memory is reclaimed per actor, not per value

Base allocations live in per-actor pools reclaimed at actor death or an
explicit reset (`boundary`, `tidy`). A long-lived actor with a high allocation
rate grows its pool and loses cache locality until reset. The
NATIVE-IDEAL-AUDIT already names unifying ownership as the largest remaining
design task; it is listed here because it is also a performance item.

### 1.6 Smaller items

- A fuel check at every function entry. Cheap, but it dominates tiny
  functions; inlining (1.2) removes most of those entries.
- `tests/fvec2.fpr` failed to compile on A64 on 2026-09-29
  (`A64: unmapped register s10`, `compiler/A64.hs:106`). A correctness bug on
  the main development machine; fix before measuring anything.

### 1.7 Order of work, and how to know it worked

1. Add a fixed benchmark set and record today's numbers: `fib`, SHA-256
   (`std/digest`), a string builder, n-body (float), and an actor ping-pong.
   Treat it as a ratchet, as the WCET bound is.
2. Base-profile inliner + pre-translation peephole (1.2).
3. Inline primitive fast paths (1.3).
4. Keep let-bound locals in callee-saved registers: a linear scan over the
   ANF form, not a full allocator, removes most remaining slot traffic.
5. Untagged `Int` locals (1.4).
6. The ownership design (1.5), on its own schedule.

Items 2 and 3 are mostly wiring existing code together.

## 2. Readiness for a WASM/WASI interpreter

Neither repository contains WASM work yet; `WASM.qa` would start from
nothing.

### 2.1 Ready

- **Decoding and validation.** A String is bytes and `std/binary` reads
  fixed-width integers, so the module parser, LEB128, sections and validation
  are ordinary pattern matching over `Result`, in tail-call loops.
- **The interpreter loop.** WASM's value stack, control frames and call stack
  should be explicit data rather than host recursion anyway; that fits the
  safety rules and lets an instance be suspended at any instruction.
- **WASI preview 1.** The core calls map onto existing std: file descriptors
  and paths onto `std/file` and `std/stream`, args and environment onto
  `std/os`, clocks onto `std/clock`, readiness onto the poller.
- **Fuel.** An interpreter charges fuel per instruction or per block itself,
  which is the anti-cheating property wanted for the WASM app tier. Each
  instance as an actor gets preemption and mailboxes.

### 2.2 Missing: three primitives at the core

1. **A mutable byte buffer for linear memory.** `std/binary` says the owned,
   resizable `Buffer` is not there yet. `Vec` is the only O(1)-mutable
   container, and its elements are tagged values: eight host bytes and a tag
   check per WASM byte.
2. **Full 64-bit integers in base.** Tagged `Int` has 63 bits. `i32` works
   with masking after each operation; `i64` would need emulating as pairs.
   The builtin profile's `Word` is untagged but not available to base code.
3. **Float bit-casts in both directions.** `f32frombits`/`f64frombits` exist;
   no float-to-bits operation was found. Reinterpret instructions, NaN
   handling and f32 rounding need both.

### 2.3 Proposal

1. Add a linear `Bytes` buffer (little-endian load/store of 8/16/32/64 bits,
   grow) and an untagged `W64` for base with wrapping arithmetic, unsigned
   comparison, shifts, rotates, `clz`/`ctz`/`popcnt` and float<->bits.
   The builtin profile already has `Word` and `Mem`, so both can be written
   there and exported rather than added to the C runtime. `std/binary` and a
   future self-hosted compiler want them too.
2. A decoder and validator, run against the official spec test suite's
   `.wast` files as the conformance suite.
3. An integer-only interpreter with `fd_write`, `proc_exit` and args: enough
   for a wasi-sdk C hello world.
4. Floats, then the rest of WASI.

Step 1 comes first because it fixes linear memory's representation and the
interpreter's value type; anything built before it would be rewritten. The
performance items in section 1 matter here as well: an interpreter is exactly
the byte-and-integer workload that 1.2 to 1.4 target.

## 2026-09-30: most of 1.7 done

In 1.7's terms: item 1 (the benchmark set) is `tools/bench.py` with
`bench/baseline.json`. Item 2's peephole now runs on the shared IR, and item
3 (inline primitive fast paths) is done, together with direct primitive
calls and the builtin path's inline Int operators and branch conditions for
the base profile. See [NATIVE-PERF](2026-09-30-NATIVE-PERF.md). Section
1.6's fuel item was already handled by `x28`. Still open: item 2's
base-profile inliner, item 4 (registers), item 5 (untagged locals).
