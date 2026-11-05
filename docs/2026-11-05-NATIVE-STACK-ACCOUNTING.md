# Native stack accounting

Codegen 178 adds `native-stack-v1`, a physical stack summary taken from the
allocated native instruction stream and its final frame layout. This is a
static-arena prerequisite. It does not yet admit an executable against a
whole-image memory budget.

[Codegen 179](2026-11-05-CALLBACK-STACK-BUDGETS.md) extends this to checked C
export frames and enforced callback stack budgets, and explicitly refuses weak
definitions that could be replaced at link time. The measurements below remain
the codegen-178 milestone record.

Since [codegen 180](2026-11-05-CALLBACK-HEAP-BUDGETS.md), ordinary builds request
these summaries with `--stack-report`. C exports and stack-budget admission
enable them automatically. An explicit report refreshes cached unit comments
without changing their identities or instructions; the stack solver is
unchanged. This avoids retaining unused analysis in ordinary compilations.

## Contract

Each selected function owns a structured `Codegen.Stack.Frame`, alongside its
assembly and instruction-segment report. The summary is not reconstructed from
assembly comments or source recursion depth. It records:

- The final stack footprint, including saved registers, spill slots, temporary
  objects, alignment and the incoming x86-64 return address.
- Direct generated calls with the caller's retained stack bytes. x86-64 also
  retains its eight-byte call-alignment slot.
- Tail transfers with zero retained bytes: the caller restores its entry stack
  before transferring. Tail-only recursive components use the largest member
  frame, rather than adding a frame on each iteration.
- Unproved runtime/foreign calls, generic argument packets, segmented-stack
  reservation shims and Darwin TLV boundaries. Missing generated definitions
  also prevent a bound. Neither a familiar symbol name nor a source annotation
  supplies a runtime bound.

The emitter composes all selected functions and specialized kernels in its
compilation unit and prints a summary for each code symbol:

```
# native-stack-v1: fpr_fn_leaf local=16 peak=16
```

The peak starts at the stack pointer immediately before entering generated
code. On x86-64 that includes the return address pushed by the incoming call.
Sequential calls use a maximum; nested calls add retained caller storage.
All selected paths are included conservatively. A recursive component with a
positive retained-stack edge is `UNPROVED`; there is no attempt to compose a
source decreasing measure with physical recursion yet. Tail recursion may
have bounded stack while running forever; this report proves no time bound.

Counts use arbitrary-precision integers. Negative frame/edge sizes and duplicate
code symbols refuse composition. Unknown reasons propagate to callers. The
analysis never removes a runtime check, changes an instruction, or suppresses a
trap in order to obtain a finite answer.

## Evidence

`NativeStack` independently enumerates all 19,683 three-node call graphs with
absent, tail and retaining edges and compares composition with a path-walk
oracle. Native selection tests cover AArch64, x86-64, RV32 and RV64, including
spill-heavy frames, ordinary and tail calls, recursive calls, missing imports,
foreign calls, generic application and panic paths. Hosted functions remain
unproved across their runtime entry checks. A synthetic runtime-free projection
tests their frame arithmetic separately; it is never published as an execution
bound.

`check_native_stack.py` executes the supported closed builtin subset on both
RV32 and RV64 emulators. It observes the stack pointer at each final frame
decrement using reserved scratch registers, with no added calls or stack space.
An assembly caller records the entry pointer and checks restoration. The C
harness checks returned values and independently measured stack high-water
against the predicted bound. Five programs cover a leaf, a two-level call, a
three-level call, a tail transfer and 24 live values forcing spills.

| Probe | RV32 predicted / observed | RV64 predicted / observed |
| --- | ---: | ---: |
| Leaf | 16 / 16 bytes | 16 / 16 bytes |
| Two-level call | 32 / 32 bytes | 32 / 32 bytes |
| Three-level call | 48 / 48 bytes | 48 / 48 bytes |
| Tail transfer | 32 / 32 bytes | 32 / 32 bytes |
| Spill-heavy caller | 144 / 144 bytes | 272 / 272 bytes |

The source-level integration check keeps ARC identity/printing entries
unproved across their reference-management/runtime calls, while the closed
nullary constructor has a finite bound. Compared with codegen 177, that source
fixture's emitted instructions and data are unchanged after removing comments.

All 40 Haskell suites pass. The unchanged cold compilation budget passes at
1.61/32.91/69.40 GB for hello/std-live/POS1; std-live remains close to its limit.
The C2 16–256-helper gate retains identical code bytes/function counts versus
explicit twins, with compiler allocation at 1.004–1.005 times the twins. These
are compiler/reporting costs, not runtime speedup measurements.
All 17 materializing-pipeline cases also pass, including their rollback modes,
effects/trap ordering, integer endpoints, imported capture allocation and
malformed-target refusal. The eight registry tests pass.

The test is registered in Base with the Cabal lock and in the RISC-V CI group
with execution required. Local emulator evidence is recorded in
[the stack probe record](../bench/2026-11-05-native-stack.json); registering CI
does not establish a remote CI pass. The
[validation record](../bench/2026-11-05-native-stack-validation.json) binds the
checks to compiler and source hashes.

## Remaining admission work

This bound is relative to generated-code entry and the selected unit's closed
call graph. Export adapters, interrupt save areas/nesting, linker-selected
definitions in other units, C/runtime frames, scheduler switches, startup and
stack growth need their own checked composition. A whole-image admission check
must bind those facts to the exact target and linked image.

Heap allocation, allocator rounding/metadata, peak live storage, region scratch
and representation-conversion allocations remain separate obligations. Source
work/result-size lemmas do not substitute for those physical facts. No static
arena budget is enforced by this milestone, and no scheduling latency, hardware
WCET or physical-board claim follows from the stack results.
