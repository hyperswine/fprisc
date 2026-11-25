# Version names: the alphas, the 0.x releases and 1.0-rel (26 November)

Kind: owner decision (26 Nov 2026), recorded here. It names versions; it
changes no code and no tag.

## The decision

FP-RISC has used "1.1.0" and "2.0" for things that were never the 1.0
release. They are now named as alphas, and the release the
[v1.0 core spec](2026-11-19-V1-CORE-SPEC.md) defines is called **1.0-rel**.

| Name from now on | What it was called | What it is | Status |
|---|---|---|---|
| **alpha 1** | `v1.1.0` | The combined qos-fpr tree tagged on 10 Sep 2026 (`bdd5b848`, annotated tag "qos-fpr v1.1.0"), before the repositories were split. qos carries a tag of the same name and `release.toml` still reads `version = "1.1.0"`. | Superseded. A historical tag. |
| **alpha 2** | "2.0", "V2" | The plan written against alpha 1: [SEMANTICS.md](SEMANTICS.md) ("The contract for 2.0"), [V2](2026-09-12-V2.md), [V2 audit](2026-09-16-V2-AUDIT.md), [STD plan](2026-09-16-STD-PLAN.md), [Platform](2026-09-16-PLATFORM.md). Never released. | Superseded by the v1.0 core spec and the pages that amend it. |
| **0.x development releases** | `v0.12.0` to `v0.15.0`, `0.16.0` in the tree, `v0.17.0` planned | The numbered toolchain releases published through `fprmeta`. | Current. They lead to 1.0-rel. |
| **1.0-rel** | "v1.0", "1.0" | The first release under the v1.0 core spec, its amendments and the [v1.0 semantics](2026-11-26-V1-SEMANTICS.md). | Not released. |

## Rules that follow

1. **An alpha name is not a version number.** "alpha 1" and "alpha 2" take
   no place in the ordering of releases. The order is 0.12.0 < … < 0.15.0 <
   0.16.x < 0.17.x < 1.0-rel.
2. **The version field of 1.0-rel is `1.0.0`** (the cabal file and the
   `fprmeta` index take numbers only); its tag is `v1.0-rel`. Nothing may
   read the old `v1.1.0` tag as "newer than 1.0-rel": a tool that orders by
   tag must use the release index, which lists 0.14.0 and 0.15.0 only.
3. **Where an alpha page and a v1.0 page disagree, the v1.0 page is the
   rule.** An alpha page is still the record of what was true or proposed
   when it was written. Clauses of SEMANTICS.md that are still true are
   restated, with their evidence, in the v1.0 semantics page; a clause that
   is not restated there is not part of 1.0-rel.
4. **"The contract" means the 1.0-rel contract**: the core spec (types,
   layers, decisions), its amendments, and the v1.0 semantics page.
   SEMANTICS.md is the alpha 2 contract.

## Deprecation deadlines, mapped

Two deadlines were written against different names:

- the std module aliases and deprecated copies go in **v0.17.0**
  ([std deprecations](2026-11-25-STDLIB-DEPRECATIONS.md));
- the `sendArc` alias goes "before the v1.0 freeze"
  ([ARC amendment](2026-11-25-V1-ARC-AMENDMENT.md)).

With the order above, both are gone before 1.0-rel: 1.0-rel ships no
deprecated alias. Whether a 0.17 release happens before 1.0-rel, or 1.0-rel
is the release after 0.16, is not decided here.

## Not done

- The tags are untouched. `v1.1.0` keeps its name in fprisc and qos; adding
  an `alpha-1` tag beside it, or renaming it, is the owner's call (the
  fprisc tag is local and annotated).
- qos `release.toml` (`version = "1.1.0"`, "the next tag") is a QOS version
  and is not changed by this page; QOS needs its own statement of how its
  versions relate to 1.0-rel.
- "The freeze" and the exit criteria of 1.0-rel are still undefined
  (see the v1.0 review of 26 November).
- Older pages that say "v1.1.0" or "2.0" in passing are not edited.
