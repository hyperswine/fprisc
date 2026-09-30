# Failure-honesty follow-up

Date: 2026-09-30. Implementation follow-up to the tooling semantics and
SOL-EFFECTS audits. These are local source changes, not a release certificate.

## Changes and regression gates

- **Publication:** `fpr commit` invokes the normal native frontend in library
  check-only mode before writing any store blob or version binding. Type,
  named-hole, recursion/safety and linearity failures refuse publication. The
  shared check-only gate is after specialization and linearity, before codegen.
  Existing dependency blobs are retained when their AST identity is unchanged.
- **Import trust:** `Safety.hs` no longer blesses names merely because they
  contain `.` or `@`. The compiler has an explicit list of shipped library
  source files; QOS owns its extra list in `core/trusted-modules.txt`, resolved
  relative to that manifest. Paths are canonicalized once per compilation.
  Imported blanket `unsafe module.` markers are scoped to their module and
  cannot mark the importing program unsafe implicitly. An unmarked entry
  calling an untrusted imported unsafe function is refused in native and Sol.
  The existing local-main policy is retained. These source allow-lists are
  transitional trust configuration, not proof certificates.
- **Sol contracts:** the shared `Precond` pass runs before inference, including
  top-level `>` statements and struct fields. Unsupported predicates fail;
  undischarged supported predicates emit the same named runtime guard as native
  compilation. Inserting contracts also happens in the debug no-types path.
- **Sol cache:** the resolved trusted name set is part of the exact cache key;
  removing a trust entry cannot reuse a previously accepted warm artifact.
- **Atomic writes:** preserve the previous file's POSIX mode, including execute
  bits. Writes to symbolic links, including dangling links, are explicitly
  refused before queueing and checked again at replay. The link and its referent
  remain intact. Temporary output is removed if replacement fails. Writing
  through links would require referent-aware transaction locking and snapshots.
- **Baseline fixtures:** hosted sketches print their intended result explicitly;
  the shared `both.sol` fixture declares native base and uses ordinary `main`,
  so its bare-metal execution and hosted sketch agree with the profile rule.
  The JSON/CSV example explicitly drops blank records during cleanup, while the
  CSV parser retains its strict dialect and round-trip behavior.

`tools/failure-honesty-check.py` checks refused first and subsequent commits
without store/database mutation, named holes, linearity and recursion rejection,
imported unsafe functions and blanket declarations, local struct qualification,
trust-policy cache invalidation, positive/negative/imported preconditions,
unsupported predicates, executable mode preservation, and intact ordinary and
dangling symlinks after refusal. Divergent unsafe fixtures are never executed.
QOS `check-all.sh` includes this gate.

Additional active baseline fixes found by the complete sweep:

- NN's three over-general measured list signatures now state their actual
  numeric types; the full training example passes its held-out probes.
- RVV startup enables vector state before the first C instruction on every
  hart. GCC can vectorize `fpr_rt_init`'s prologue before its internal enable
  call; the old boot trapped on `vsetivli` at that entry. The existing RVV
  execution leg now passes all five fusion/write-back assertions. Scalar
  images retain the runtime's weak no-op enable hook.

## Verification

Freshly rebuilt compiler: focused failure-honesty checks, Sol output contract
(26 checks), Sol safety, transaction/recovery and module-cache/transaction suites
passed. A fresh native negative precondition probe also emitted the same
named failure as Sol. QOS's final complete sweep exited 0 with
`ALL LEGS GREEN`; its platform-specific skips and the unresolved 38/47 legacy
demo tally are recorded in `qos/docs/2026-09-30-FAILURE-HONESTY-ROUND.md`.

## Remaining boundaries

Commit checks current language correctness; it does not certify target cost or
compare inferred interfaces for version compatibility. Compatibility still uses
export arities, written signatures and constructor declarations. Library trust
remains an explicit source policy rather than versioned proof certificates.
