# Documentation: purpose, authority, and evidence

Kind: documentation policy and navigation guide. Status: working policy
for new and revised documents; existing pages may mix several roles.

Documentation preserves, communicates, or helps recover information about
a system, decision, process, or state. That broad description does not tell
readers whether a page is a promise, a report, a proposal, or a lesson.
State the role so readers know what they may rely on.

## Choose the role by the reader's task

| Kind | Reader's question or task | What the document provides |
| --- | --- | --- |
| Specification | What must a conforming implementation do? | Normative clauses, scope, versions, and observable requirements |
| Reference / lookup table | What does this name, field, flag, or operation mean? | Directly searchable signatures, mappings, errors, and constraints |
| Manual / how-to | How do I operate this or complete a task? | Prerequisites, steps, expected results, recovery |
| Tutorial | How do I learn this concept or workflow? | A guided progression and explanations |
| Example | What does a concrete use look like? | A runnable instance with its assumptions and limits |
| Explanation / rationale / decision record | Why does this design exist? | Reasoning, alternatives, trade-offs, and decision status |
| Goal / plan | What do we want, and how might we get there? | Desired outcomes, proposed work, dependencies, completion criteria |
| Record / log | What happened? | Dated actions, observations, and evidence |
| Review / status report | Where did the system stand when examined? | Findings tied to a revision, verification method, unresolved issues |
| Notes | What should we remember or investigate? | Provisional ideas and observations without implied commitment |

A lookup table is a retrieval format, not automatically a specification.
A manual can quote a requirement, but its example does not define all legal
behaviour. A review can recommend a change without adopting it.

## Independent axes

Describe a document by its subject, role, audience, applicable version or
revision, and status. Distinguish:

- **Normative:** what the implementation is required to satisfy.
- **Descriptive:** what a particular implementation or historical state does.
- **Instructional:** how a reader learns or accomplishes a task.
- **Proposed:** what might become a requirement after a decision.

Records primarily concern the past, references the applicable system, and
plans a desired future. A specification may concern a future release;
that does not imply the current implementation already conforms.

## How this applies to the repository

| Document or location | Primary role and qualification |
| --- | --- |
| [SEMANTICS.md](../SEMANTICS.md) | 2.0 contract workbook; distinguish its test-linked clauses from `(decide)` and empty-test proposals |
| [PLATFORM.md](PLATFORM.md) | Proposed language/Base specification framework and membership policy |
| [V2.md](V2.md) | Release goals and implementation plan, not a statement that planned work has landed |
| [STD-PLAN.md](STD-PLAN.md) | Library inventory at a stated revision and proposed organization/promotion work |
| [V2-AUDIT.md](V2-AUDIT.md) | Review evidence and dispositions at the revisions it identifies |
| [FPR-QOS-REVIEW.md](FPR-QOS-REVIEW.md) | Historical review; findings require rechecking before being presented as current |
| [INSTALL.md](INSTALL.md) | Installation and operation guide |
| [VERSIONING.md](VERSIONING.md) | Reference and procedures for module identities, locks, and releases |
| [TOOLCHAIN.md](TOOLCHAIN.md) | Dated development-machine inventory, not a minimum-version specification |
| [MEMORY.md](MEMORY.md) | Memory design/contract account with explicitly pending sections |
| [ESP-IDF.md](ESP-IDF.md) | Decision record for `--system=esp-idf` at a stated revision: choices, alternatives, workarounds; the build manual is machine/esp-idf/README.md |
| [MEMORY-V2-PLAN.md](MEMORY-V2-PLAN.md) | Migration plan and implementation records |
| [NOTES.txt](NOTES.txt) | Working notes; not an implicit extension of the contract |
| `fp-risc/programs/`, `fp-risc/tests/` | Programs and executable examples/checks; annotate the intended contract coverage |

The planned `docs/STD.md` and `docs/HAL.md` references are deliverables in
V2, not existing documents linked here. Existing narrative feature pages
can remain useful; give mixed sections their own status rather than
rewriting history into a current specification.

## Authoring and maintenance

For new or substantially revised pages, state the kind, scope, and status
near the top. Date or revision-stamp measurements, reviews, and records.
Use section-level labels when a page contains both current behaviour and
proposed changes. For example:

```text
Kind: reference
Applies to: <release/profile>
Status: implemented; evidence: <test or source>
```

Keep the requirement separate from evidence of satisfaction. Link accepted
contract clauses to tests and profile coverage; a passing example alone
is not a proof of all behaviours, and a filename in a test slot does not
show that the test has passed. Preserve SEMANTICS.md's existing promotion
convention while keeping pending decisions explicit.

When a proposal is adopted, update the authoritative contract, link the
implementation and validation evidence, and mark the plan's item complete.
When implementation disagrees with an accepted contract, record the gap;
do not silently turn accidental behaviour into a new promise. Historical
records retain their original scope and can link to a later disposition.

Put operational instructions in guides, searchable facts in references,
and intended guarantees in specifications. Link between them so readers
can retrieve an answer without reconstructing it from a development diary.
