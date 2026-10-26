# Compile-time budget

Date: 2026-10-26. A follow-up named by the
[structural checkpoint](2026-10-26-COMPILER-STRUCTURAL-CHECKPOINT.md): each typed
stage made compiling slower (a full Base sweep went from about 420 s to about
668 s on six workers), and `5ac6b4d` failed hosted CI when the POS application
passed its 180 s compile limit. This stage measures where the time goes, gates
regressions, and removes the three largest avoidable costs. Emitted code is
byte-identical throughout.

## Where the time went

Before this stage, on this Mac (Apple Silicon, GHC 9.8.2, cold caches,
`fpr compile --system=posix`):

| Program | Wall | Allocated | Peak live |
|---|---|---|---|
| `main = print 42` | 0.5 s | 1.2 GB | 11 MB |
| a program that only imports `std/live` | 26-29 s | 56.5 GB | 685 MB |
| `examples/logbook.fpr` (353 lines) | 42 s | 89.5 GB | 1.6 GB |
| `examples/inventory.fpr` (1070 lines) | 56 s | 100 GB | 1.8 GB |
| `examples/pos1.fpr` (952 lines) | 74 s | 136 GB | 2.1 GB |

An unused `std/live` import alone cost 26 s, so the cost scaled with the
imported units, not the program. GHC's profiler (late cost centres) on that
import put 28% of the time in A64 emission, 22% in region placement, 10% each
in typed inlining and callback specialization, and 8% in closing. Three
causes stood out.

1. **Register classes were parsed with `read`.** `Codegen.Target.A64`'s
   register file classified a register by parsing its name (`read d`) on
   every query, and the allocator asks for every operand: 22% of all
   allocation. The x86-64 and RISC-V files rebuilt and searched a name list
   per query. All three now answer from a digit fold or a table built once.
2. **Region checks re-walked the same types.** `receiveTurns` asked
   `Region.copyable`/`bounded` 78,054 times in one compile, each walking
   nominal declarations afresh (22 million substitutions). It now answers
   each interface type once per run, from a lazy map (`Type` and `Row` derive
   `Ord` for the key; `Eq` and `Show` are unchanged).
3. **Every unit re-transformed every other unit's constructor stubs.** Each
   linked artifact carries a stub for every constructor of the program (the
   inliner and the compatibility lowering read them); only the owner emits
   one, the others elide it. The specialize, inline, vector-read, normalize
   and fusion passes transformed every artifact's copies anyway: in the
   `std/live` compile the inliner processed 58,749 definitions, of which 5,511
   were owned. These passes now transform owned definitions and pass elided
   stubs through (`Core.Typed.Pipeline.ownedOnly`). Verification still covers
   every definition.

For (3), an instrumented build compared each elided stub before and after
every pass, by its derived `Show` text: specialize, inline, vector reads,
normalize and fusion changed **0 of 17,746** elided stubs on the `std/live`
compile, and the inliner changed 0 over all 180 unit-rounds of `pos1`. The
skip therefore returns exactly what the passes returned before; it is not an
approximation.

## After

| Program | Wall | Allocated | Peak live |
|---|---|---|---|
| `main = print 42` | 0.8 s | 1.77 GB | 28 MB |
| imports `std/live` | 19.2 s | 39.5 GB | 665 MB |
| `examples/logbook.fpr` | 25.7 s | | |
| `examples/inventory.fpr` | 40.1 s | | |
| `examples/pos1.fpr` | 49.9 s | 97.7 GB | 2.26 GB |

The profiled `std/live` compile went from 40.7 s to 24.5 s. Wall times are
single runs on an idle machine; allocation repeats exactly (three runs of the
`std/live` compile allocated 56.50 GB each, and run-to-run differences after
the change were about 0.02%). The hello row's allocation includes the
`profile base.` line its gate program adds.

Output: `examples/inventory.fpr` compiled by the saved pre-stage compiler and
by the new one produces identical files (57 each, the unit manifest compared
with its directory normalised) for x64, rv64, a64 and x64mac, and the
posix/a64 output matches its saved SHA-256 (`f01cf5c0...`). Unit file names
embed their cache identities, so identical manifests also mean unchanged
cache keys: the codegen revision stays where it was.

## The gate

`tests/check_compile_budget.py` compiles three fixed programs cold (hello, a
`std/live` import, `examples/pos1.fpr`) with `+RTS -t` and compares GHC's
allocation and peak residency with `tests/compile_budget.json`. Allocation
fails above +10%, peak residency above +25%; wall time is reported and never
gated, since runners differ. Baselines are per GHC version and architecture:
a different GHC allocates differently. `--record` writes the current
environment's baseline; record it in the commit that makes the compiler
cheaper, and the check says when a program is more than 10% under budget.

It is a Base job (`tests/check_registry.py`), so CI runs it. CI's environment
(Debian's GHC on x86-64) has no baseline yet: the check measures and passes
with a note there until that baseline is recorded from a hosted run.

## The per-pass report

`make fpr-prof` builds the compiler with GHC's profiler at `build/fpr-prof`
(late cost centres, so the -O1 code with a cost centre per top-level
function; its own build dir, `dist-prof`). `tools/compile_profile.py PROG`
compiles a program cold with it and prints the call tree with each stage's
inherited time and allocation; `--flat` lists the top cost centres. The
profiler attributes cost to the stage that does the work. Wall-clock timers
between the compiler's lazy stages would charge it to whichever stage first
forces a value, so the report uses the profiler instead.

## What remains

After this stage the `std/live` profile is flatter: A64 emission 20% (the
register allocator and its checker about 7%), region placement 17% (cost
analysis 7%, receive turns 6.5%), inlining 13%, specialization 12%, closing
9%, inference 6%. Within the linked passes, whole-program verification after
every pass and round is now a visible share (about 8% together), since it
re-checks the unchanged elided stubs each time. Erasure in `replaceClosed`
also re-erases them (3%).

Larger and separate: the compiler runs single-threaded (no `-N`), and units
are emitted one after another (`Compile.hs`, the unit loop), so a multi-unit
compile uses one core.

## Validation

`make fpr`; `make unit-tests` (26/26); the emission comparisons above. The
full Base suite passes **137 jobs in 610 s on seven workers** with no reused
coverage, including the new budget job, which ran under the sweep's
parallel load and matched its baseline allocation exactly (peak residency
-2.9% for pos1). Hosted CI follows the push.
