# Qualified signatures in the editor

Date: 2026-11-01. Extension: 0.8.1.

## Language contract

`MyMod.x : I64.` is a value signature: it declares the type of the qualified
symbol `MyMod.x`. Without a binding body, native FP-RISC treats it as an external
symbol supplied by the host/runtime when linked. It does not define a value or
create a record named `MyMod`. `MyMod.read : Int -> I64.` similarly declares a
function. A simple concrete example is `Os.connect` in `std/osnet.fpr`.

The shared parser accepts uppercase qualified signature names through
`signature`/`upperName`. It still restricts ordinary binding heads to simple
lowercase identifiers: `mymod.x = 1.` is not a supported definition form.
Existing `M = use "module".` aliases and `Int = Struct ...` members are other
uses of dotted expressions; those forms have their own definitions and rules.

Native module renaming deliberately keeps bodyless foreign signatures global.
If an imported file declares `MyMod.x`, native callers use `MyMod.x`, not
`M.MyMod.x`. Sol's module splicing differs: importing as `M` makes that signature
available as `M.MyMod.x`. The regression test checks both contracts against the
real compiler. Type checking does not prove that a runtime implementation exists.

## Editor fixes

Simple qualified signatures were already recognized in 0.8.0. This patch fixes
remaining cases:

- Multiline signature text survives in hover, completion and outline; an arrow
  on a continuation line still classifies the symbol as a function.
- Directly declared signatures override builtin completion details.
- Qualified signature declarations receive declaration highlighting.
- Foreign signature lookup follows reachable imports, preserving native global
  names and Sol alias prefixes. Local declarations take precedence. Unsaved
  imported text refreshes lookup, and closing the buffer restores the disk view.
- An unknown qualified member cannot accidentally resolve an unrelated bare name.

Import traversal is cycle-safe and bounded to 256 source visits, depth 32 for
native lookup and eight import levels for Sol. Results are shared only within
one request/notification; the next request revalidates module caches. This is
still a source scan, not compiler-backed references/rename. `--foreign` files
outside the source import graph are not automatically added to navigation.

## Validation and release

`lsp/test/qualified-signatures.js` covers local and nested signatures, multiline
function types, native/Sol transitive imports, builtin precedence, definition and
declaration navigation, semantic tokens, dirty imports and scope isolation.
The full package suite has 16 groups. Release evidence is recorded separately
in `docs/evidence/2026-11-01-editor-0.8.1-release.json`.

Use `tools/lsp-release.sh publish` for a tested package followed by a Marketplace
upload, or `publish --dry-run` to produce the same package without uploading.
