# Haskell test suite and backend names

Date: 2026-10-26. Part of the [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md):
the "Validation ownership" and "Obsolete architecture descriptions and names" rows.

## The compiler is a library

`fp-risc.cabal` now has a `library` with every compiler module (`compiler/`)
and the `fpr` executable depends on it. The executable's source directory is
`app/`, whose `Main.hs` is a symlink to `compiler/Main.hs`: the file stays
where QOS looks for it (`qos.py` and `dependency.mk` use it to recognise an
fprisc checkout, and the Pi SDK copies it), and where the Makefile's plain-ghc
fallback compiles it. Cabal compiles the 177 library modules once and the
executable's `Main` against them.

The library keeps the executable's code options (`-O1`, `-O0` under the `dev`
flag), C sources, pkg-config and system libraries; the RTS options
(`-threaded`, `-rtsopts`, `-V0.001 -A64m`) stay on the executable.

Checked: `make fpr` builds; a cold compile of `examples/inventory.fpr` for the
posix system emits a byte-identical file (SHA-256 `f01cf5c0...`) before and
after the split, in 55-56 s both ways (one-run noise), so moving the modules
behind a package boundary did not change the compiler's speed or output.

## `make unit-tests`

Each Haskell check in `tests/` that needs no arguments is a cabal
`test-suite` (26 of them). `make unit-tests` builds them against the library
and runs them all; `make unit-tests UNIT=TypedCore` runs one. With a built
library the whole set takes about 20 s on six cores, against `runghc`
interpreting the compiler for each script.

- The suites use GHC2021, the language `runghc` gives the scripts
  (`TypedCalls` relies on its `FlexibleContexts`).
- `tests/Reuse.hs` and `tests/Workers.hs` became `ReuseCheck.hs` and
  `WorkersCheck.hs`: with `tests/` on a suite's search path, the old names
  shadowed the compiler modules they import. `check_reuse.py` and
  `check_workers.py` follow the rename.
- `Frontend` and `FrameEmitters` take arguments from their scripts
  (`check_frontend.py`, `frame_emitter.py`) and stay script-only.

The Python checks still compile and run these drivers themselves and still
own native execution; this stage adds the cabal entry point and does not
change them. Two drivers had no runner at all: `if-precedence-check`
(parser grouping) and `module-path-check` (module search order). Both pass,
and CI now runs them through cabal after `make fpr`. The other 24 already run
in the Base suite, so CI does not run them twice.

## Backend names

Comments in `Codegen/Lower.hs`, `IR.hs`, `Eval.hs`, `Frame.hs`, `Bounds.hs`,
`Kernel.hs`, `Verify.hs`, `Target/A64.hs` and `Target/Common.hs` named the
deleted legacy generator, `Codegen.inlineTable`, `Codegen.compileFnBody` and
the retired translators as the reference for current behaviour. They now
name the current owners: the lowering tables in `Codegen.Lower`,
`Core.Utils.floatLitBits`, `Codegen.Kernel`, `runtime/runtime.c` and the
generated-code calling convention. Where a fact's origin matters (the frame
shape, the `# wcet:` metric) the comment says the code it came from was
retired.

The stack policy constructor `StackCheckLegacyShallow` is now
`StackCheckShallow`, after its option (`FPR_TYPED_IR_SHALLOW_STACK`). It is
only pattern-matched, never shown, so no cache identity changes.

Kept on purpose: the `FPR_TYPED_IR_*` environment names and the refusal of
`FPR_TYPED_IR_BACKEND=legacy`. They are tested compatibility controls, which
the cleanup register says to retain.

## Validation

- `make fpr`; byte-identical emission and equal compile time (above).
- `make unit-tests`: 26 of 26 suites pass.
- `check_core_pipeline.py`, `check_typed_core.py`, `check_reuse.py`,
  `check_workers.py` and `check_compiler_options.py` pass with the renamed
  drivers and the library on cabal's package path.

No full Base sweep was run for this stage; its changes are comments, one
constructor rename and the build layout.
