# Triage: the four checks red at 57201f0

Date: 11 November 2026. Kind: investigation record (decision 7 of
[the copy-out decisions](2026-11-11-COPY-OUT-DECISIONS.md)). All four were
already listed as red in the [CI baseline](2026-11-10-CI-GREEN-BASELINE.md).
Each fails identically on the unmodified `57201f0`, so none comes from the copy-out work.

`check_base.py` stops at its first failure, so one red job hides every job
queued after it. To run the rest, list the jobs and pass each with `--only`, through
bash (zsh does not split the argument string):

    bash -c 'python3 tests/check_base.py $(python3 tests/check_base.py --list | grep -v -E "x64_scalar|x64_qos|trmc_arc|check_trust" | sed "s/^/--only /")'

## check_trust: needs an approval

`std/fixedmap.fpr`, `std/mutmap.fpr` and `std/vector.fpr` were added on 9-10
November without an entry in `compiler/Safety.hs` `approvedLibraries`. The
check requires every std module to be listed. Adding the three lines is
mechanical, but the list grants trust, so it is the owner's approval, as the CI
baseline already noted. Not changed here. The change is three lines in alphabetical order:

    "std/fixedmap.fpr",   (after "std/file.fpr")
    "std/mutmap.fpr",     (after "std/mqttsession.fpr")
    "std/vector.fpr",     (after "std/ui.fpr")

## check_x64_scalar and check_x64_qos: rotate63's self-loop

`check_x64_qos` runs `check_x64_scalar`'s body for the QOS target, so this is one failure.

- **The assertion.** It fails in the second mode, `typed-ir-workers` (`FPR_NO_SCALAR_WORKERS=0`,
  self-loops on). It expects `rotate63`'s self tail call to become a loop, so that the
  stores to hart argument cells 8 and 448 disappear.
- **The actual assembly.** Both stores are present: `movq %r12, 8(%r10)` and
  `movq %r10, 448(%r11)`. The loop was not formed.
- **The mode is not the cause.** With fresh caches, `FPR_NO_SCALAR_WORKERS=0` and the unset default produce
  byte-identical assembly, and both keep the stores. So `rotate63` with its 64
  arguments is not turned into a self-loop on x86-64 in any mode.
- **Why the first mode passes is not established.** The likely reason is that the check parses a different titled section for the same function. A later change probably stopped
  forming the self-loop for a 64-argument function, and the first mode's pass may hide it.
- **Next step:** bisect with the check's own `rotate63` extraction, or read
  self-loop formation (`FPR_TYPED_IR_SELF_LOOPS`) for arities above the register and spill-cell boundary.

## check_trmc_arc: no TRMC worker under builtin ARC

- **The symptom.** The `values` program (`build`, `append` over `revOnto`/`reverse`) gets TRMC
  workers on builtin without ARC (`$worker.trmc.$trmc.5.build.0` and others) and none
  with `ARC=1`. `Compile.hs` admits `BuiltinArc` to the checked TRMC stage, and the
  stage declines silently: no note under `FPR_OPT_REMARKS`.
- **The likely cause.** Under ARC the program is erased and restructured (`$arc.mainManaged`), so the
  reverse-helper recognition (`Trmc.reverseHelpers`, from checked templates)
  probably no longer matches.
- **First bad commit:** `5e4f248a` ("Complete zero-overhead roadmap implementation
  and record target evidence", 4 November). Its parent on the ancestry path, `22e1e553`, and
  the check's own commit `a7f4fd6f` both form the workers.
  A plain `git bisect` from `a7f4fd6f` blamed a CI-only commit (`390eda69`) that is not a descendant of
  `a7f4fd6f`, because main and the TRMC branch ran in parallel; the ancestry path settles it.
  The commit is 497 files. The relevant part is the ARC product erasure: `compiler/Arc.hs` (+135),
  and new `compiler/Arc/Products.hs` and `compiler/Arc/Uniform.hs`. The likely
  mechanism is that the erased bodies no longer match `reverseHelpers`' templates.
- **Next step:** compare the checked templates of `revOnto`/`reverse` before and after the Arc
  product erasure, and give the TRMC stage a remark when it declines.

## check_live_runner: a timing flake

Not one of the four. Once, under the full suite's parallel load, it hit its
20-second `fpr watch` timeout. It passes run alone, and in the suite at `-j 4`.
