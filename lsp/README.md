# FP-RISC for VS Code

Language support for `.fpr` and `.sol`, maintained with the compiler in
[`fprisc/lsp`](https://github.com/hyperswine/fprisc/tree/main/lsp).
The Marketplace identity remains **jasen.fpr-lang**. Requires VS Code 1.82+.

## Version 0.8.0

- Moved from `hyperswine/fpr-vscode-2` commit `1dd7939` into this compiler
  repository. The original repository is retained; this directory is the
  maintained source for subsequent releases.
- Compiler checks are coalesced for 120 ms and limited to two processes.
  Successful checks are reused only while their source/input fingerprints,
  compiler identity and configuration match. Failed checks are retried.
- Saving a dependency checks affected open importers, including transitive
  imports, instead of every open importer. Workspace file creation, deletion
  and changes also update diagnostics. Missing resolution candidates, pinned
  store blobs, the prelude and explicit foreign declarations participate.
- Unsaved relevant buffers suppress disk-based checks. Edits cancel work and
  clear old reports; results are checked again before publication. Duplicate
  imported diagnostics are merged, and closed files have their diagnostics
  cleared. Shutdown terminates and reaps compiler children.
- Checks have a two-minute timeout and 8 MiB report limit. Cancellation escalates
  after one second if a compiler ignores termination.
- Compiler character columns convert to UTF-16 editor positions. Pinned-module
  navigation preserves whitespace inside strings rather than incorrectly
  treating changed literal values as the committed program.
- Corrected the VS Code minimum to 1.82, matching `vscode-languageclient` 9.
  The server reports the extension's actual version.

The new compiler's `--editor-json` check reports versioned diagnostics, actual
source dependencies and inferred top-level types for native FP-RISC and Sol.
Hover shows inferred types after a successful saved-file check; editing a root
or dependency clears those types until it is checked again. Local-variable type
hovers are not yet supported. Older compilers fall back to their text reports.

The dependency scan still includes missing source/store candidates so creating a
higher-priority module invalidates a cached check. Compiler-reported inputs are
also fingerprinted and tracked. Unknown flags or ambiguous import syntax disable
reuse. External libraries are revalidated on the next check; automatic file
notifications remain workspace-scoped.

Workspace symbols use an event-updated index across all workspace folders,
including unsaved buffers. Repeated queries do not rescan the directories. The
index skips generated/hidden directories and symlinks, limits discovery to 5,000
files of at most 1 MiB each, and returns at most 500 matches. A file-limit warning
appears in the language-server log.

The scanner now retains complete dotted definitions for outline, hover,
completion, navigation and highlighting. **The compiler currently rejects a
literal direct definition such as `mymod.x = 1.`** This editor change does not
add that language syntax or hide its parse error. Use the existing module/record
forms until direct namespaced definitions have defined compiler semantics.

## Version 0.6.4

- Hover and completion know the newer Sol surface: deferred values
  (`Proc.later`, `Deferred.out/trim/line/field`), `logTo`, the deferred and
  immediate Git natives (`NativeGit.headLater/tagAt/pushLater/commitNow`),
  `Proc.queryReplayable`, and the file, HTTP, pipeline and byte types
  (882 entries, up from 766). The `check` and `builtins` tests pass again.

## Version 0.6.3

- Finds an installed toolchain. VS Code started from the Dock or Finder does
  not get a login shell's PATH, so the Homebrew `fpr`
  (`brew install hyperswine/tap/fprisc`) was not found there. When `fpr` is not
  on PATH, the extension now tries `/opt/homebrew/bin/fpr`, `/usr/local/bin/fpr`,
  `/home/linuxbrew/.linuxbrew/bin/fpr` and `~/.local/bin/fpr`. The module home
  follows that executable to its SDK, so the editor reads the installed `std`.
- A project made by `fpr new` is a project root: the compiler check runs in the
  nearest directory holding `fpr.toml` or a `.fpr` store. That is where
  `fpr check` runs, so pinned imports resolve the same way in both.
- `test/discovery.js` covers both.

## Version 0.6.2

- Refreshes the compiler/prelude reference from 506 to 765 documented names,
  including I32/I64, typed vectors, death-aware receives, actor heap grants,
  state loops, interrupt/logging helpers and prelude constructors.
- Fixes truncated vector signatures and leaked Haskell names such as `tI32`.
  Shared names show the signature and contract for the active language, including
  Sol's unenforced actor heap grants and compatibility statistics.
- Adds hover lookup for qualified operators (`I32.+`, `Int.(==)`), list indexing,
  directives and scalar type names. Strings/comments and shadowed namespaces do
  not receive unrelated builtin hovers.
- Every generated entry has behavioral documentation or its source definition.
  Existing prose/definitions take precedence over historical design paragraphs;
  primitive summaries live in `tools/builtin-docs.js`. Signatures and name/profile
  inventories remain sourced from the compiler and preludes.
- `test/builtins.js` exercises 906 real LSP hovers across both languages, checks
  every public compiler table entry, and verifies generation fails on missing
  docs or unknown type syntax. Existing diagnostics, imports, semantic tokens
  and string/case-scope tests still run against the current compiler.

## Version 0.6.1

- Pinned imports resolve. `use "path#hash"` used to be looked up as a file
  literally named `path#hash`, so hover, go-to-definition and completion
  found nothing through any pinned import. The part before `#` is the path.
- A pinned import follows the compiler to the committed version: when the
  working file is missing, or its code is no longer the pinned version, the
  editor opens the copy in the project's `.fpr/store` (then the home's). A
  working file that differs only in comments or layout is still opened.
- The compiler check runs from the project root (the nearest directory with
  a `.fpr` store, else the workspace root). The compiler finds `.fpr/store`
  relative to where it runs, so a file in a subdirectory whose pinned import
  resolves only from the store used to show a false "hash mismatch".
- With neither `fpr.home` nor `FPR_HOME` set, the module home is the
  compiler's own (the directory its executable really lives in), as the
  compiler computes it, instead of the workspace root. The editor and the
  compiler now read the same std.
- `test/modules.js` checks this against a module committed with the real
  `fpr commit`.

## Version 0.6.0

- Compiler diagnostics. On open and on save the real compiler checks the
  file and its errors appear in the editor and the Problems panel: type,
  exhaustiveness, parse, safety (unsafe recursion), linearity, precondition,
  typed holes (as warnings) and unresolved imports. `.fpr` files run
  `fpr compile --check-only` with `fpr.checkArgs` (default
  `["--system=posix"]`; use `["--system=qos-portable"]` for QOS apps); `.sol`
  files compile to bytecode without running. Errors the compiler places in
  another file (an imported module, the prelude) are reported there.
- Placement follows the compiler: a column when it gives one, else the clause
  name from `in NAME:` on the reported line, else the definition the message
  names. A failed check whose output is not recognized is still reported, as
  one file-level error in the compiler's own words.
- The compiler is `fpr.compilerPath`, else `fpr` in the module home
  (`fpr.home` / `FPR_HOME`), else `fpr` on PATH. If it cannot be run the
  extension says so once. Turn the check off with `"fpr.check": false`.
- Checks read the saved file, so the diagnostics describe the last save.
  Saving a module re-checks the open files that import. A newer save
  supersedes a check still running. The scanner hints (unresolved names,
  unsafe calls) still update while you type.
- With the current FP-RISC compiler, `--check-only` accepts source modules
  without `main`: their definitions and imports receive the same checks and
  source locations as executable files. Executable builds still require
  `main`. This behavior lives in the compiler, so updating/rebuilding `fpr`
  fixes the false missing-main diagnostic without changing extension settings.
- `test/compiler-check.js` covers the report parser and runs the server
  against the real compiler.

## Version 0.5.5

- Opt in with `"fpr.unsafeCalls": true` to underline the function name at
  statically resolved unsafe calls, including imports, simple aliases, unsafe
  prelude signatures and blanket unsafe modules. Off by default; independent
  of unresolved-name diagnostics. Uses informational squiggles (theme-colored).
  Dynamic higher-order calls and inferred unsafe behavior are not analyzed.
- Strings that hold code that holds strings. `"{pad 6 " " "{n}"}"` is an
  interpolation with a string argument and a nested interpolated string; the
  grammars' interpolation rule knew neither a nested string nor a nested
  brace, so the inner `}` closed the outer interpolation and the rest of the
  file was highlighted as one string. Interpolations now nest to any depth in
  both grammars, and hold the expression rules (keywords, constructors,
  operators, path literals). The server's line scan follows the same rule and
  keeps its state across lines: names inside an interpolation are uses
  (definition and hover work there), text between interpolations is never
  scanned as code, and a `#` on a line inside a multi-line string is text, not
  a comment. `test/strings.js` is the regression.

## Version 0.5.4

- Adds informational diagnostics for unresolved expression names (normally blue
  squiggles; the theme controls the color). Disable with `fpr.unresolvedNames`.
  This is a best-effort scan: dynamic record fields, symbolic operators, and
  type-variable positions remain the compiler's responsibility. Names from
  external foreign declarations may need explicit declarations in the source.

## Version 0.5.3

- Highlights case-pattern variables and their uses within each arm, including
  tuple, list, record, and nested constructor patterns. Constructors keep their
  existing coloring; branch bindings do not leak into sibling arms.

## Version 0.5.2

- Highlights simple local `name = expression;` bindings and their subsequent
  references within the enclosing clause, including names that shadow builtins.

## Version 0.5.1

- Fixes semantic highlighting: builtin type names keep type coloring, and
  parameterless value definitions use variable coloring. Function clauses and
  explicit lambdas retain function coloring. Exact colors come from your theme.

## Version 0.5.0

- Highlights profile declarations, `if`/`then`/`else`, `and`/`or`, `Layout`,
  parameterized and linear types, qualified foreign signatures, float literals,
  typed holes, and `@Msg` / `@Model.field` literals.
- Adds completion for builtins, local declarations, and imported module members.
- Updates the generated reference from the compiler's type tables and both
  preludes. Includes machine primitives and AOT prelude record members; removes
  QOS device APIs that are now declared by QOS itself.
- Recognizes record type aliases, parameterized sums, layouts, and foreign
  signatures in outlines, hovers, and navigation.
- Resolves module imports from the importing file, then the configured home,
  then additional module roots. Open, unsaved imports take precedence over disk.
- Filters builtin hovers, completions, and semantic tokens between FPR and Sol.

## Module setup

When editing programs outside the compiler checkout, set **FP-RISC: Home**
(`fpr.home`) to your `fprisc` directory. Alternatively inherit `FPR_HOME`.
Set **FP-RISC: Module Paths** (`fpr.modulePaths`) for additional library roots;
`FPR_PATH` entries are also searched. Settings changes apply without restarting.
With neither home setting nor environment variable, the compiler's own home
is used (the directory its executable lives in), else the workspace root.
A pinned `use "path#hash"` opens the committed copy from `.fpr/store` when the
working file is missing or no longer holds the pinned code.
The compiler used for diagnostics is `fpr.compilerPath`, else `fpr` in the home, else `fpr` on PATH, else an installed toolchain's `fpr` (`/opt/homebrew/bin`, `/usr/local/bin`, Linuxbrew, `~/.local/bin`).

Imports try the current file's extension first, then the other supported
extension. Imported standard-library modules, including `std/live`, `std/term`,
`std/clock`, and `std/os`, are read directly from your configured source tree.
Their APIs are not advertised as globally available builtins.

## Refresh and test

```sh
npm run builtins
npm test
```

The default compiler location is the parent directory (`..`). Build `fpr`
there before running the full suite. For another checkout:

```sh
node tools/mkbuiltins.js /path/to/fprisc server/builtins.json
node test/check.js /path/to/fprisc
node test/current-api.js /path/to/fprisc
```

The generator reads `compiler/Infer.hs`, `compiler/Sol/Infer.hs`,
`compiler/Sol/Preamble.hs`, and `core/prelude.fpr`. Types come from the tables;
prelude record members without explicit signatures show their call forms.
Generation refuses unknown type expressions and missing documentation; add a
source comment or a reviewed primitive summary when introducing a new name.
Tests check generated-reference freshness, public AOT/Sol table coverage, grammar
patterns, and actual LSP requests against both fixtures and compiler modules.
A missing compiler checkout fails the checks rather than silently skipping them.

## Package, install and publish

Use Node.js 22 or newer. From anywhere, the repository helper installs the
locked dependencies, runs the complete suite against the compiler checkout,
and packages the extension:

```sh
/path/to/fprisc/tools/lsp-release.sh package
code --install-extension /path/to/fprisc/lsp/artifacts/fpr-lang-0.8.0.vsix
```

For iteration after `npm ci`, run `npm run package` inside `lsp/`. The VSIX
contains the client, server, grammars and production dependencies; it does not
bundle the compiler, tests, release tools or the rest of the compiler repository.
The CI job builds the matching compiler, tests the extension and retains its VSIX.

Publishing is explicit and uses the existing `jasen` publisher authentication
configured for Microsoft's `vsce` tool:

```sh
/path/to/fprisc/tools/lsp-release.sh publish --dry-run
/path/to/fprisc/tools/lsp-release.sh publish
```

The dry run performs testing and packaging without uploading. Publishing runs
the same checks and uploads that exact VSIX with `vsce publish --packagePath`.
It does not change versions, create commits/tags or install into VS Code.
Before each release, update the version and lock with
`npm version <version> --no-git-tag-version`, update these notes, and review the
package. The name and publisher stay unchanged so existing users receive
updates. No Marketplace publication is implied by a successful local package.

See Microsoft's [publishing guide](https://code.visualstudio.com/api/working-with-extensions/publishing-extension).

Between saves the language server is a lightweight source scanner; type
errors come from the compiler check on save. The scanner does not typecheck, infer generated codec members, enforce
Builtin/Base/ExtBase restrictions, or automatically load `--foreign` files.
The `.fpr` / `.sol` extension selects builtin availability. Compiler checks remain
the authority for language and target-system validity. Workspace symbol search
is limited to 5,000 files (1 MiB each) and 500 results, with unsaved-buffer overlays.

### Optimization remarks

Run **FP-RISC: Show Optimization Remarks** from the Command Palette for a
saved native `.fpr` file. It supports modules without `main`, compiles to
scratch assembly without linking or executing the program, and shows source
summaries in the **FP-RISC Optimization Remarks** output panel. Located
summaries also appear as Information diagnostics in open files.

This is an explicit command: it adds no emission run on open, save or typing.
The progress notification can cancel it; a new request supersedes the old
one. Source/configuration changes clear results. Dirty files or dependencies
and mismatched source fingerprints are rejected, so old positions are not
presented as current. The command needs an updated compiler with
`--remarks=json` and `remarkInputsVersion: 1`; it uses `fpr.compilerPath`,
`fpr.home`, module paths and compatible native `fpr.checkArgs` settings.

Inliner and callback messages describe pass attempts. A later pass can resolve
an earlier refusal, and a planned clone can be rolled back. These are advisory
performance explanations, not final-code guarantees. Definition-level locations
are intentional. Bytecode/Sol, ARC/raw, cost-manifest checks, automatic refresh,
inlays and expectation actions are outside this initial command.
