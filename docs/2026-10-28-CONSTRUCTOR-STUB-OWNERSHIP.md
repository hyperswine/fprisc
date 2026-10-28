# Constructor stubs are owned by one artifact, not duplicated into all 39

Fixes plan item 2 (root cause §2.3) of `2026-10-27-COMPILE-SPEED.md`. On the
38-unit qos build: **cold 1.22× CPU (32.3 → 26.4 s), warm 1.15–1.19× CPU
(20.0/20.7 → 17.3 s), −15…−17% heap allocation, −21% cold max residency** —
with byte-identical emitted assembly for root and every unit.

## Problem

`nativeUnit` called `selectUnit (M.keysSet consAll) unit`, so `assemble` in
`Frontend.Desugar.Typed` generated a typed stub for **every** constructor of
the program (~320 in qos, 662 in pos1) in **every** unit's `NativeCore` —
12,480 constructor definitions across 39 artifacts. Each was closed,
re-erased (`eraseClosed` inside `replaceClosed`) and re-verified
(`verifyClosedProgram`) on every `Linked` pass, although `ownedOnly` already
skipped *transforming* them and `emitProgram` elided them at the end. A
profiled build (`make fpr-prof`, late cost centres) of a warm qos compile
showed the cost spread exactly across that repeated mass: Verify 10%+ self
time, `mapChildrenM` 4.8%, `freeVars` 4.0%, `eraseWith` 2.6%, and `GHC.Classes
Ord [a] compare` as the single hottest function in the whole compile
(`Data.Map`/`Data.Set` keyed on names, hammered per duplicated definition).

## Fix

Each artifact now carries stubs only for the constructors it **owns** (the
same ownership partition the elision sets already encoded):

- `Compile.hs`: `selectRoot` passes `rootCons`, the prelude unit passes
  `preludeCons`, dependency unit `h` passes `unitConsOf h`. The ownership
  block moved up next to `consAll` so both the selection and the artifact
  boundary see one definition.
- `Frontend.Desugar.Typed.assemble`: physical constructor arities now come
  from the checked type authority (`planTypes`, peeling `TFn`) instead of
  from the local stubs, so a unit that only *references* a foreign
  constructor still publishes the arity `linkArtifacts` cross-checks.
- Emission (`emitUnit`, root path): codegen reads constructor layout from
  erased stub bodies in its context (a nullary `CVar` constructor lowers to
  an immortal object, a saturated call gets its arity —
  `Codegen/Lower.hs:407-420`), so the erased stubs are materialized there
  from `consAll` (`erasedConstructorStubs`) and unioned into the program
  handed to `ready`/`emitCheckedProgramWithImports`. `elide` still keeps
  non-owned stubs out of the emitted text, exactly as before.
- The whole-program raw view (`compileRaw` → cost bounds, region context)
  keeps **all** stubs: `Cost.declaredBounds` costs constructor calls from
  their bodies.

No `codegenRev` bump: emitted code is unchanged. Unit cache identities shift
once for units that *reference* foreign constructors
(`Core/CacheIdentity` is reachability-based — it keeps reachable elided
stubs, precisely the inputs codegen can observe); units that reference none
keep their identity and were verified byte-identical after regeneration.

## Verification

- pos1: root `.s` and 49/49 paired unit `.s` byte-identical old vs new; the
  10 identity-stable units (no constructor references) regenerated and
  byte-identical.
- qos: root `.s` and 45/45 paired unit `.s` byte-identical, 0 differing.
- `make unit-tests` PASS; all 149 `check_base` jobs PASS;
  `check_compile_budget` within budget, baseline re-recorded
  (std-live −19.7% alloc/−33.2% peak live, pos1 −21.3% alloc/−70.5% peak
  live vs the previous baseline).

## Numbers (`bench/2026-10-28-constructor-stub-ownership.json`)

qos `programs/main.fpr --target=qa64`, ABBA pairs, load 3.2–4.1:

| | old | new | ratio |
|---|---:|---:|---:|
| Cold CPU (MUT+GC) | 32.33 s | 26.41 s | **1.22×** |
| Cold heap allocated | 60.2 GB | 51.3 GB | −14.8% |
| Cold max residency | 733 MB | 582 MB | −20.6% |
| Warm CPU, pair 1 | 19.97 s | 17.29 s | 1.15× |
| Warm CPU, pair 2 | 20.67 s | 17.34 s | **1.19×** |
| Warm heap allocated | 44.0 GB | 36.5 GB | −17.1% |

## What remains (compile-speed plan)

- Item 3 (§2.2): each `Linked` pass still re-erases and re-verifies the
  *owned* definitions of every artifact (`replaceClosed` → `eraseClosed`,
  `verifyClosedProgram` ≈ 30% of warm time combined). Next candidate: erase
  once at the end of the linked pipeline / verify only changed definitions.
- Item 4 (§2.2/§2.4): whole-program source reprocessing and `show`-based
  `hashAST` every invocation; persist checked unit interfaces.
