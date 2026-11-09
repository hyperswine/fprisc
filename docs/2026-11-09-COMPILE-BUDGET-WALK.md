# Compile budget back under its margin: specialize the typed walk

9 November 2026. The darwin compile budget (`tests/check_compile_budget.py`,
baseline recorded 2026-11-02) had been red since before P2: hello +10.4%,
std-live +10.5%, pos1 +4.8% with `FPR_NO_TYPED_LOWER=1`, and +12.4 / +12.8 /
+6.7% with the typed lowering. So removing the typed lowering alone could not
make it pass.

## Finding

`tools/compile_profile.py --flat` on the std-live program: the largest self
allocation was `Core.Typed.Walk.mapChildrenM` (13.6%), the generic one-level
traversal every typed pass uses (inline, callbacks, verify, erase, the typed
lowering's helpers). It is polymorphic in the `Applicative` and had no
`INLINABLE`, so every call from another module went through the unspecialized
version with dictionary passing: each `Const`, `Identity` or `State` traversal
allocated applicative closures per node.

## Change

`{-# INLINABLE mapChildrenM #-}` and `{-# INLINABLE mapUpdateM #-}`, so GHC
specializes them at each call site's applicative. Nothing they compute changes.

| program | before | after |
|---|---|---|
| hello | 1.65 GB, +12.4% | 1.47 GB, +0.1% |
| std-live | 33.75 GB, +12.8% | 30.68 GB, +2.5% |
| pos1 | 69.15 GB, +6.7% | 63.58 GB, -1.9% |

Peak residency stays within its margin (hello +9.9% against 25%). The budget
reports "within budget". The baseline is not re-recorded here; that stays the
owner's call.

Pipeline baseline (no metric drift, 23 behaviour contracts), baseline gate,
typed-lowering corpus (host, RV64, RV32, inlined closure), signature bridge,
policy D1/D2, compiler options, typed vectors, specialization differential,
stdcheck, 43 unit suites: pass; QOS guishell unchanged.

Measured and not taken: `INLINABLE` on `Core.Typed.Erase`'s `eraseFunction*`
and `Core.Typed.Close.closeFunction*` (the other exported `Monad m =>`
functions in the typed pipeline) saves 0.4-0.5 points more (hello -0.4%,
std-live +2.0%, pos1 -2.3%): their callers mostly use one monad already.

## Baseline re-recorded

At the owner's request the darwin baseline (`ghc-9.8.2 aarch64-apple-darwin`)
was re-recorded from 27b49d9: hello 1.47 GB / 47 MB peak, std-live 30.68 GB /
357 MB, pos1 63.58 GB / 496 MB. The 2026-11-02 baseline it replaces predated
the typed lowering; the new one includes it. Other environments' baselines are
unchanged.
