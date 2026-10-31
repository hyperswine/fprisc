# Editor integration, compiler reports and workspace indexing

Date: 2026-11-01. Kind: implementation and follow-up register.
Applies to extension 0.8.0 and the matching compiler changes.
Status: implemented; local validation recorded in the linked evidence. No Marketplace publication.

## Ownership and release

`lsp/` owns the client, server, grammars, generated reference, tests and release
tooling, imported from `hyperswine/fpr-vscode-2` revision
`1dd79391f18272ca1e856ebb60182bdd0832cb92` (0.6.4). Its MIT license and
`jasen.fpr-lang` identity are preserved. The sibling checkout remains unchanged.
The minimum VS Code version is 1.82, matching language-client 9.0.1.

The [recent workflow notes](2026-10-31-PROJECT-WORKFLOW.md) describe installed
compiler discovery already fixed in 0.6.3. Builtin reference freshness was fixed
in 0.6.4: all 882 entries now match the current compiler. The explicit command
from the [remarks plan](2026-10-27-OPTIMIZATION-REMARKS.md) is already implemented;
this change does not enable automatic code emission.

From any directory, with the compiler built and Node 22+ available:

```sh
/path/to/fprisc/tools/lsp-release.sh package
/path/to/fprisc/tools/lsp-release.sh publish --dry-run
/path/to/fprisc/tools/lsp-release.sh publish
```

The helper installs locked dependencies, runs the suite, and packages
`lsp/artifacts/fpr-lang-0.8.0.vsix`. Only `publish` without `--dry-run` uploads,
using the exact tested VSIX. Version changes and Git commits/tags are explicit.
The existing Linux CI job builds the compiler and packages an artifact; it does
not automatically publish. See [release instructions](../lsp/README.md).

## Compiler-owned editor report

Native `fpr compile --editor-json INPUT OUTPUT` implies `--check-only`; it never
writes OUTPUT. `fpr compile --target=bytecode --editor-json INPUT.sol` checks
without executing the script or producing a bytecode listing. Native checking
uses the ordinary pipeline. Sol uses its existing full checking path, bypassing
compiled-artifact caches so source/type metadata is collected for this run.
Normal compiler invocations retain their existing behavior.

The compiler emits one final JSON record on stderr, alongside ordinary human
output. Version 1 has:

- `editorVersion: 1`, `positionEncoding: "utf-32"`, `ok`, absolute `root`.
- `algorithm: "fnv1a-64-utf8"` and `inputs: [{file, digest}]` for consumed
  source contents. Native inputs include the selected prelude, foreign
  declarations and imported units. Sol's prelude is embedded in the compiler;
  its identity is covered by the executable fingerprint rather than a disk file.
- `diagnostics: [{code, kind, severity, message, file, start, precision}]`.
  Positions are zero-based. `precision` is `point`, `definition` or `file`;
  it deliberately does not claim an exact range where the checker has none.
- `types: [{file, name, type, start}]`, derived from existing inference results.
  Types are emitted only after all checking gates succeed, never on a failing
  safety, ownership or inference check. Disabling Sol inference yields no types.

Structured inference/safety/linearity diagnostics use the shared source resolver.
Legacy gates use an explicit adapter; unmigrated failures retain the human report
as a fallback. Import failures can still be file-level, and this is not a complete
AST or local-binder type protocol. The schema is defined in `Compiler.Editor`.

The editor validates schema/version, exit status and consumed-source digests.
Dirty buffers and stale reports are discarded. Compiler-reported dependencies
join the invalidation graph and successful-result cache. The conservative scan
still tracks absent resolution candidates; source manifests alone cannot detect
new files shadowing an import. UTF-32 columns become LSP UTF-16 positions, and
canonical filesystem paths are mapped back to the editor's URI spelling.
Older compilers that reject the flag retry their existing check command once.

Inferred top-level types appear on local and imported symbol hovers after a
successful check. Explicit annotations are retained. Edits to any relevant open
buffer clear inferred types. Local shadowing suppresses a global-type answer;
local binder types are not guessed.

## Scheduling, indexing and dotted names

Ordinary checks coalesce for 120 ms, run at most two compiler processes, and
reuse only successful results with matching source contents, compiler identity,
arguments and environment. Failures retry. Dirty relevant buffers suppress disk
checks. Timeout is two minutes; report limit is 8 MiB. Cancellation escalates
after one second, and shutdown waits for children. Imported diagnostics are
deduplicated, and closed files clear their squiggles.

Workspace indexing scans once per workspace-folder configuration, then updates
on file events and open-buffer changes. It supports multiple roots, encoded URIs,
create/delete events and changes with restored timestamps. Queries do not walk
the tree again. Discovery is capped at 5,000 files of at most 1 MiB, skips hidden,
generated and symlink directories, logs the file cap, and returns 500 matches.
Module navigation still uses its separate approximate source scan/cache.

Dotted definitions retain their entire name in scanner diagnostics, outline,
completion, hover, navigation and highlighting. However the current shared
compiler parser rejects `mymod.x = 1.`: bindings accept simple lowercase names,
and `mymod.x` expressions denote record projection or an imported module member.
This change fixes the editor's truncation of dotted names but **does not add new
language semantics or suppress genuine compiler parse errors**. Direct dotted
bindings need a separate compiler change defining record/namespace precedence,
local shadowing, nested namespaces, signatures, imports and emitted symbols.

Pinned navigation also preserves literal whitespace: it no longer treats two
sources with different string contents as equivalent to the stored pin.

## Validation and observed work reduction

The [machine-readable evidence](evidence/2026-11-01-editor-integration.json)
records the compiler build, test groups, packaged VSIX and isolated editor check.
Regression coverage includes native/Sol report parity and no execution/output,
real inferred hovers, metadata-only dependencies, same-size/restored-mtime edits,
dirty buffers, old-compiler fallback, invalid schema rejection, path aliases,
watch routing, process bounds, cancellation, module/store resolution and remarks.

| Scenario | Observed work |
| --- | --- |
| Twelve rapid requests for one file | One compiler run |
| Unchanged successful save | Zero compiler runs |
| Dependency change, unrelated importer | Zero extra compiler runs |
| Burst of six files | At most two compiler processes |
| 25 workspace symbol queries after indexing | Zero additional source parses |

These are deterministic work-count tests, not end-user latency claims. Local
validation is macOS arm64. Hosted Linux CI and VS Code 1.82 are not claimed as
executed. The user's installed extension is not replaced by isolated VSIX tests.

## Remaining work

- Direct dotted-binding language support, if desired; the compiler currently
  rejects it as described above. Full local-binder inferred types and richer
  source spans also require compiler metadata beyond the current report.
- Exact resolution-probe metadata, complete imported parse-error spans, and
  file notifications for libraries outside workspace roots. Such files are
  revalidated on the next check; the current graph conservatively over-approximates.
- Compiler-backed navigation and references/rename. Current lookup remains a
  source scanner, with conservative suppression around local shadowing.
- Remarks immediately after save can be cancelled by delayed file notifications.
  Improve cancellation feedback, then measure filters/lenses and package bundling.
  Expectation actions and automatic code emission remain deferred.
