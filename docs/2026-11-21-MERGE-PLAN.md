# Post-decision merge plan: the JIT stays

Date: 2026-11-21. Kind: plan with source-verified probes. Follows the
[architecture review](2026-11-18-COMPILER-ARCHITECTURE-REVIEW.md): with the
JIT tier declared permanent, finding 1 converts from "decide" to "act", and
the remaining merge candidates change shape. Every claim below was probed
in source this pass; nothing was built yet.

## 1. The encoder unification (finding 1, now actionable)

**What the probe found.** The two A64 emitters do not share a single line
of code, because they speak different mediums: `Codegen/Target/A64.hs`
emits TEXT (`.s` mnemonics — `"sub sp, sp, x16"`, `ldur`/`stur` spellings
for the frame forms, assembled externally), while `Sol/AsmA64.hs`
hand-encodes BYTES (`0xD2800000 .|. shiftL 21` for movz, imm19/imm26
branch fields, 52 bit-manipulation sites). The same split holds for X64
(`Target/X64.hs` vs `Sol/AsmX64.hs`). The duplication is ISA *knowledge* —
both tiers independently implement movz/movk immediate chains, the
ldur/stur unscaled-offset forms, and PC-relative branch ranges — and only
the JIT's copy is checked by anyone: the AOT's text is validated by GNU as
at assemble time, the JIT's bytes are validated by nothing.

**The merge shape.** A shared instruction-description layer per ISA, two
interpreters over one vocabulary:

```
Compiler/Encoding/A64.hs
  data Insn = ...          -- the forms BOTH tiers use today
  render :: Insn -> String          -- AOT path (.s text, as today)
  encode :: Insn -> Either RangeError Word32   -- JIT path (bytes)
```

- Scope the vocabulary bottom-up from the JIT: KIR's stack machine uses a
  much smaller instruction set than the full AOT selection, so start with
  the ~40–80 forms both share (movz/movk, add/sub imm/reg, the frame
  load/store forms, branches with range checks, compares, the f64 ops).
- The JIT adopts first (it gains range/immediate diagnostics it has never
  had), then the AOT emitter consumes the same ADT for the shared forms,
  rendering text. Not a big-bang rewrite: staged per instruction family.
- Same pattern for X64 afterwards. RV is AOT-only today and stays out of
  scope.

**Payoffs.** One definition of each instruction form; the permanent JIT
gets its encodings checked instead of trusted; and the layer unlocks a
strategic option without committing to it — the AOT could later switch to
direct byte emission (dropping the external assembler dependency) without
touching instruction selection.

**Sequencing.** A64 end-to-end first (ADT + JIT adoption + AOT adoption
for shared forms), then X64. Estimate: staged slices, days not weeks; each
slice lands with the differential gates (`tests/run.sol` codegen checks,
the Sol suites, board/QEMU gates unchanged).

## 2. Probed and rejected merges (so they stay rejected)

- **JitCore's `JTy` (JB/JI/JD/JW) vs KernelKinds' `Kind` (KI/KD/KS/KB).**
  Similar letters, different machines: one is a join lattice for JIT
  admission (JW is an inference poison), the other a per-argument
  constraint solve for the raw-word callback ABI. A merge would force one
  model onto two problems. Action instead: a two-line cross-reference in
  each header naming the other and the distinction — both are now
  permanent residents and the letters will confuse every new reader.
- **The four "representation" modules.** Distinct owners probed:
  `Representation.hs` (whole-program C2 inference), `Representation/`
  (ARC layout contracts), `Compiler/Native/Representation.hs` (erased-
  boundary evidence), `Compiler/DataLayout.hs` (runtime layout
  vocabulary). Placement/naming noise, not duplication; normalize names
  only if touched for other reasons.
- **`std/` vs `sol/lib/`.** Different tiers, profiles and checkers. Keep.

## 3. Mechanical placements (small, no behavior)

- **Top-level middle-end passes.** `Inline.hs`, `Reuse.hs`, `Workers.hs`,
  `Cost.hs`, `ReceiveTurns.hs`, `Exhaust.hs` sit at `compiler/` root while
  `Core/Opt/` exists as the pass home. They are native-tier erased-Core
  passes; moving them under one home is an imports-only change. Do it in
  one commit so review is a rename.
- **`Sol/VM.hs` (2361 lines).** The HAL table (`mkHal` from line ~1041,
  several hundred lines of device/name plumbing) splits cleanly to
  `Sol/Hal.hs`; the interpreter loop remains. Mechanical, mirrors the
  review's `Txn.hs` finding.
- **Diagnostics map.** Four spellings with distinct roles
  (`Diagnostic/` the shared model, `Frontend/Diagnostics.hs` the frontend
  reporter, `Compiler/Remarks.hs` optimization remarks,
  `Sol/Diagnostic.hs` the trial buffer). At minimum one paragraph in each
  header pointing at the others; adopting the shared model inside the Sol
  trial buffer is optional later.
- **`cbits/` naming.** `sol_digest.c`/`sol_http.c` prefixed, the rest not.
  Cosmetic.
- **JIT home.** With the tier permanent, `Sol/{JitCore,JitIR,HandJIT,
  AsmA64,AsmX64}.hs` could move under a `compiler/Jit/` directory beside
  `Codegen/` — the tier stops reading as five loose Sol files. Optional,
  bundle with the encoder work so imports move once.

## 4. Re-ranked review findings with the JIT permanent

| Finding | Status | Note |
| --- | --- | --- |
| 1 dual emitters | OPEN, now actionable | plan above; JIT permanent removes the "don't invest" branch |
| 3 `Txn.hs` split | OPEN | unchanged; after P2 lands |
| 10 `Compile.hs` | OPEN | unchanged |

## Suggested order

1. `Compiler/Encoding/A64.hs` vocabulary + JIT adoption (A64 slice).
   [Delivered 2026-11-21](2026-11-21-ENCODING-A64.md): 49 GNU-as-pinned
   byte-identity checks, silent branch masking replaced by range errors,
   JIT differentials byte-identical.
2. AOT A64 emitter adoption for shared forms; then the X64 pair.
   [Slice 1 delivered 2026-11-21](2026-11-21-ENCODING-A64.md);
   [slice 2 delivered 2026-11-22](2026-11-22-ENCODING-CONTRACT.md) and
   [slice 3 delivered 2026-11-22](2026-11-22-ENCODING-CONTRACT.md) with a
   deliberate deviation: no `Encoding.X64` extraction — the JIT's x86-64
   assembler is a fixed-register-plan byte table with exact rel32 patching
   (no masking hazard, no second definition to unify), so the X64 slice is
   the spelling contract alone: 17 families whose hand bytes are proven
   against the AOT renderer's spellings through the system assembler.
   [Shape corrected 2026-11-22](#1-the-encoder-unification-finding-1-now-actionable),
   after reading the AOT's emission architecture: the AOT already has an
   instruction ADT with mnemonics (`Codegen.Opcode.A64`, consumed by typed
   renderers into the .s lines). The convergence is NOT "add render" but a
   SPELLING CONTRACT: for each family the two tiers share,
   `Encoding.render`'s output and the AOT renderer's line must assemble to
   the identical word, proven by a differential test feeding both
   spellings to `as` and byte-comparing (`test:EncodingA64`'s oracle,
   generalized). No structural merge of the two ADTs -- their operand
   models differ legitimately (allocation-resolved frame operands vs bare
   JIT forms).
   [Delivered 2026-11-22](2026-11-22-ENCODING-CONTRACT.md): 14 families
   proven through `test:EncodingContract` (both spellings assembled by the
   system `as`, words equal); the contract's first run caught and fixed an
   inverted CSetX render. AOT per-family delegation of the rendered lines
   to `Encoding.render` remains optional follow-up -- the WORDS are now
   proven identical, which was the drift risk.
3. Mechanical placements in one rename commit (passes home, `Sol/Hal.hs`,
   kind cross-references, diagnostics map paragraphs).
4. `Txn.hs` split when the P2 typed-lowering branch lands.
