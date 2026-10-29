# Sol: cached checking of imported libraries

Follows docs/2026-10-29-SOL-INCREMENTAL-PRELUDE.md. That change sliced the
prelude; libraries spliced by `use` were still type-checked, specialised and
lowered whole on every new script or REPL command (json+csv: ~43 ms of
typecheck, ~23 ms of bytecode).

## Contract

Same output, same diagnostics, same exit status as a whole compile. Any doubt
falls back to the whole compile.

## Design

* `expandUses` splices libraries ahead of the script, so the first
  `nLib = length expanded - length userTops` declarations are library code.
* Verdict key (`Sol.Cache.checkedLibraries`, under `<cache>/libchecks/`):
  cache schema (bumped to 6), executable identity, arch/os, the options that
  change checking (`SOL_NOTYPES`, `SOL_NO_SAFETY`, `FPR_HOME`, `FPR_PATH`,
  `FPR_NO_SPEC`) and SHA-256 of the binary-encoded library declarations plus
  trusted names. The spliced text already includes transitive dependencies,
  so their changes change the key.
* Establishing a verdict: the libraries are compiled **on their own**
  (no user code) with the prelude slice. Pass → `True`; any rejection →
  `False` (also cached, so such libraries are always compiled whole without
  re-trying). A library that only checks in the context of a particular
  program (e.g. `sol/lib/auth` needs a record shape the app defines) is
  therefore never trusted.
* Verified libraries: the prelude **and** the libraries are sliced from what
  the user part names (`SliceAll`); library record shapes are seeded from the
  whole libraries so shape ids match the whole compile.
* The sliced compile is still a trial with buffered diagnostics, deep-forced;
  any exception or `[hole]` note → whole compile, as for the prelude.
* Not used with `SOL_CACHE=0`, `SOL_NO_SAFETY`, `SOL_NOTYPES`/notypes
  pragma, `SOL_INCREMENTAL=0`, or `SOL_LIB_INCREMENTAL=0` (escape hatch).
  `SOL_INCREMENTAL=trace` reports verdicts and slice sizes.

## REPL fix included

Each REPL command recompiles the session text, but the module dedup table
from the previous command survived, so from the second command on a `use`d
module was aliased to a copy that was no longer spliced (`J.f` unbound).
The REPL now resets it per command. This also fails on main.

## Evidence

* `tools/sol-library-cache-check.py`: 171 differential cases (every library
  alone and all together, combinations, shadowing, type errors, unknown
  members, double `use`, context-dependent library, every tree file with
  `use`, shared cache, run output, edited-library invalidation,
  `SOL_NO_SAFETY`, REPL sessions) — identical asm/diagnostics/exit status
  against `SOL_LIB_INCREMENTAL=0`.
* Existing suites: sol-incremental-check, sol-repl-check, sol-ci.

## Numbers (median ms, first run of a new script, warm cache, x86-64 box)

| case | main 94f699b | this branch |
|---|---|---|
| hello | 32.6 | 33.1 (noise) |
| json+csv | 129.9 | 41.4 |
| cli | 153.6 | 46.7 |
| config | 189.9 | 49.8 |
| http | 67.6 | 32.7 |
| git | 66.3 | 33.8 |
| json+csv+cli+config | 216.9 | 60.8 |
| REPL, `use json` + 20 commands (total) | 1581–1759 (`SOL_LIB_INCREMENTAL=0`) | 691–694 |

json+csv phases: typecheck 42.6 → 2.7, bytecode 22.7 → 1.0.
