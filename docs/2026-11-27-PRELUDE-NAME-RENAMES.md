# Four libraries rename helpers that clashed with the prelude (27 November 2026)

Kind: delivery record. Follows [2026-11-27-POW-AND-STANDALONE-SCRIPTS.md](2026-11-27-POW-AND-STANDALONE-SCRIPTS.md).

Each of these libraries defined a top-level value under a Sol prelude name. Sol refuses that on
purpose (a definition would join the prelude's, not replace it). Imported, the names are
qualified, so only compiling the library as a script failed. Owner decision: rename the helpers.

| Library | Was | Now | Callers updated |
|---|---|---|---|
| `sol/lib/build.sol` | `exists flag path` | `testPath flag path` | 46 `B.exists` calls across `tools/`, `machine/`, `tests/`, `scripts/`, `deploy/` |
| `sol/lib/git.sol` | `log count r` | `history count r` | `tests/gitquery.sol` |
| `sol/lib/webstyles.sol` | `input` | `inputField` | `sol/lib/ui.sol` (`input = S.inputField`; the field keeps its name) |
| `tests/sol-checks/helpers.sol` | `collect`, `write` | `finishJob`, `writeFile` | every check that calls `H.write` |

`helpers.sol` also defined `write`, which is a builtin with a declared type. The `collect` error
hid that clash until `collect` was renamed.

**For qos:** `tools/qlink-qemu-check.sol` and `tools/board.sol` call `B.exists` (three calls)
through the installed Sol bundle (`use "sol/lib/build"`). They must change to `B.testPath` when
qos's Sol pin moves past this commit. Until then they use the pinned bundle's copy.

## Checks

- Every changed script type-checks (`sol --asm`), and so do all 235 Sol scripts in the repo,
  except the two deliberately bad examples and `std/std.sol` (its `Numeric`/`List` structs miss
  the `Arith`/`Functor` signatures; this error predates this change).
- Sol check suite (CI-style): 38 run, none unexpected.
