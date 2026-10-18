# CSS construction without repeated suffix copies and decoding lists

Date: 2026-10-18. Kind: implementation and measurement report. Applies to
FP-RISC `d398f63` plus the preceding immutable-byte-string change and this
`std/view.fpr` change, on `codex/runtime-copy-20261018`. QOS source:
`796198d6396a61ca5b1966857f294744b8821ce3`.

This follows [the first allocation reduction](2026-10-18-RUNTIME-ALLOCATION.md).
The additional CSS changes reduce median cumulative allocated bytes by 27%
in the same 100-session Liveboard workload. Generated CSS, class names,
render frames and the cached-fragment representation remain unchanged.

## What changed

1. `atomClasses` joins the class names once instead of repeatedly copying
   the remaining class-attribute string.
2. `localStage` collects its nonempty rules and joins them once. Previously
   every class copied the remaining stylesheet, including classes whose rule
   was empty in that scope. This removes quadratic suffix copying.
3. Each stage constructs its scope prefix once. A byte check rejects other
   numeric scopes before matching the prefix. `hasPrefix` compares bytes
   without making a substring; its existing strict-length convention stays
   intact, including the empty-prefix cases.
4. `cssFor`/`renderStyled` retain typed declarations as `CssAtom` entries
   until emission. Their CSS is already available, so the renderer can use it
   directly rather than decoding its hexadecimal class name through
   `Encoding.fromHex` and temporary per-byte lists.

Entries deduplicate by the original class-name string, keeping the same last
occurrence as `nub`. Tree/attribute traversal and the seven precedence stages
keep their previous order. Explicit `Cls` values and cached `Fragment`
class-name lists become `CssName` entries and use the existing decoder path.
Uppercase hex, malformed names, duplicates and byte strings keep their prior
behavior. `Node`, `ViewCache.Output` and the wire format retain their shapes.
This is library code; it adds no runtime primitive or ABI revision.

The encoder still builds hexadecimal names, and duplicate detection still
scans lists. This patch removes the typed declaration's decoding round trip;
it does not eliminate every temporary list or repeated render.

## Focused allocation checks

The runtime already includes the previous byte-string optimization in both
variants. A small frozen reference preserves the old construction functions
without requiring Git history. The fixture compares 125,308 output bytes on
one and four workers, including DOM frames, scope order, typed/raw duplicate
classes, cached/fresh mixtures in both orders, and malformed/encoded fragment
classes. Both outputs have SHA-256:

`9119d98d67cab660377e5ac554473a30a10620a7866d326b907a600958e799cd`.

| Operation | Allocated bytes before | After | Reduction |
|---|---:|---:|---:|
| 1,000 prefix comparisons | 48,000 | 0 | 100% |
| Join 256 class names | 2,290,240 | 349,648 | 85% |
| Emit 256 CSS rules | 1,841,904 | 394,224 | 79% |
| Stylesheet for the 64-button typed tree | 2,470,064 | 1,581,488 | 36% |

The typed-tree check also reduces allocation requests from 39,834 to 31,607
(21%). The regression check verifies output equality and allocation budgets:
500,000 bytes for each 256-item join, and 2,000,000 bytes/35,000 requests for
the typed tree. These ceilings leave headroom above the observed costs and
permit future compiler improvements to the frozen reference too. It does
not assert wall-clock timing.

## Real session workload

Three sequential paired runs, alternating order, on native macOS arm64;
four workers, `FPR_HEAP_MB=2048`, `FPR_COST_PROBE=1`. Baseline: the frozen
executable from the preceding byte-string optimization with the original
view library. Candidate: that same runtime with the CSS changes. The copied
Liveboard/probe source is byte-identical between builds. Other builds/tests
from this task had finished before these paired runs.

All 100 clients received the shared `Bump 989789` update in all six runs.
Medians at the 100-session checkpoint:

| Metric | Previous byte-string version | CSS version | Reduction |
|---|---:|---:|---:|
| Allocation requests | 645,661,837 | 581,166,283 | 9.99% |
| Cumulative allocated bytes | 49,470,337,072 | 36,082,692,224 | 27.06% |
| Peak RSS through the snapshot | 730.9 MiB | 606.8 MiB | 16.98% |
| Arena reserved at snapshot | 100.25 MiB | 99.63 MiB | 0.62% |
| Cumulative session admission | 5.634 s | 4.353 s | 22.73% |

This mainly reduces allocation churn, not retained arena memory. Cumulative
allocated bytes are not live RAM. RSS varied between runs: 631.3–752.6 MiB
before and 556.7–640.5 MiB after, so the ranges overlap. Admission time ranged
from 5.127–8.179 seconds before and 4.177–4.373 after. These are instrumented
times, excluding explicit settling waits and the final fanout check; they
do not establish an uninstrumented production speedup. Counter reads occur
during concurrent work and are not a globally atomic heap census.

[Measurement data](../bench/2026-10-18-css-construction.json) includes all
1/10/50/100-session snapshots, executable/source hashes, ranges, medians and
the focused ledgers. Raw logs and frozen binaries remain under ignored
`build/css-paired-*` and `build/session-css-*` in this worktree.

## Validation and the protocol-test timing issue

- `python3 tests/check_view_construction.py`: exact-output differential,
  byte/fragment/precedence cases and all four allocation checks passed.
- `tests/check_view_utilities.cjs` with bundled Playwright and the installed
  Chromium headless shell: actual computed CSS, invalid-value refusals,
  inventory layout, responsive bounds, hover/focus, new cached styles,
  removal/reappearance, two tabs and preserved focused drafts passed. Live
  checks ran on one and four workers.
- A loaded QOS Portable application compared the new renderer with the
  frozen reference on a mixed typed/cached tree: one/four workers passed.
- The same comparison in a QOS Native RV64 kernel under QEMU passed on
  one/two harts.
- The complete view-cache suite and repeated v2/v3/legacy wire comparisons
  cover the real Logbook's normal, verification and stateless modes.

An initial stateless wire run failed an immediate equality assertion. A
diagnostic repeat found equal CSS/statics and rows, but a header still said
`3 entries, 3 online` while the other clients said `2 entries, 3 online`
after deletion. `Store.page` obtains the count/plan from the front actor,
then fetches rows from shards. A read overlapping deletion can therefore
carry an older count with newer rows. The old test waited only for the
row to disappear and the toast to be empty, which can accept that interim
frame before the command's completion event.

`check_live_wire.py` now requires the expected total and three connected
clients as well as the expected content and settled toast before comparing
the full protocol states. Its exact-equality and patch-format checks remain.
Three serial corrected stateless runs passed. Three control runs with the
frozen old renderer and the old predicates passed too; the failure was not
reproduced in those controls. The asynchronous-read explanation follows the
observed differing field and the store implementation, not a claim of a
reproduced old-renderer failure. No production store behavior was changed.

QOS builds and test sources were isolated under `build/qos-runtime-check`
and `build/qos-css-check`; the sibling QOS checkout/lock was not changed.
The full Base suite, FreeBSD and physical Pi/STAR64 deployments were not run.
Publishing a compiler revision and repinning/rebuilding QOS remain separate
steps before these changes reach the installed boards.

## Reproduce

```sh
python3 tests/check_view_construction.py
python3 tests/check_viewcache.py
python3 tools/session-memory.py --qos ../qos \
  --sessions 1 10 50 100 --output /tmp/session-css
```

Use a fresh output directory. For paired runs, retain the previous binary
and pass `--binary /absolute/path/to/liveboard-probe`. The profiler records
current runtime/std patches and hashes; those describe the checkout, not
the build provenance of an arbitrary prebuilt binary. The frozen baseline's
hash and expected source revision are recorded in the measurement data.
