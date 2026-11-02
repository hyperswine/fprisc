# Per-project managed toolchains in the editor

Status: implemented and packaged as extension 0.9.0, 2 November 2026.

The old editor resolved `/opt/homebrew/bin/fpr` to the manager binary, then
looked beside that manager for the compiler's `std`. It also cached one module
home across a workspace. A managed project could therefore compile through
the launcher while navigation searched a different directory.

`lsp/server/toolchains.js` now asks manager 0.2.0's read-only `which --json`
API from each project's directory. It leaves release selection and pin
validation in the manager. Checks, source navigation and optimization remarks
share the resulting compiler context. QOS uses its SDK's private compiler,
module roots, foreign declarations, compiler prelude and target; `.sol` scripts
use the ordinary FP-RISC manager.

The selection response is cached against project manifests, manager identity,
settings and installed-version state. Checks fingerprint the selected metadata
and compiler as well as source dependencies. Saving either manifest resets
selection. A lightweight one-second local-state poll detects external default
or installed-version changes and invalidates checks and remarks; it does not
spawn a compiler or manager on each poll. Missing versions produce an
install hint instead of selecting another compiler. Nothing is auto-installed.

## Using it

Leave `fpr.home` and `fpr.compilerPath` empty, install the needed versions with
Homebrew's managers, and open the project. **FP-RISC: Show Active Toolchain**
shows the release and selection source, compiler, module home, extra paths and
check flags.

Explicit `fpr.home`, inherited `FPR_HOME` and real `fpr.compilerPath` settings
remain developer overrides. Old checkout settings must be cleared to opt into
automatic package discovery. A nonempty `fpr.checkArgs` overrides target flags;
its new default is empty. Explicit extra module roots remain supported.
Manager-home environment overrides should be absolute paths.

The packaged VSIX is `lsp/artifacts/fpr-lang-0.9.0.vsix`; this task does not
publish a Marketplace release. The previous Marketplace version remains
independent of the local artifact. Install the VSIX explicitly to use this
candidate before a Marketplace release.

## Validation and limits

- The full extension suite passed, including source-generated builtin parity,
  scheduling, cancellation, dependency invalidation, editor metadata, source
  navigation and optimization remarks.
- `lsp/test/toolchains.js` covers different homes in one process, QOS isolation,
  explicit overrides, cached discovery, default/pin/metadata changes, missing
  version errors and actual checker execution.
- `lsp/test/managed-installed.js` ran against isolated installed FP-RISC
  0.12.0/0.13.0 and QOS SDK 0.3.0 with the published Homebrew managers. It
  checked per-project navigation, real FP-RISC and private-SDK diagnostics,
  missing-pin hints and automatic refresh after an external default change.

The installed-package checks were on macOS ARM64. Resource-specific VS Code
settings across multiple workspace folders, full compiler-backed navigation,
unsaved TOML pin selection and general external-library file notifications
remain separate work. Older compilers retain the existing text-report fallback.

The packaged VSIX also passed an isolated VS Code profile check: a real
managed compiler error appeared, a saved correction cleared it, navigation
opened the pinned installed `std`, inferred hovers showed `Int -> Int`, and
Show Active Toolchain ran. The user's editor settings and installed extension
were not replaced by this isolated check. `lsp/test/vscode-managed.cjs` is the
reusable extension-host test runner; it takes `FPR_EDITOR_TEST_WORKSPACE` and
`FPR_EDITOR_TEST_RESULT` paths. Release/check evidence is in
[evidence/2026-11-02-signed-managers-and-editor.json](evidence/2026-11-02-signed-managers-and-editor.json).
