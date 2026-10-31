# FP-RISC projects: `fpr.toml`, `fpr new`, check, build, run, test, doctor

Status: implemented 31 October 2026 and merged to main, which is versioned
`0.13.0-dev`. Not yet in a release; the released 0.12.0 does not have it, so
a project created by main asks for `fpr = "0.13.0"` and 0.12.0 refuses it. This is step 2 of the
[installed toolchain roadmap](2026-10-30-INSTALLED-TOOLCHAIN-ROADMAP.md)
("small external-project workflow").

```sh
fpr new hello --template=cli      # or --template=service, --template=sol
cd hello
fpr check                         # every module, no main needed
fpr run -- Ada                    # build and run the entry point
fpr build --release               # build/release/hello
fpr test                          # the programs in tests/
fpr doctor                        # toolchain, C tools, SDK, caches, project
```

Explicit-file commands are unchanged: `fpr build prog.fpr`, `fpr run prog.fpr`,
`fpr sol x.sol` and `sol x.sol` never read a manifest, even inside a project.

## The manifest

A project is the directory holding **`fpr.toml`**. Project commands find it by
walking up from the current directory, so they also work from `src/`.

```toml
# fpr.toml -- an FP-RISC project
manifest = 1

[project]
name = "hello"
version = "0.1.0"
kind = "cli"            # cli | service | sol
entry = "src/main.fpr"

[toolchain]
fpr = "0.12.0"          # this fpr or a later compatible one

[target]
name = "host"           # host | linux-aarch64 | linux-x86_64 | linux-riscv64 | macos-x86_64

[dependencies]
# name = "vX.Y#HASH"    a committed version: fpr commit, fpr versions, fpr pull
```

| key | meaning |
|---|---|
| `manifest` | The format number. This toolchain reads format 1 and refuses any other. |
| `project.name` | Lower-case letters, digits, `-` and `_`, starting with a letter. It names the executable (`build/NAME`). |
| `project.version` | The application's own version. Recorded now; step 4 packaging will use it. |
| `project.kind` | `cli` or `service` (native executables) or `sol` (a script run on the Sol VM). |
| `project.entry` | The program file, relative to the root: `.fpr` for native kinds, `.sol` for `sol`. It may not leave the project. |
| `toolchain.fpr` | The oldest compatible `fpr`. The running `fpr` must be the same series and not older. While the major is 0, the series is major.minor, so `0.12.0` accepts 0.12.x. From 1.0 it is the major alone. A pre-release such as `0.13.0-dev` counts as the release it leads to (0.13.0), and `fpr new` writes that release. Otherwise every project command stops with status 2. |
| `target.name` | `host` (the default) or a `fpr build --target=` name. A `--target=` on the command line wins. A sol project's target is always `host`. |
| `[dependencies]` | `name = "vX.Y#HASH"`: a committed module version, as `fpr versions` prints it. |

The format is a small, strict subset of TOML. It has comments, `[section]`
headers, and `key = value` lines, where a value is a quoted string, an integer,
`true`/`false`, or a one-line array of strings. Every key is known. An unknown key
or section is an error naming its line, and the error says a newer toolchain may
know it. A typo or a newer section is never silently ignored.

**Extending it.** Roadmap step 4 will add tables for assets and service settings,
for example `[assets]` and `[service]`. A new table can stay format 1, because an
older `fpr` refuses the unknown key rather than building without it. The format
number goes up only when an existing key's meaning changes.

### Why `fpr.toml`, and the QOS boundary

QOS finds `qos.toml` by walking up parent directories. FP-RISC uses a different
name, and its own walk stops at a directory holding `qos.toml`, with this message:

```
fpr check: this is a QOS project (/path/qos.toml): build it with `qos build`; fpr projects have an fpr.toml
```

So `fpr` never adopts a QOS project. The other direction is QOS's walk. Avoid
nesting an FP-RISC project inside a QOS project's directory: `qos build` run from
inside it would still find the outer `qos.toml`.

### Dependencies

`std` and `sol/lib` come with the toolchain, so the toolchain version is their
identity. External modules are committed versions, made with `fpr commit` or
fetched with `fpr pull NAME.vX.Y`. They are pinned in source as `use "NAME#HASH"`.
The manifest records each one's identity (name, version, hash). `fpr check`
verifies two things for each:

- its source blob `.fpr/store/HASH.fpr` exists in the project;
- `.fpr/versions.db` does not bind that name and version to a different hash.

Nothing is fetched automatically, and there is no version solving. The roadmap
asks for useful workflows before a package manager.

## Commands

**When `build` and `run` act on the project.** They act on it only when no file
is named. That means the first argument that is not a flag (or a flag's value),
before `--`, decides. If there is such an argument, it is the existing
explicit-file command. `fpr build --target=qos-portable` keeps its QOS refusal.

| command | what it does |
|---|---|
| `fpr new NAME [--template=cli\|service\|sol]` | Writes a new project directory (`NAME` may be a path; its last part names the project). It refuses a non-empty directory or an invalid name. The default template is `cli`. |
| `fpr check [--fresh] [FILE...]` | Type and safety checks the entry and every `.fpr`/`.sol` under `src/` and `tests/`, generating no code. Then it checks that the native entry has `main`, and verifies the dependencies. |
| `fpr build [--release] [flags]` | Builds the entry into `build/NAME`, or `build/release/NAME` with `--release`. Other `fpr build` flags pass through (`--harts`, `--cc`, `--target=`, `-v`, ...). A sol project is refused: it is not built into an executable. |
| `fpr run [flags] [-- args]` | Builds and runs the entry, through the run cache. A sol entry runs on the VM. Program arguments follow `--`. The program keeps the caller's working directory. |
| `fpr test [-v] [FILE...]` | Runs the tests (below). |
| `fpr doctor` | Reports the toolchain, native build tools, caches and the project (below). |

**`fpr check` is not `fpr stdcheck`.** `fpr check` is the normal compiler's
checker over a whole project: parse, types, ownership, safety. It reports what
`fpr build` would reject, without generating code. `fpr stdcheck FILE` is the
separate std proof pass (intervals, measures, WCET) on one file. `fpr --help`
says so.

How `fpr check` checks each file:

- A `.fpr` file runs through `fpr compile --check-only` (the posix system), which
  does not require `main`.
- A `.sol` file runs through the Sol compiler (`sol --asm`, with its listing
  discarded).
- Imports are checked before their importers. A file that imports a failed project
  file is reported as not checked, so one error is reported once, not once per
  importer:

```
fpr check: src/main.fpr
    not checked: it imports src/greeting.fpr, which failed
fpr check: src/greeting.fpr
    === TYPE ERRORS ===
      * src/greeting.fpr:1: in greet: declared type of greet: cannot unify String with Int
fpr check: tests/greeting.fpr
    not checked: it imports src/greeting.fpr, which failed
fpr check: 1 problem, 2 not checked (3 files)
```

**`--release`.** The compiler has one optimization level, so `--release` does
not change code generation. It requires the toolchain's default code generation:
if an `FPR_*` code generation or cost-probe control is set in the environment, it
refuses with status 2 and names the variables to unset. It never ignores them.
Without that, a release could silently differ from what its manifest and toolchain
say. `--release` also works with an explicit file (`fpr build prog.fpr --release`),
with the same check.

### Exit status

| status | meaning |
|---|---|
| 0 | done: checked, built, every test passed, or doctor found no problem |
| 1 | the work was refused or failed: a diagnostic, a failing test, a problem doctor found |
| 2 | the command could not start: no project, an invalid or incompatible manifest, a bad option, a refused `--release` environment, a sol project given to `fpr build` |

A program run by `fpr run` exits with its own status.

## Tests

- **Where.** A test is a program file directly in `tests/`: `.fpr` (built and run
  like `fpr run`) or `.sol` (run on the VM). Subdirectories of `tests/` hold shared
  helpers and are not run. `fpr check` checks them all. A test imports the code it
  tests by path, for example `use "../src/greeting"`.
- **Pass and fail.** Exit status 0 passes. Anything else fails: a non-zero status,
  a trap, or a refusal by the checker.
- **Order.** Tests run one at a time, in name order, with the project root as the
  working directory.
- **No timeout.** There is no time limit, by design: a limit would be an arbitrary
  bound. A hanging test hangs `fpr test`.
- **Output.** One line per test, `PASS tests/x.fpr (0.21 s)` or
  `FAIL tests/y.fpr (exit 1, 0.18 s)`. A failure's output follows, indented; `-v`
  shows passing tests' output too. The last line is `fpr test: N passed, M failed`.
  Exit status is 0 when all passed and 1 when any failed. With no tests it says so
  and exits 0.
- **Helpers.** Two small libraries print one line per check, in the TAP shape
  `ok N - name` / `not ok N - name: why`:
  - `std/test`, for native tests: `Test.run [checks]` answers 0 or 1, and `main`
    returns it as the exit status.
  - `sol/lib/test`, for Sol: `T.run [...]` ends the script with status 1 when a
    check fails.

```
# tests/greeting.fpr
Greeting = use "../src/greeting".
Test = use "std/test".

main = Test.run (
     Test.equalString "greets by name" "hello, Ada" (Greeting.greet "Ada")
  :: Test.that "keeps an empty name" (Greeting.greet "" == "hello, ")
  :: Nil).
```

```
# tests/words.sol
W = use "../src/words".
T = use "sol/lib/test".

> T.run [T.equal "shout adds a bang" "hi!" (W.shout "hi"),
         T.that "an empty shout" (W.shout "" == "!")].
```

## Templates

Each template writes `fpr.toml`, a `.gitignore` (`build/`), an entry, one module
under `src/`, and one test of that module. Every template passes `fpr check` and
`fpr test` as written.

| template | entry | module and test |
|---|---|---|
| `cli` | `src/main.fpr`: greets its first argument, or `world` | `src/greeting.fpr`, `tests/greeting.fpr` |
| `service` | `src/main.fpr`: an HTTP server on 127.0.0.1, port 8080 or its first argument (0 picks a free port), until stopped | `src/routes.fpr`: a pure request-to-response handler; `tests/routes.fpr` tests it without a socket |
| `sol` | `src/main.sol`: runs on the VM; needs no C toolchain | `src/words.sol`, `tests/words.sol` |

Launchd/systemd setup, logs and data paths for services are roadmap step 4.

## `fpr doctor`

It prints four sections:

- **Toolchain:** the version, the real executable, and its home (`FPR_HOME` when
  set). It checks that `core`, `std`, `sol/lib`, `runtime` and `machine` are
  present, and whether this is an installed SDK (its `toolchain.json` revision)
  or a checkout.
- **Native builds:** the C compiler (`FPR_CC` or `cc`), its path and version line.
  On macOS it also shows the developer directory (`xcode-select -p`, marked
  Command Line Tools or Xcode) and the SDK (`xcrun --show-sdk-path`). On a Mac
  without developer tools it does not run `cc`, because that only offers to
  install them.
- **Caches and state:** the `fpr` cache (`XDG_CACHE_HOME/fpr`), the Sol cache, and
  the Sol recovery-state directory. The paths are resolved by the same functions
  Sol uses, and nothing is created.
- **Project:** the manifest found from here, its summary, and whether this
  toolchain is compatible.

Exit status is 0 with `no problems found`, and 1 when something is missing. Each
missing thing is marked `PROBLEM:` with the fix, for example
`xcode-select --install`. Sol needs none of the C tools.

## Evidence

- **Unit tests.** `make unit-tests UNIT=ProjectWorkflow` (`tests/ProjectWorkflow.hs`)
  covers: the render/parse round trip; comments and `#` inside strings; 18
  refusals (format, unknown keys and sections, duplicates, kinds, names, entry
  paths, targets, toolchain and dependency spellings, string syntax); version
  compatibility; when build and run act on the project; and that each template's
  manifest parses and names files it writes. 
- **Install check.** `tools/toolchain-install-check.py` stages the SDK read-only and
  denies the checkouts, GHC, Cabal, make and git, as before. After its native, Sol
  and cross steps, it now runs these in a project folder whose path has spaces:
  - `fpr doctor`;
  - the `cli` template through new, check, build, execute, `run` from `src/`,
    `--release` and test;
  - a failing test (exit 1, with its `want 5, got 4` line);
  - a failing module (exit 1, importers not checked);
  - an explicit file inside the project;
  - the `sol` template through check, run and test;
  - the `service` template through check, test and build;
  - the `qos.toml` refusal.

  Result on macOS arm64, 31 October 2026, after the follow-ups below and a
  merge of main: all 45 steps passed. The 23 existing steps stayed green, and
  22 are new: the first 19, then `project-check-cached`, `project-commit` and
  `project-run-pinned`. With `--qos /opt/homebrew/bin/qos`, all 47 passed:
  QOS Portable 0.2.0's `qos build` still selected its own hash-matched
  compiler. All 33 unit suites pass. See the
  [evidence](evidence/2026-10-31-project-workflow.json) (the `--qos` run).

## Follow-ups, later on 31 October

The first version left three gaps. All three are now addressed.

1. **The editor extension did not find an installed compiler.** It already
   resolved `fpr` from PATH and followed the symlink to the SDK's home. But VS
   Code started from the Dock or Finder does not get a login shell's PATH, so
   `/opt/homebrew/bin/fpr` was invisible to it. Its project root was also only a
   `.fpr` store directory. `fpr-vscode-2` 0.6.3 (`f7364a3`, pushed) does two
   things:
   - When `fpr` is not on PATH, it tries `/opt/homebrew/bin`, `/usr/local/bin`,
     Linuxbrew and `~/.local/bin`.
   - It runs the check in the nearest directory with `fpr.toml` or `.fpr`.

   Its new `test/discovery.js` covers both. The extension's `check` and
   `builtins` tests were already failing before this change: its builtin docs
   lack Sol names added since (`Deferred.*`, `NativeGit.*`,
   `Proc.queryReplayable`). That is still open.
2. **`fpr run` from a subdirectory missed pinned modules.** The compiler finds
   `.fpr/store` from its working directory (`Modules.loadModule`). Project
   `fpr run` now compiles in the project root (`Build.runMainIn`), and the program
   still starts in the caller's directory. The install check's
   `project-run-pinned` step proves it from `src/`. It commits a module, pins it,
   then edits the working file so that only the store holds the pinned code. An
   explicit `fpr run main.fpr` from `src/` still behaves as before: it fails to
   resolve the pin, because explicit-file commands are unchanged.
3. **`fpr check` cost a compiler run per file, every time.** Now:
   - **Cache.** A `.fpr` file that passed is remembered under a key of everything
     the check reads (`Build.checkKey`): the file and its whole `use` closure
     (as byte digests), the compiler's and prelude's stamps, `--foreign` files,
     `FPR_PATH`, the working directory and the flags. `--fresh` ignores the cache.
     Failures are never cached. Sol files are not cached; they take about 0.1 s.
   - **Parallel.** Files whose imports are settled are checked at the same time,
     one compiler per core.
   - **Shared closure walk.** `fpr run`'s cache key uses the same closure walk,
     which now also follows `FPR_PATH` roots and pinned store blobs.

   Measured on this Mac (10 cores):

   | project | before | first check | unchanged | one file edited |
   |---|---|---|---|---|
   | `cli` (3 files) | 0.7 s | 0.25 s | 0.02 s | |
   | `service` (3 files, imports `std/http`) | 2.7 s warm, 4.6 s cold | 3.2 s | 0.20 s | 1.2 s |

   A first check of the service template is not faster. One module checks
   `std/http` (1.9 s), and the two files importing it then run in parallel. A
   project-wide single compiler pass would remove the repeated import checking.
   That is a larger change and is not done.

## Known limits

- **Platforms.** Only macOS arm64 is qualified. The code has Linux branches
  (`doctor` without `xcrun`, Linuxbrew in the extension), but they are not
  tested here.
- **`fpr doctor --json`.** There is none yet; the editor could use it to show
  which toolchain it found.
