# Linear lists (`List 1`) across the FP-RISC apps — 2026-11-18

Question (Jack): are there places where a linear list `List 1` would help across the FP-RISC apps?

Short answer: yes, a few. But today there is no `List 1` to use. The two hot paths that matter (inventory journal replay and pos1 void) get most of the win now, without new compiler work. One uses the linear type that already exists (`MutMap 1`). The other just stops rebuilding the whole list.

Compiler: fprisc main f5a6bd9d (child of 54c812d8). Apps: terra-ii ca41f8d, hyperswine/inventory cba3771, fprisc examples/pos1.fpr. Also checked: dungeon 2d1eeab, logbook fea5c7d, printer 19870ba, grapher 018057d, qrepo 0fd3803. hyperswine's other repos are not .fpr.

## 1. What List 1 support exists on main

| Item | Status |
|---|---|
| `List 1` type / use-site multiplicity | **None.** It is an explicit non-goal: docs/2026-11-09-PERFORMANCE-PRIORITIES.md:359 says "Vector is the linear contiguous list". Linearity is nominal per type, and use-site `Map 1` is a non-goal (:362). |
| `--list-as-vec` | Rejected as a default (priorities :128, :354-358). It is not in the compiler. |
| VList-backed unique List | **Proposal only**: docs/2026-11-15-PARALLEL-MAP-FOLD.md "VList-backed linear lists" (f378f503). It describes Bagwell doubling blocks, chosen by the compiler when Reuse.hs proves uniqueness, frozen on escape, rolled out at step 2 behind a rollback flag. Open questions: the freeze point, flat Vector vs blocks, and interaction with Reuse twins. **No code exists.** Searching compiler/runtime for VList or Bagwell finds only an old comment in vec.c. |
| Linear types that do exist | `Handle 1`, `Vector 1 a`, `MutMap 1 k v`, `FixedMap 1 k v`, `SString 1` (core/prelude.fpr:16-40); `Client 1 s` in std/ownedmqtt and std/ownedtransport. The prelude `VList` Struct (~:726-749) is just ops over Vector. Checker: Frontend/Linearity.hs. |
| Automatic uniqueness optimisations | Reuse.hs: bounded uniqueness proofs and in-place spine reuse (`spineBuilders`); calls to public functions stay borrowing. Core/Opt/StoredLists.hs, list fusion (Core.Typed.ListFusion), TRMC (Trmc.hs; f5a6bd9d builds guard-clause accumulators front to back), loop regions with FPR_REGION_FLOOR = 1 MB. |
| Closest precedent | Frontend/OwnedMapFold.hs (54c812d8): a fold that builds an ordered Map is rewritten to a linear MutMap plus a single freeze (turn off with FPR_NO_OWNED_MAP_FOLD=1). A "fold builds a list keyed by id" rewrite would follow the same pattern. |

**Main blocker for MVU apps.** `update` keeps the old model alive:
- terra-ii game.fpr: `syncHint m msg m3` and `captured m m4`.
- pos1 and inventory live servers project `m` to sessions.

So during a step, every list reachable from the old `m` is shared. A uniqueness-driven List 1 would not fire there. Batch folds where the model is private do qualify: journal replay, pos1 boot/rebuild, and per-step locals.

## 2. Ranked candidates

"Today" means it can be written now with existing types. "Needs" names the compiler or std work.

| # | Where | Current pattern | Linear? | Expected win | Today / needs |
|---|---|---|---|---|---|
| 1 | inventory src/inventory.fpr:256 `replayed`, via putItem :187-194 and del :181 | The journal fold calls `findItem` (List.find), then `List.map` over every item per item line. `del` does `List.filter`, and re-parses `int "id" v` for every element. | Yes: during boot the model is private to the fold. | **Measured, see §3.** The list rebuild per line is the 1.96 GB boot RSS. | Today, either as tail-sharing recursion (A) or a `MutMap 1` id table frozen once (B). A future List 1 alone would only remove allocation, not the O(n) walk; the keyed table removes both. |
| 2 | fprisc examples/pos1.fpr:291 applyVoid (with findSale :297) | `m.sales \|> List.map markVoid` rebuilds all sales for each void. | Yes during replay/rebuild; shared in the live server. | **Measured, see §3.** | Today (tail-sharing `voidIn`). In place would need List 1 plus a unique model. |
| 3 | inventory :986 import dedup (`fresh = List.filter (… List.any … lower …) m.items`), plus :460 uniqueCi | Quadratic, and calls `lower` on both sides each time. | The accumulator is local and linear. | Import cost stays about 7.10 G Ir for 300 docs in every variant (§3), and import RSS is still +1.36 GB in B. This is the remaining ~4.5 MB/doc. | Today: a `MutMap 1` keyed on lower(name)\|lower(place), built once. Not prototyped. |
| 4 | inventory :609-610 rebuild (findItem per item), :679-694 project (filter/sort/length per render) | Repeated scans per render. | Not linear: render reads a shared model. | Medium for the live server. | A cache or index in the model. List 1 does not apply. |
| 5 | terra-ii actions.fpr:107-115 ageAll (`ageFx m.fx dt Nil`, ageMarks, ageNums, agePuffs) | Each tick does filter-map into a reversed accumulator. | Locally yes; the source lists are shared with the old `m`. | Small: the lists are short (effects). | Needs List 1 plus breaking old-model retention. Low priority. |
| 6 | Snoc appends: terra rules.fpr:149 `p.hand + [k]`, actions.fpr:21 `aiPlan m2 + [AEnd 1]`, input.fpr:214 `m.keys + [k]`, save.fpr:171 `m.out + [Out …]`, terminal.fpr:161; inventory :336 `List.append es [...]`, :442 `have + [t]`; dungeon dungeonrules.fpr:297, :517; grapher desktop/main.fpr:26 (+:30 take len-1, :67 length); pos1 :128-130, :267 | O(n) append to a model field. | The field is shared with the old model. | Small: all short lists. | Needs a linear list with O(1) snoc. A VList gives O(1) cons, not snoc. `Vector 1` works today where the field can become linear. |
| 7 | terra-ii prelude nth/setAt/delAt/takeAt; cards.fpr:80 shuffle via takeAt (O(n²)); rules.fpr:188-189 trim via len + delAt | Indexed ops on lists. | Shuffle is local and linear. | Small: rows are 5 slots, the deck is small. | `Vector 1` today for the shuffle. |
| 8 | qrepo text.fpr diffGo :35-46 (reverses both remainders on every mismatch, plus drop/take), editsGo :151-154, clusterGo :158-162, applyGo :165-167 (`L.concat (L.reverse …)`), mergeGo :189-204; qr.fpr:318 historyGo | Accumulate then reverse, repeatedly. | Yes: all local. | Medium on big diffs. Not measured (no workload). | Partly today: TRMC already builds guard-clause accumulators front to back, and restructuring diffGo avoids the repeated reverses. A List 1 builder would make the rest automatic. |
| 9 | pos1 :591 project `List.length m.sales` + takeN 50 each render; :152/:164 rev/seGo; :377-379 sessions filter | Per-render scans. | Not linear (render). | Small to medium. | Store the count in the model. Not List 1. |
| — | logbook, printer | List.length/List.append in views | — | Minor | — |

**Bonus, not List 1.** terra-ii game.fpr:57-63 `sameHintInput` builds `rowKey` tuple lists for both sides on every update and compares them structurally. In the earlier e4e8476c callgrind, `veq` was 27% self. Comparing per unit without building lists, or keeping a version counter, should remove most of it. Not prototyped.

## 3. Prototypes, measured (main f5a6bd9d, local only, nothing pushed to app repos)

Diffs are in [2026-11-18-list1/](2026-11-18-list1/).
- **inventory A** (`inventory-A-tailshare.diff.txt`): `replaceById` / `dropById` stop at the matching id and share the tail. This replaces putItem's `List.map` and del's `List.filter`.
- **inventory B** (`inventory-B-mutmap-replay.diff.txt`): when boot starts from empty items, replay folds `(model, MutMap 1 Int Item, id order)`. It writes items in place and builds the list once at the end; a deleted then re-created id is deduped. Otherwise it uses the original fold.
- **pos1** (`pos1-voidIn.diff.txt`): `voidIn` stops at the voided sale and shares the tail. Its signature is row-typed, because pos1 has no Sale alias.

Workloads:
- inventory: `member` boots on the 16001-line journal and adds a member. `import` boots and imports 300 Firestore docs.
- pos1: a batch driver runs `replayed` ×3 on the 23460-line log (1000 voids), then 2000 commit rings (200 voids).

Callgrind Ir is the median of 3 runs, at most 2 lanes. Wall/maxrss is the median of 5 interleaved runs on an idle box.

| Workload | base Ir | A / proto Ir | B Ir | base wall, RSS | A / proto | B |
|---|---|---|---|---|---|---|
| inventory member | 10,174,651,047 | 4,904,903,579 (**−51.8%**) | 1,071,676,967 (**−89.5%**) | 2.303 s, 1968 MiB | 1.519 s, 997 MiB | **0.191 s, 170 MiB** |
| inventory import (300) | 17,278,940,095 | 12,009,021,978 (−30.5%) | 8,175,882,057 (−52.7%) | 3.568 s, 3325 MiB | 2.876 s, 2354 MiB | 1.449 s, 1527 MiB |
| pos1 batch | 3,240,936,276 | 2,534,614,177 (**−21.8%**) | — | 1.127 s, 1187 MiB | 0.743 s, 621 MiB | — |

The run-to-run spread in Ir is under 0.01%. Import minus member is 7.10 G Ir in all three inventory variants, so the import path itself (candidate 3) is untouched and is now the biggest remaining cost.

Output equality checks:
- **inventory**, all 18 callgrind runs: stdout and the appended journal lines are identical once timestamps (`at`), salt/hash and run paths are masked. A separate dump driver printed every item row on inv-big.log and on an edge-case journal (moves, a no-op move, rename, delete then re-create id 2, a bad JSON line, an empty line, created=0, more than 3 moves, delete of a missing id, member). base = A = B, md5 eae7c3b9 and c788f4ca.
- **pos1**: stdout includes a digest of void count, sale numbers, voidAt and voidBy. Every run gives md5 f59de3c9.

## 4. Blockers and what would unlock more

1. **There is no List 1 or VList in the compiler.** Turning the 2026-11-15 VList proposal into code is a prerequisite for any automatic in-place list work. It is still undecided whether it should be flat Vector or blocks.
2. **MVU keeps the old model alive.** terra's `syncHint m msg m3` / `captured m m4` and the live-server session projections make model list fields shared during `update`, so candidates 5, 6 and 9 would not be unique even with List 1. Unlocking them needs an update shape where `m` is dead after `update` (diff hints computed before the step, or from a small key).
3. **Snoc needs a different structure.** VList is O(1) cons, not O(1) snoc. The snoc sites want `Vector 1` or a builder.
4. **Public calls stay borrowing** (Reuse.hs), so uniqueness does not cross module boundaries such as std/list map/filter.
5. **B duplicates the item/del logic of `apply`** in `replayOp`. Merging it into the app would need a shared helper, or a compiler rewrite in the style of OwnedMapFold ("fold building a list keyed by a field → MutMap + freeze"), which is the general way to do this.

## Files

- `2026-11-18-list1/*.diff.txt`: the prototype diffs.
- `inventory-dump-driver.fpr.txt`, `pos1-drive-driver.fpr.txt`: the batch drivers.
- `inventory-edge.log.txt`: the edge-case journal.
- `cgj.sh.txt`, `cgp1.sh.txt`, `bld.sh.txt`, `wall-l1.py.txt`: the measurement helpers, kept outside the app repos.
- `callgrind-results.txt`: the raw Ir figures.
