# Frontend ownership and compatibility

Date: 2026-10-25. Kind: implementation record. Applies to the cleanup on
`04206f1`; follows [the cleanup goal](2026-10-25-COMPILER-CLEANUP.md).

The frontend is no longer implemented in the FPRISC compatibility module.
The same grammar, surface constructors, scopes and lowering algorithms now
have explicit owners; this is preparation for carrying checked types and
binder identities through those stages, not completion of typed Core.

## Owners

| Module | Responsibility |
|---|---|
| `Frontend.Syntax` | Surface declarations, expressions, patterns, syntax types and stable Binary/NFData instances |
| `Frontend.Lexer` | Tokens, identifier rules, literal bounds and whitespace |
| `Frontend.Parser` | Surface grammar, including expressions, declarations, signatures and blocks |
| `Frontend.Normalize` | Profile inspection, eval desugaring and the greater-than-64-argument extension |
| `Frontend.MemoryLayout` | Nominal raw-memory layout expansion into declarations |
| `Frontend.Paths` | Typed paths and schema expansion |
| `Frontend.Desugar` | Surface-to-Core lowering, constructor/record layout and closure/join lifting |
| `Frontend.Traverse` | Scope-aware traversal and position erasure for module identity |
| `Frontend.Diagnostics` | Existing source anchoring and legacy diagnostic-rendering compatibility |
| `Frontend.Linearity` | Ownership checking over surface syntax and evidence |
| `Ownership.Shape` | Ownership vocabulary and substitution, independent of both ASTs and inference |
| `Core.Pretty` | Core rendering, independent of the frontend |
| `FPRISC` | Compatibility reexports only |

`FPRISC.hs` falls from 2,843 to 29 lines. Its exports and Sol.Lang's public
compatibility reexports remain available. Internal consumers import owners
directly. In particular, inference depends on syntax, traversal, ownership and
linearity, without pulling in lexer/parser or Core desugaring through the old
facade. `Type.Syntax` and `Ownership.Shape` can be consumed by future typed Core
without creating a dependency back into inference or the surface AST.

The split preserves original constructor order and Show/Binary behavior. The
surface cache instances retain their `-O2` compilation. Native cache revision
105 and the region ABI are unchanged by this refactor.

The module-identity comment now points to Frontend.Traverse and explains the
current parser marks, rather than claiming no position nodes exist. Structured
diagnostics, typed stage products and source positions through Core remain
unfinished work; moving their existing compatibility code is not their
completion.

## Validation

- `make fpr` builds the new module graph.
- `tests/check_frontend.py` checks the saved pre-split parser Binary checksum
  and module hash for a stable syntax fixture. The oracle was generated from
  the FPRISC definition at `04206f1`, not from the new implementation.
- That check also verifies compatibility API identity, Binary roundtrip,
  position-insensitive module identity, scoped transformations, diagnostic
  anchors/offset stripping, record ownership and duplicate-owner refusal.
- The prelude and three native/Sol source fixtures retain their complete
  parsed Binary bytes and module hashes against the pre-split implementation.
- Fresh assembly and dependent unit cache keys/content match byte for byte in
  128 cases across RV32, RV64, A64 ELF/Mach-O, x64 ELF/Mach-O, qx64 and qa64,
  including default, worker/reuse-disabled and fusion-disabled configurations.
- Full Base passed all **132 jobs in 409.29 seconds on six workers**, with no
  reused coverage. Existing platform/toolchain-dependent subchecks report
  their skips explicitly. The compiler source and binary stayed fixed through
  the run. Exact timing is retained in the JSON record below.
- Sol argument handling and the shared-language smoke passed. Measured self
  and mutual tail calls each completed 3,000,000 iterations under the memory
  ceiling (peak 86 MB), and the bytecode listing ends in TailCall.
- Local evidence: `/private/tmp/fpr-frontend-{baseline,parity}.log`,
  `/private/tmp/fpr-frontend-base.{log,json}`, `/private/tmp/fpr-frontend-sol-tail.log`
  and `/private/tmp/fpr-frontend-{before,after}/`. Hosted CI for this exact
  checkpoint runs after push; no physical board validation is claimed.

## Next evidence boundary

Inference currently returns checked Type values alongside rewritten, untyped
SExprs; the Type values for expressions and lexical binders are discarded.
A typed Core migration must preserve them at that handoff, then transform the
evidence deliberately through desugaring, generated joins/closures, region
helpers, specialization and workers. Re-inferring optimized bodies would not
meet that requirement. Separate term-identity supply from inference type-variable
supply so adding binder identities does not perturb diagnostics or schemes.
