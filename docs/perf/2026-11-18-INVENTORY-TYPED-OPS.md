# inventory: journal ops as a sum type — 2026-11-18

PR: https://github.com/hyperswine/inventory/pull/2 (ari/typed-ops, ad339c2). It is stacked on #1 (ari/linear-replay); merge it after #1 or retarget it to main. Approved as its own PR (t155u).

## Change
- `parseLine : String -> Op` reads each line once into `Op = Put Item | Rename Item | Del Int String Int | Member … | Device … | Undevice … | Revoke … | OtherOp | Unreadable | Blank`.
- `apply` (which covers the live path through `commit`), the boot replay and `historyText` all pattern-match on it.
- The on-disk JSON is unchanged.
- Bad lines behave as before: blank changes nothing, not-JSON counts in `skipped`, an unknown op is ignored.

## Equality vs #1
- Item dumps, the live-apply driver and `historyText` are identical on the big journal, the edge journal and an extra edge journal ([inventory-edge2.log.txt](2026-11-18-list1-apps/inventory-edge2.log.txt)). The history check uses [inventory-hist-driver.fpr.txt](2026-11-18-list1-apps/inventory-hist-driver.fpr.txt).
- Member and import runs are identical once masked, and so is the import edge test.

## Tests
`sol project.sol test` passes, including a new round-trip check for all 10 kinds.

## Numbers vs #1
Instructions are the callgrind median of 3 on one lane. Wall time and peak RSS are the median of 5 runs at load 7–8, so the wall times are noisy.

| workload | #1 Ir | typed ops Ir | Δ | wall | peak RSS |
|---|---|---|---|---|---|
| boot + member | 1,070,834,473 | 1,077,280,002 | +0.6% | 0.196 → 0.191 s | 170.2 → 170.7 MiB |
| boot + import 300 | 1,103,345,080 | 1,108,383,852 | +0.5% | 0.211 → 0.201 s | 178.4 → 180.9 MiB |
| live apply, 16001 lines | 4,746,884,876 | 4,751,672,422 | +0.1% | 1.580 → 1.518 s | 993.3 → 994.5 MiB |

## Similar string-dispatch sites elsewhere (listed, not changed)
- **pos1** (fprisc examples/pos1.fpr, main 631b67e7):
  - :243-262 `applyW` dispatches the shop-log word with `strEq w "product" | "retire" | "staff" | "tax" | "lowat" | "price" | "restock" | "sale" | "void"`. This is the same pattern as inventory's journal: a candidate for a `Line` sum type parsed once in `apply` (:236-240).
  - :545-551 `runW` admin console commands (`help`, `get`, `set`, `add`, `retire`, `staff`, `rebuild`).
  - :564-568 `getV` keys (`tax`, `lowat`, `revenue`, `price`, `stock`).
  - :570-573 `setV` keys (`tax`, `lowat`, `price`).
- **terra-ii**:
  - src/save.fpr:26-28 `profFold`: profile lines `start` / `end`.
  - src/save.fpr:35 result word `"win"`.
  - src/save.fpr:170 `strEq text "none"` (a disk reply).
  - src/terminal.fpr:57-69 `termRun` console commands (`help`, `ls`, `get`, `set`, `hand`, `board`, `deal`, `place`, `clear`, `hit`).
  - src/terminal.fpr:76 `sideNo` (`"en"`).
  - src/terminal.fpr:84-102 `getP` paths (`env`, `tno`, `turn`, `seed`, … `prof played/won/lost`, `me|en hq/stock/hand/deck/fwd/rear`), plus `setP` / `zoneNo` alongside.
- **grapher**:
  - cli/main.fpr:12-21: argv matched against literal lists (`test`, `demo parabola|wave|stars`, `plot`). This is already pattern matching at the CLI edge, so it's low value.
  - desktop/main.fpr dispatches on `D.Key` codes, which are already typed.
- **qrepo**:
  - qr.fpr:1249-1258 (with `start` :1267-1272): `dispatch` on argv literal lists. This is already pattern matching at the CLI edge.
  - qr.fpr:1125-1146: the sync state is passed around as the strings `"conflict" | "behind" | "local"` and compared at :1145-1146. A strong sum-type candidate.
  - qr.fpr:242: the remote relation as `"same" | "ahead" | "behind" | "diverged"`.
  - qr.fpr:948-953 conflict kinds `"json" | "binary" | "text"`, compared at :1086 and :1094 (`kind == "text"`). These are also the on-disk conflicts.json format, so the parse would sit at the edge.
  - qr.fpr:1085 / :1095 `choice == "ours"`. :1085 already maps to `T.Pick`, and :1095 should reuse it.
  - qr.fpr:686 `why == "again"`, an error string used as control flow.
  - qr.fpr:868 / :888 / :899 `J.Text "directory"`, the stored entry kind.
  - qr.fpr:1119 change kind `"M"`.
