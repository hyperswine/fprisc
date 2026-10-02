# Function specialization: implementation and measured limits

Date: 2026-10-03. Kind: implementation record for
[the specialization plan](2026-10-03-SPECIALIZATION.md).

## Implemented

`compiler/Mono.hs` specializes lifted Core on statically known function
arguments, including partial applications with captures. Callback parameters
are removed from clones; their captures become ordinary parameters. A
backwards demand analysis follows callback forwarding through wrappers and
recursive groups. Clone identities are registered before their bodies are
visited, so mutually recursive loops converge to direct calls rather than
unrolling. Multiple callback arguments can be fixed in one clone.

The native Base pipeline runs this after safety, preconditions, linearity and
cost checking, before the existing inliner. Sol runs the same pass between
lifting and bytecode compilation. ARC retains its existing ownership pipeline.
Source-level resource proofs still describe the unspecialized program.

A callback alias snapshots its capture expressions once at its definition.
At a direct specialization site, argument expressions and callback captures
are evaluated once, left to right, in the original argument positions.
Alpha-renaming protects both callee locals and caller aliases from lexical
capture, including saving a global callback before shadowing its original name.
An escaping alias keeps its function value.

Imported definitions are available to the root pass. Clones live in the root,
and imported private lifts receive caller-private names before being copied.
Cached home units specialize only against their own definitions. Existing
exports and the runtime/module callable ABI remain available.

The default limits are 256 clones, 60,000 source Core nodes of cloned bodies,
12 levels of nested clone creation, and 64 native parameters. Exceeding a limit
keeps the original call. Recursive callback changes are conservatively declined;
there are separate tests for stability and budget refusal.

`FPR_NO_SPEC=1` disables the pass. Native unit tags, native run-cache keys and
Sol preparation-cache keys include the mode. `codegenRev` is 27, so existing
compiled archives must be rebuilt for the new compiler revision.

## What “no PAPs” means here

The pass removes PAP creation and indirect application from specialized
callback paths. It does **not** remove `pap_t` from the runtime. Runtime-loaded
functions, actor/runner callbacks, record-stored functions and otherwise
unknown calls retain the callable representation. This is the boundary stated
in the plan; changing it requires a different module and actor ABI.

Static global function descriptors are immutable objects and allocate nothing
per use. They remain for exports and general entry points, including unused
general higher-order entries beside specialized clones. Consequently, a whole
assembly file can still contain `fpr_applyN` even when its measured hot path
allocates no PAPs and calls only known functions.

This pass does not infer function identities through arbitrary returned values,
conditionals or record projections, or recursively specialize the identities of
function-valued captures inside another callback. A later flow-analysis pass
could remove more static cases. Budgets can also leave known sites general.

## Measurements

Apple M4/macOS. Compiler built from this change. On and off use the same source;
the off mode is `FPR_NO_SPEC=1`. Seven native executions per timing result;
every run checks the expected output. Times include process startup.

| Witness | Off | On |
|---|---:|---:|
| 1,000 captured callback uses, callback heap delta | 64,000 B | 0 B |
| Million captured callback uses, fastest run | 16.7 ms | 6.9 ms |
| Million captured callback uses, median | 18.4 ms | 7.1 ms |
| `bound_pipeline`, linked known partial-application sites | 10 | 0 |
| `todo`, linked known partial-application sites | 26 | 10 |
| `todo`, root known partial-application sites | 11 | 6 |

The million-use witness returns `500007500000` in every run. The fastest-run
ratio is 2.42x, the median ratio 2.59x. These are this witness's measurements,
not an end-to-end claim about interactive `todo` or general FP-RISC programs.

`FPRC_APPLY=1` reports per-unit native dispatch sites, known partial-application
sites and static descriptors, including cached units. A known partial site is
an emitted under-application of a global of known arity; an unknown dynamic
application can also allocate at runtime and is counted only as dispatch.
These are static emitted-site counts, including retained general entries,
not dynamic allocation or execution counts.

| RV64 emitted assembly ledger | Off | On |
|---|---:|---:|
| `bound_pipeline`, linked dispatch sites | 51 | 45 |
| `bound_pipeline`, root assembly bytes | 43,655 | 49,218 |
| `bound_pipeline`, root + linked unit assembly bytes | 496,439 | 585,037 |
| `todo`, linked dispatch sites | 85 | 74 |
| `todo`, root assembly bytes | 249,710 | 292,936 |
| `todo`, root + linked unit assembly bytes | 2,494,865 | 2,653,111 |

Assembly byte counts include symbol names, comments and static descriptors;
they are not executable text sizes. Specialization adds clones while preserving
general functions. The ledger makes that code-growth tradeoff visible.

## Verification and reproduction

- `python3 tests/check_specialization.py`: Core recursion, forwarding, lexical
  shadowing, dynamic refusal, imported lifts, callback-change refusal, clone
  count/node/ABI limits; native/Sol differential and warm mode-cache checks;
  capture effects and capture panic before a later effect; allocation ratchet;
  inliner enabled and disabled; RV64/RV32/A64/x64 emission.
- `python3 tests/check_base.py` and `FPR_NO_SPEC=1 python3 tests/check_base.py`:
  full Base suite, including the specialization leg. Local socket access is
  required by the descriptor-exhaustion leg.
- `python3 tests/check_case_growth.py`: shared case-fallthrough, captures,
  effects, linear ownership, 20,000 tail iterations and bytecode-growth gates.
- `make -s bare-metal-run PROG=tests/base/specialization.fpr`: RV64 QEMU
  execution, including imported map/filter/fold/sort and mutually recursive
  captured callbacks. RV32 and x64 were checked by emission, not execution.
- `tools/wcet-ratchet.sh tests/cases/bound_pipeline.fpr 200 rv64` and the same
  command for `tests/base/specialization.fpr`: both retain a program maximum
  of 116 IR instructions between safepoints.
- `python3 tools/bench.py --runs 7`: the full native performance ratchet
  passes against the existing host baseline; the baseline was not changed.
- `python3 tools/bench.py specialization --runs 7`, then the same command with
  `FPR_NO_SPEC=1`: reproduce the timed witness without changing a baseline.
- `FPRC_APPLY=1 ./fprc --target=rv64 examples/todo.fpr /tmp/todo.s`, then the
  same command with `FPR_NO_SPEC=1` and a different output directory: reproduce
  site diagnostics. `<out>.units` lists exactly the linked units.

The QOS `programs/system.fpr` WCET gate with this compiler is blocked before
specialization by existing module safety/signature errors (`write`, `close`,
`awaitFrom`, `boundary`, `reply`). It is not counted as passing evidence here.
The QOS compiler pin is unchanged. Interactive `todo` was compiled for the
ledger; no terminal-session allocation total is claimed.
