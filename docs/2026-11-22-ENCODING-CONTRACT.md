# A64 spelling contract: both tiers' renderers assemble identically

Date: 2026-11-22.
Kind: delivery record for slice 2 of the
[merge plan](2026-11-21-MERGE-PLAN.md)'s encoder arc. Slice 1
([Encoding.A64](2026-11-21-ENCODING-A64.md)) gave the JIT a shared,
GNU-as-pinned vocabulary; this slice binds the AOT's renderer to the same
words. Host: macOS arm64; oracle: the system assembler.

## The contract

`test:EncodingContract` (new, in `make unit-tests`): for 14 instruction
families the two native tiers share, the AOT renderer's actual line
(`renderItem` — now exported from `Codegen.Target.A64`, called on a
constructed `SInstr`, not a copied string) and a canonical spelling for
the `Encoding.Insn` are BOTH assembled by the system's `as`, and the
encoded words must be equal — and equal to `Encoding.encode`. Branch
families assemble with 8 padding words and a rendered label (the Encoding
delta is 9), so the displacement fields are compared too, not just the
base words.

Shared families: Move, Add/Subtract-immediate, Compare, b.cond (Equal,
NoOverflow), cbz/cbnz, Jump, Set×2, Mul, SDiv, small Literal. The Set/CSet
pair is the contract's subtle case: both set on the NAMED condition
holding — the encoding's inverted field is the mechanism, so the pairs are
same-condition (Set Equal ↔ CSetX Eq); the rendered TEXT differs (the AOT
spells `cset x0, eq`, Encoding.render spells the inverted alias
`cset x0, ne`) while the assembled words are identical, which is exactly
what the contract compares.

## What the contract caught on its first run

`Encoding.render`'s CSetX spelled the INVERTED condition (`cset x0, ne`
for `CSetX 0 Eq`) — a spelling that assembles to a DIFFERENT word than
`encode` (csinc cond field inverted means the disassembly reads the
opposite condition). Render must be word-faithful: it now spells the same
condition, and `EncodingA64`'s render expectations were corrected with it.
Also fixed: the contract test's own comparison originally compared the
whole assembled layout (branch + 8 nops) against `encode`'s single word.

The test additionally surfaced the deliberate non-families, now recorded
in its header: SignExtend31/63 (the AOT's `sbfx` is SBFM with N=0;
Encoding's bitfield is the N=1 asr form the JIT uses — a BFX constructor
lands when the JIT needs one), negative wide constants (the AOT's `mov #n`
alias assembles to MOVN, one word; `movImm64` uses movz+movk per nonzero
half — same 64-bit value, different encoding on purpose), and the AOT-only
forms with no JIT use (CompareImmediate, LoadByte/StoreHeader, frame
`ldur`).

## Results

| Gate | Result |
| --- | --- |
| `test:EncodingContract` (new) | 14 families assemble identically through both renderers |
| `test:EncodingA64` | 49 byte-identity + 9 range + 7 render checks passed |
| `make fpr` | clean build |

`render` is not yet consumed by production code (the AOT renderer's
per-family DELEGATION to `Encoding.render` is the remaining arc; this
slice proves the spellings already agree), so runtime behavior is
unchanged by construction. `make fpr` rebuilt clean.

## Limits

- The contract binds `renderItem` and `Encoding.render` as they are
  TODAY; a future operand-shape change on either side is caught only for
  the families in the list (adding a family is a 3-line table entry).
- Branch displacement coverage is a single layout (+8 padding words); the
  range checks live in `Encoding.encode` (slice 1), not here.
- The assembler is invoked per family (28 `as` processes); the suite runs
  in seconds. Windows hosts have no `as`.

## The X64 pair (same day)

The x86-64 side joined the same contract test (`test:EncodingContract`
grew an X64 section; cross-assembled on the arm64 host with
`as -arch x86_64`). The X64 arc deliberately deviates from the A64
pattern: **no `Encoding.X64` extraction**. The JIT's `Sol/AsmX64.hs` is a
fixed-register-plan byte table (rax, r11, rdx, xmm0/1, rbp, rbx — every
IR op is a fixed byte pattern), with exact rel32 delta patching and no
masking hazard; extracting named constants would add indirection without
removing duplication, because the AOT side renders text and shares no
encoder code. The drift risk is one-sided: the hand bytes could silently
stop being the canonical encodings of the AOT's spellings — the contract
now checks exactly that. 17 families: the fixed-plan bytes (movq forms,
rbp-relative load/store with disp32, cmp/add/sub/imul/cqo/idiv/xor,
setcc+movzbq pairs, movabsq, push-imm32, testq+jz, jno) are each
assembled via the AOT renderer's spelling for the same instruction and
registers, and the object bytes must equal the hand bytes.

Assembly findings recorded by the test: backward branch references
within rel8 range make `as` pick the SHORT form (the contract's jno uses
a matched 4-byte backward layout: label, 2 nops, jno rel8 -4); forward
rel32 references are assembler-RELOCATED (the .o carries zeros), so the
testq+jz family compares its opcode prefix bytes (0F 84) only, with the
displacement documented as linker-produced.

Non-covered, deliberate: the xmm families (the AOT renderer hardcodes
xmm8+; the JIT's fixed plan uses xmm0/1 — encodings differ by the REX
bits, not by form), the operand-stack push/pop discipline (no AOT
equivalent — the JIT's stack is its own), and the AOT's push strategy
(subq+movq vs the JIT's push).
