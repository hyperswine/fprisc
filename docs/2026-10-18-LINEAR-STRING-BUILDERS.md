# Linear string builders: the renderer's runs and the Stream Reader

Date: 2026-10-19 (the page is dated 2026-10-18 to sit with the two allocation
pages it follows). Kind: implementation and measurement report. Applies to
FP-RISC `3e44148` plus this page's `std/view.fpr` and `std/stream.fpr`
changes, on branch `linear-string-builders`. QOS source `fd9d4bc`
(the Liveboard probe's copied source hashes to `f3830536dd54`, the same as
the two preceding pages).

This follows [the byte-string change](2026-10-18-RUNTIME-ALLOCATION.md) and
[CSS construction](2026-10-18-CSS-CONSTRUCTION.md), whose next priority was
"a linear builder". `String` is immutable and flat: `strcat` allocates and
copies both operands, so a loop that appends one piece per step copies its
accumulator per step and costs the square of its output. Four such loops in
the HTML renderer and two in the socket reader are now linear. Generated
HTML, CSS, render frames, the cached-fragment shape, the Reader's answers and
its failure order are unchanged; the one difference is that `readExactly`
of a negative count no longer truncates the buffered remainder (it answers
`""` and leaves the Reader as it was). No runtime primitive, ABI revision or
wire format changed.

## What changed

1. **The render context.** `Ctx` kept the static run in progress as one
   String that `emit` extended by `strcat` per emitted piece, so every open
   tag, attribute block and close tag re-copied the run. `renderStyled`
   seeds the run with the whole `<style>` block, so every element before the
   first `Dyn` re-copied the stylesheet as well. The run is now a list of
   pieces, newest first, joined once by `strJoin` when a `Dyn` ends it or the
   render finishes (a one-piece run is that piece, with no join).
2. **`esc`.** One `strcat` per byte, with one allocation per escaped byte
   (the plain bytes were already shared values). Runs of plain bytes are now
   copied whole by `substr` and the pieces joined once, as `jesc` already
   did; a text with nothing to escape is answered as it is.
3. **`splitSp`.** One `strcat` per byte of every word. Each word is now one
   `substr` of its run. The words are still answered last first: callers
   rely on that order, so it is now stated beside the function.
4. **`mediaGo` and `rules`.** The breakpoint rules were appended by `strcat`
   per rule; `rules` was right-recursive, so each rule copied all the rules
   after it. Both now build a reversed list and join once. `rules` was not
   on the list that prompted this page, but it is the same pattern two lines
   above `mediaGo` in the same stylesheet.
5. **The Stream Reader.** `untilGo` and `exactGo` concatenated every 64 KiB
   fill onto one buffer (`strcat buf more`) and cut the remainder out with a
   `substr` per delivered message: a message of n fills copied about n²/2
   fills. A Reader now keeps the pieces its fills delivered, newest first,
   behind a head piece and the offset of its first unconsumed byte. A fill
   is a cons. The bytes are copied once, into the message, when it is
   delivered; the piece the cut falls in stays whole behind its offset, so
   the remainder is not copied either. The separator search visits only the
   pieces that end past the already-searched prefix (`from`), so after a
   fill that is the fill itself and the tail of what preceded it; an
   occurrence that straddles a piece boundary is found in a window of the
   last `strlen sep - 1` bytes before the boundary and the first
   `strlen sep - 1` after it. A head consumed to its end with nothing behind
   it is let go, so an idle session's Reader holds nothing between messages.
   What a Reader can hold past a message is at most one fill, kept whole
   until the next read moves on: bounded, and smaller than the old buffer's
   remainder copy in every case the probe measured.

`Reader` is matched only inside `std/stream.fpr`; `std/ws.fpr`,
`std/httpcore.fpr`, `std/live.fpr` and the transports use it through its
functions and compile unchanged. `Node`, `Ctx`'s constructor name,
`ViewCache.Output` and the view wire format keep their shapes.

## Exact output

`tests/base/linearstrings.fpr` prints `esc` on empty, plain, escaped, leading
and trailing cases and on bytes 0 and 255; `splitSp` on empty, single,
multi-space and edge-space inputs; `media` and `rules` with matching,
non-matching, unknown and duplicate classes and with no classes; render
frames for an empty text, a lone `Dyn`, mixed `Txt`/`Dyn`/`LTxt`/`Inp`
children, `renderStyled` with a style block, cached fragments composed twice
and under a styled root, and a 130-element styled tree with slots. For the
Reader it reads one file through every operation across 64 KiB fill
boundaries: a `\r\n` whose bytes land in two fills, a three-byte separator
across a fill, `readExactly` across fills, `readUntilWithin` past its bound
(and that the error keeps its buffer), the empty separator, `readExactly 0`,
single-byte reads before a long line, `readLine`, `readRest`, the end of the
stream from every operation, and 100,000 lines through `readLine`.
`tests/base/linearstrings.expected` is that program's output under the
strcat-era library; the program built against the new library prints the
same 12,945 bytes on one and four workers. `tests/check_linear_strings.py`
holds that and the allocation budgets below.

`examples/logbook.fpr` was built before and after. Two entries were posted
(one with markup, an ampersand and quotes), then `GET /` (72,336 bytes), a
fresh session's websocket snapshot (5 statics of 45,197 bytes, 4 dynamics)
and a legacy client's first frame were captured from each build. With the
entries' minute stamp normalised (the two captures were a minute apart;
a second before-capture confirmed the stamp is the only moving part) the
page, the snapshot and the legacy frame are byte-identical:

- page `c6f089b14e976ad5…`, snapshot `3faa7132c60ef941…`, legacy frame
  `8d6bd071ecf0783d…` from both builds.

## Focused allocation ledgers

`tests/base/linearstrings.fpr` with `tests/bench/costprobe.c`, one worker,
bytes requested from the allocator between `Cost.begin` and `Cost.report`.
The inputs are built before the ledger opens.

| Operation | Allocated bytes before | After | Reduction |
|---|---:|---:|---:|
| `esc` of 16 KiB with an escape per 64 bytes, and 16 KiB plain | 276,013,824 | 90,912 | 99.97% |
| the same at 64 KiB + 64 KiB | 4,400,778,240 | 363,552 | 99.99% |
| the same at 1 MiB + 1 MiB | not run | 5,816,352 | |
| a 64 KiB `Txt` node rendered | 2,250,811,216 | 433,200 | 99.98% |
| a 1 MiB `Txt` node rendered | not run | 6,915,120 | |
| `splitSp` of 8,192 words | 1,966,080 | 786,432 | 60% |
| 2,048 breakpoint rules and 2,048 plain rules | 159,638,784 | 3,788,096 | 97.6% |
| `renderStyled`: 2,000 elements, a style block, 31 slots (156 KB) | 21,693,408 | 6,340,544 | 70.8% |
| `readUntil` of a 1 MiB line in 64 KiB fills | 13,113,840 | 3,156,544 | 75.9% |
| `readExactly` of the same 1 MiB | 12,064,576 | 3,154,896 | 73.9% |
| `Ws.receive` of a 1 MiB masked text frame | 67,903,776 | 57,880,576 | 14.8% |

The 1 MiB escapes were not run on the old library: the 64 KiB case already
asked for 4.4 GB. The 64 KiB `esc` ran 131,072 allocation requests before
and 5,121 after; the 1 MiB line through the Reader 150 and 219 (the pieces
and the one join). What remains in the Reader's 3.2 MB is the 16 fills from
the OS (1 MiB), the delivered message (1 MiB) and the read path's own
message copies, which `copy_bytes` reports unchanged at 11 MB: the reads
cross an actor boundary and that copy is not this page's subject.
`Ws.receive` is dominated by `unmask`, one allocation request per payload
byte (1,048,832 requests), also not this page's subject.

Budgets in `tests/check_linear_strings.py` are about twice these costs:
ceilings for a regression, not a claim about the old implementation.

## Real session workload

`tools/session-memory.py` against the sibling QOS checkout: three runs per
variant, alternating before/after, native macOS arm64, four workers,
`FPR_HEAP_MB=2048`, `FPR_COST_PROBE=1`, clients joining at 1, 10, 50 and
100 sessions. The before binary was built from this checkout at `3e44148`
before any edit and reused by hash for its second and third runs; the after
binary likewise. The copied Liveboard/probe source is byte-identical between
builds. All 100 clients received the shared update in all six runs.

Medians at 100 sessions:

| Metric | Before | After | Reduction |
|---|---:|---:|---:|
| Allocation requests | 561,755,500 | 561,246,868 | 0.09% |
| Cumulative allocated bytes | 34,878,364,352 | 30,732,806,832 | 11.89% |
| Peak RSS through the snapshot | 638.4 MiB | 566.9 MiB | 11.20% |
| Arena reserved at snapshot | 99.6 MiB | 99.6 MiB | 0.00% |
| Cumulative session admission | 4.020 s | 3.599 s | 10.47% |

Allocation requests did not move: the renderer emits the same number of
pieces, as list nodes now instead of strings, and the reader's messages are
small. Bytes moved, because the pieces are no longer copied per piece. At
1, 10 and 50 sessions allocated bytes fell 10.3%, 12.6% and 13.8%, peak RSS
18.1%, 11.7% and 12.0%. Peak RSS ranged 578.3–703.0 MiB before and
555.9–570.8 MiB after; admission 3.96–6.65 s before and 3.52–3.68 s after,
so the before ranges overlap the after ranges and the first before run was
the slowest of the six. The arena reservation did not change: this is
allocation churn and transient resident memory, not retained session state.
The timings are instrumented and do not establish an uninstrumented speedup.
Counter reads happen during concurrent work and are not an atomic census.

[Measurement data](../bench/2026-10-19-linear-string-builders.json) holds
every checkpoint of the six runs, the binary and source hashes, the focused
ledgers and the logbook capture hashes. Raw logs, binaries and captures
remain under ignored `build/session-*` and `build/lsb` in this worktree.

## Verification

- `python3 tests/check_linear_strings.py`: the fixture's 12,945 bytes equal
  the strcat-era record on one and four workers; every budget held.
- `python3 tests/check_view_construction.py`: byte-identical CSS, classes,
  render frames and cached fragments (125,308 bytes, SHA-256
  `9119d98d…` as on the CSS page) on one and four workers; all four
  allocation ledgers passed. Its frozen reference module builds the render
  context through the live `Ctx`, so its two seeds now start a run of
  pieces; the CSS functions it freezes are untouched.
- `python3 tests/check_viewcache.py`: unit invariants, stale/duplicate
  keys, the real Logbook in normal, verification and stateless wire modes,
  pagination/search eviction and session isolation passed.
- `python3 tests/check_byte_strings.py`: one and four workers passed.
- `python3 tests/check_std.py`: every module check passed, including
  `tcp` (2 MB echoed through `Stream`), `transport`, `http`, `httpclient`,
  `httplimits`, `posix` (three held streams, 3.9 MB through a pipe),
  `apps`, the terminal app and the live Logbook driven over its websocket
  (`std/ws` through the new Reader), and `poller_stop`. Two checks fail at
  HEAD `3e44148` before this change, identically in the untouched main
  checkout with the same compiler: `poller` prints "100,000 asks of an
  empty mailbox allocated 112 bytes" where its record says 0, and
  `examples/swarm.fpr` is refused by the linearity checker (`freeCols`,
  `advanceRecords`, `advanceCaptured`, `advanceCols`, `update`, `release`).
  The suite stops at the first failure, so it was run in three parts, each
  resuming after a known failure; the two failures are follow-ups, not
  this page's.
- `examples/logbook.fpr`: the page, snapshot and legacy frame captures
  above.
- The six session probe runs: every client received the shared update.

The full Base suite, the browser suites, FreeBSD and the boards were not
run. Publishing a compiler revision and repinning QOS remain separate steps.

## Not done here

- `jaGo` and `dGo` (`jarr`, `deltaJson`) still append by `strcat` per
  element; they serialise dynamic diffs, short in practice.
- `others` (attributes of one element) and `localStages` (seven scopes) are
  right-recursive `strcat` chains over short lists.
- `hasPrefix "{name}:" c` in `mediaGo` still builds the prefix per class.
- `Ws.unmask` allocates a one-byte piece per payload byte (shared values,
  but a list node each).
- The read path's copy of each fill across the actor boundary.

## Reproduce

```sh
python3 tests/check_linear_strings.py
python3 tests/check_view_construction.py
python3 tests/check_viewcache.py
python3 tests/check_byte_strings.py
python3 tests/check_std.py
python3 tools/session-memory.py --qos ../qos \
  --sessions 1 10 50 100 --output /tmp/session-linear
```

For paired runs, build the before binary from `3e44148` (or any checkout
with the old `std/view.fpr` and `std/stream.fpr`) and pass it with
`--binary` for its later runs; the profiler records the checkout's current
patches, which describe the checkout and not a prebuilt binary's build.
