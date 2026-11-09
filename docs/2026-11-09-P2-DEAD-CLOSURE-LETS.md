# P2 typed lowering: the dead closure lets

9 November 2026. Follows
[local closures over any arrow-free capture](2026-11-09-P2-TYPED-CLOSURE-CAPTURES.md),
which left 24 `optimized` functions classified "dead let removed, a closure
value": inventory (`rebuildCmd`, `withItem`, `putItem`, `moveCmd`, ...),
logbook (`project`, six `updateWith` clones) and pos1 (`giveLine`, `takeLine`,
`seGo`, ...).

## Cause

Logbook's `project` shows it. `sessOf` is inlined into `project`, and its
`List.find (fn s -> s.sid == sid) m.sessions` comes along. The typed callback
pass calls a clone of `List.find` with the capture (`$typed.mono.project.0`
taking `sid`), and the trim pass removes the clone's callback parameter. The
binding of the closure is now unused, but it stayed in the plan:

    let %3 = $typed_lifted_0.6.sessOf %0      -- dead
    ...  $typed.mono.project.0 %0 %4 ...

The erased `Mono` deletes it, so the two Cores differed and the function kept
the erased code.

`Callback.Trim` deletes an unused binding only if it is `removable` and its
value is pure. For a closure value, `pureValue` looked the code label up in the
graph of this root's own codes. An inlined function's lambda keeps its home's
code identity (`$typed_lifted_0.6.sessOf`); its code is a checked template from
the catalog, not in the graph, so the lookup failed and the value counted as
impure.

## Change

`pureValue` accepts a closure whose code is in the graph or is a closure-kind
template (`closureCode`, `closureArity` in `Core.Typed.Callback.Trim`). A
closure value is an allocation of already evaluated captures either way.
Codegen revision 207.

`tests/typed_core/inlined_closure.fpr` reproduces `project` (it prints 5);
`check_typed_lowering.py` requires its root to emit every S1 function typed.
Without the change the root reports `optimized=1` with the same dead let.

## Results

Attribution sweep (151 programs, host):

| kind | before | after |
|---|---|---|
| single-use let sunk, a closure value | 47 | 47 |
| dead let removed, a closure value | 24 | 0 |
| single-use let sunk (`normIn`) | 27 | 22 |
| let with 2-3 uses differs | 25 | 25 |
| dead let removed (plain) | 1 | 0 |
| plan application vs lowered application | 2 | 2 |
| `optimized` | 126 | 96 |

Five `normIn` sinks went too: in those functions the dead closure let was what
stopped the plan and the erased Core matching after the sink.

Typed 71,337 -> 71,369 in the sweep's per-program sum (s1 75,771, refused 0).
Assembly identical to `FPR_NO_TYPED_LOWER=1` on host 145/145 and RV32 128/128
(the same 6 and 23 programs fail as before). The 43 unit suites, typed-lowering
corpus (host, RV64, RV32 leg, the new inlined-closure check), pipeline baseline
and baseline gate, signature bridge, policy D1/D2, compiler options, typed
vectors, specialization differential and stdcheck pass; QOS guishell is
unchanged at 2,527/2,635 typed. Budget unchanged and still red: hello +12.4%,
std-live +12.8%, pos1 +6.7%.

## What is left in `optimized`

- 47 sunk closure lets: 42 `G.locals` lambdas over records of functions and 5
  `pageOf`; they need capture multiplicity in the ownership shapes (arrow
  captures keep their closure).
- 22 `normIn` sinks, 25 multi-use lets and 2 application shapes: the Core
  optimizer.
