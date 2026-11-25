# Stdlib deprecations (v0.16.0)

The v0.15.0 stdlib consolidation (three merge passes on 24 November 2026)
renamed and moved a large set of `std/` modules with no compatibility
aliases. Apps that had not yet been updated — grapher (`std/bytes`),
qrepo (`std/osnet`), inventory (`std/viewcache`, the `std/browser*`
helpers, `std/livemetrics`, `std/appearance`, `std/pagination`) — stopped
compiling.

This release adds a one-cycle warning path so those old imports compile
again, and names the replacement. The aliases are **removed in v0.17.0**.
New code should use the replacement now.

The warning looks like:

```
warning: "std/bytes" is deprecated; use "std/binary" instead (removed in v0.17.0)
```

Pinned uses (`use "std/bytes#<hash>"`) are not rewritten; they still
resolve from the `.fpr` store when that exact hash is present.

## Merged modules (compiler aliases)

An unpinned `use` of the old path loads the new module and rewrites
imported names that were prefixed when the files were merged (so
`VC.many` is `cacheMany`, `Net.connect` is still `connect`, but
`Conn.read` is `connRead`, not the generic OS `read`). Because the
compiler rewrites the import, the shim is zero-cost: there is no wrapper
module in the image, and used-definitions-only compile (#120) sees the
same destination definitions as a direct import of the new module.

| Old module | Use instead | Renamed exports (old → new) |
|---|---|---|
| `std/bytes` | `std/binary` | (names unchanged: `new`, `put`, `get`, `pack`, `free`) |
| `std/dir` | `std/file` | (names unchanged) |
| `std/native` | `std/reload` | `attach` → `nativeAttach`, `loadAt` → `nativeLoadAt`, `loadVersionAt` → `nativeLoadVersionAt` |
| `std/ble` | `std/esp` | `scan` → `bleScan`, `advertise` → `bleAdvertise` |
| `std/wifi` | `std/esp` | `info` → `wifiInfo`, `scan` → `wifiScan`, `startAp` → `wifiStartAp`, `stations` → `wifiStations`, `stop` → `wifiStop` |
| `std/viewcache` | `std/view` | `Output` → `CacheOutput`; `empty`/`begin`/`output`/`fragment`/`item`/`fresh`/`many`/`manyGo`/`finish`/`retain`/`stats`/`size` → the same names with a `cache` prefix (`cacheEmpty`, `cacheMany`, …) |
| `std/logfile` | `std/log` | (names unchanged) |
| `std/durable` | `std/live` | `Store` → `DurableStore`; `open`/`save`/`close`/`log` → `durableOpen`/`durableSave`/`durableClose`/`durableLog` |
| `std/osnet` | `std/os` | (names unchanged) |
| `std/osio` | `std/os` | (names unchanged) |
| `std/osfs` | `std/os` | (names unchanged) |
| `std/oswatch` | `std/os` | (names unchanged) |
| `std/osconnection` | `std/os` | `adopt`/`begin`/`fd`/`status`/`read`/`write`/`close` → `connAdopt`/`connBegin`/`connFd`/`connStatus`/`connRead`/`connWrite`/`connClose` |
| `std/httpclient` | `std/http` | (names unchanged) |
| `std/httpcore` | `std/http` | (names unchanged) |
| `std/mqttclient` | `std/mqtt` | (names unchanged) |
| `std/mqttsession` | `std/mqtt` | (names unchanged) |
| `std/ownedmqtt` | `std/mqtt` | `create`/`begin`/`next`/`subscribe`/`publish`/`takeNotices`/`phase`/`close`/`stop` → the same names with an `owned` prefix (`ownedCreate`, …) |
| `std/resolver` | `std/transport` | `create`/`close`/`gate`/`nap` → `resolverCreate`/`resolverClose`/`resolverGate`/`resolverNap` |
| `std/sockettransport` | `std/transport` | `failure`/`handle`/`valid`/`readNow`/`writeNow`/`waitNow`/`release`/`now` → `socketFailure`/`socketHandle`/`socketValid`/`socketReadNow`/`socketWriteNow`/`socketWaitNow`/`socketRelease`/`socketNow` |
| `std/connect` | `std/transport` | (names unchanged) |
| `std/watchedtransport` | `std/transport` | `failure` → `watchFailure`, `wait` → `watchWait` |
| `std/browserautocomplete` | `std/browser` | `src` → `autocomplete`; `scope`/`from`/`prototypes`/`reset`/`onPointerDown` → `autocompleteScope`/`autocompleteFrom`/`autocompletePrototypes`/`autocompleteReset`/`autocompleteOnPointerDown` |
| `std/browsercalc` | `std/browser` | (names unchanged, including `Target`, `Id`, `mark`) |
| `std/browserconsole` | `std/browser` | `script` → `console`; `remembered`/`recallIndex`/`remember` → `consoleRemembered`/`consoleRecallIndex`/`consoleRemember` |
| `std/browserfeedback` | `std/browser` | `src` → `feedback`; `theme`/`prototypes`/`onPointerDown` → `feedbackTheme`/`feedbackPrototypes`/`feedbackOnPointerDown` |
| `std/browserformfill` | `std/browser` | `src` → `formFill` |
| `std/browsermedia` | `std/browser` | `program` → `media`; `programWithRetry`/`programWithReconnect`/`active`/`evaluate`/`phase`/`message` → `mediaWithRetry`/`mediaWithReconnect`/`mediaActive`/`mediaEvaluate`/`mediaPhase`/`mediaMessage` |
| `std/browserstorage` | `std/browser` | `script` → `storage` |
| `std/livemetrics` | `std/browser` | `script` → `metrics`; `milliseconds`/`ms`/`summary`/`initial`/`sent`/`reset`/`frame` → `metricsMilliseconds`/`metricsMs`/`metricsSummary`/`metricsInitial`/`metricsSent`/`metricsReset`/`metricsFrame` |
| `std/livenotice` | `std/browser` | `init`/`pending`/`adopted`/`adoptedAt`/`tick`/`expireAt`/`view`/`appearance`/`styles` → the same names with a `notice` prefix (`noticeInit`, `noticeStyles`, …) |

## Modules moved out of std (deprecated copies)

These files left std for `examples/`. An installed toolchain does not
ship `examples/`, so a deprecated copy remains in `std/` until v0.17.0.
It carries a `deprecated "…" .` pragma that prints the same style of
warning. New programs should copy the file into the app (as inventory
did) or, in-tree, import it from `examples/`.

| Old module | Canonical source |
|---|---|
| `std/appearance` | `examples/lib/appearance` |
| `std/pagination` | `examples/lib/pagination` |
| `std/gitrevision` | `examples/lib/gitrevision` |
| `std/mjpeg` | `examples/lib/mjpeg` |
| `std/money` | `examples/lib/money` |
| `std/printeralertcodes` | `examples/printer-dashboard/printeralertcodes` |
| `std/printeralerts` | `examples/printer-dashboard/printeralerts` |
| `std/printertelemetry` | `examples/printer-dashboard/printertelemetry` |
| `std/sessionauth` | `examples/printer-dashboard/sessionauth` |
| `std/checkdemo` | `examples/checkdemo` |

A test in `tests/sol-checks/std-deprecations.sol` requires the std copy
(minus its three-line preamble) to stay identical to the canonical file.

## Removed with no alias

`std/set` was deleted in v0.15.0 with the `Set` type, per the v1.0 core
spec. There is no compatibility alias. An unpinned `use "std/set"` is a
compile error that says so.

## Precedent

The warning-and-deadline shape follows the planned `sendArc` →
`sendFrozen` alias (same primitive, a compile warning naming the new
word, then removal) in [the v1 ARC amendment](2026-11-25-V1-ARC-AMENDMENT.md).
This change does not refuse `fpr commit` of modules that still use a
deprecated std import; the warning is the signal, and v0.17.0 is the
removal.
