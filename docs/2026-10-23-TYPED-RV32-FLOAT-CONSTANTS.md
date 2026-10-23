# Typed RV32 boxed float constants

Kind: implementation and acceptance record, following `afebff1`. This removes
a real default fallback identified by the
[complete migration audit](2026-10-23-TYPED-IR-COMPLETION.md).

## The missing representation

RV32 Base represents F64/F32 as boxed numeric leaves. The parser encodes a
float literal with `f64frombits hi lo` or `f32frombits bits`; those IEEE words
can exceed the signed 31-bit tagged Int range. Typed lowering previously
tried to lower them as Int arguments and refused legitimate literals. Numeric,
float-vector and record-float programs therefore still used old function
emission even though the surrounding RV32 program was typed.

`OBoxedFloat` now expresses an immutable numeric leaf with an IEEE width and
unsigned bit pattern, independently of tagged Ints. The verifier checks the
payload range and limits this representation to the 32-bit word policy.
It is pure and participates in normal SSA renaming and constant sharing.
The reference evaluator continues to state explicitly that it models no
floats; runtime tests provide the numeric evidence.

Lowering recognizes literal arguments before ordinary Int lowering, in value
and tail positions, with primitive shadowing preserved. On RV32 it pools
literal boxes with either setting of `FPR_NO_F64_INLINE`, as the former
emitter did. Ordinary Ints outside the tagged range remain errors. Builtin
RV32's existing frontend refusal of F32/F64 is unchanged; this is Base's
boxed numeric contract, not an expansion of the manual builtin profile.

## Native data emission

The RV selector records each referenced constant in the native function's
data requirements. The native emitter deduplicates them across functions and
kernels and emits the objects directly:

- F64: `T_BITS` (9004), variant 5, fixed uint64 length/value fields, matching
  `fpr_num64_t` in `runtime/fpr.h`.
- F32: `T_BITS`, variant 6, RV32 word length/value fields, matching `bits_t`.

Each object is aligned to eight bytes and has an address stable across calls.
No box allocation or floating-point instruction is needed for a literal.
Numeric leaves remain opaque to the existing generic walkers. The 64-bit
targets retain their raw-bit float representation; their native data lists
contain no boxed float constants. Runtime and context ABIs are unchanged.
The cache revisions are generator 77 and RV selection 17.

## Correctness and physical evidence

`tests/check_rv32_float_constants.py` checks:

- Width/range verification and primitive shadowing, plus cold/warm codegen.
- An independent C oracle for 128 F32/F64 bit patterns: signed zero,
  subnormals, finite limits, infinities, quiet/signalling NaN payloads and
  deterministic random words. It checks the actual runtime structs, alignment,
  repeated addresses and unchanged live-allocation count.
- Actual RV32IM and RV32IMC runtime execution of the numeric suite, float
  record maps/filters/folds and F32 vector maps/filters/folds. Software
  arithmetic, float bitcasts, NaNs, signed zero and I64 interoperability
  retain their expected results; integer specialization remains enabled.
- Both inline-float flag settings, strict all-native function/unit coverage
  and the existing ISA checker.

[QEMU results](evidence/2026-10-23-native-fallbacks/float-runtime-final.log)
and the broader ten-image
[RV32 Base suite](evidence/2026-10-23-native-fallbacks/rv32-runtime1.log)
pass. The independent C numeric runtime and production startup are used;
the test's QEMU UART adapter is distinct from physical board execution.

The idle Tang Nano answered its 48 MHz UART diagnostic. The bit/layout/pooling
oracle and the full numeric software-runtime suite both ran on the responding
physical RV32 board, printed their success markers and `FPR EXIT 0`, and
returned `DONE` to the loader
([log and image hashes](evidence/2026-10-23-native-fallbacks/physical-final.log)).
Applications were loaded into RAM through the existing loader; the FPGA
bitstream was not reprogrammed or read back. This does not claim a new FPGA
timing, clock or SDRAM PVT qualification.

The full local Base sweep passes **117 jobs in 480 seconds** on four
workers ([log](evidence/2026-10-23-native-fallbacks/base-final.log)), with
the RV32 runtime gate executing rather than skipping.
[Metadata](evidence/2026-10-23-native-fallbacks/metadata.json) records compiler,
SoftFloat and physical image identities. Hosted CI has not run here.

The execution gate is registered in Base and required in CI after building
the RV32 SoftFloat archive. If execution tools or the archive are absent,
the ordinary Base job records a skip; `--require-execution` makes absence an
error. This local run explicitly reused the sibling's existing SoftFloat
archive read-only via `FPR_SOFTFLOAT_ROOT`.

## Paired guest work

The preserved compiler at `afebff1` and the new compiler compile the same
numeric program through their defaults (`mixed`), with strict-all required
after the change. Both link the same real software-float runtime and library.
Guest `instret` brackets generated `main`, including its arithmetic, vector,
runtime and output work; startup and counter reporting are outside it.
The QEMU counter uses deterministic `-icount shift=0`, randomized pair order,
and checks the program's numeric result on every run.

All 31 pairs have identical counts per variant: **97,745 before**, **95,502
typed**, ratio **0.9771**, or **2.3% fewer guest instructions**. This is one
workload's guest work, not physical elapsed-time speedup.
[Samples](evidence/2026-10-23-native-fallbacks/paired-results.json) and
[run log](evidence/2026-10-23-native-fallbacks/paired-final.log) are retained.

```sh
FPR_SOFTFLOAT_ROOT=/path/to/softfloat python3 tests/check_rv32_float_constants.py --require-execution
python3 tools/bench-rv32-floats.py --against /path/to/previous-fpr --output /tmp/rv32-float-pairs --runs 31
```

## Remaining fallback inventory

The initial audit also identified plain RISC-V `--plugin` emission lacking
a native backend choice, RVV startup still carried by the old text emitter,
and hosted frame-size refusals. Those remain separate migration work.
This increment does not retire the complete old generator or close the
overall goal. The initial inventory log retains the failed pre-change cases;
it is not passing acceptance evidence.
