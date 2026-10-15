# The safety allow-list, reviewed: 36 std modules admitted, four apps compiled safe

Date: 2026-10-15. Kind: review and implementation record. Item 1 of
[2026-10-15-DESIGN-GOALS-AUDIT.md](2026-10-15-DESIGN-GOALS-AUDIT.md), the
first step of [2026-10-15-DESIGN-GOALS-REVIEW.md](2026-10-15-DESIGN-GOALS-REVIEW.md).

## What the list is

The safe/unsafe line ([2026-08-25-SAFETY.md](2026-08-25-SAFETY.md)) stops
its taint at the library boundary: a module on `approvedLibraries`
(`compiler/Safety.hs`) is the vetted set, whose recursive internals are
marked `unsafe` honestly but whose public functions may be called from safe
code. A module OFF the list is checked as if it were part of the program,
so every public function of it that sits over a marked helper is refused
in a safe program. 36 of 88 std modules were off the list; the three
applications carried `unsafe base.` at the top, which switches the whole
check off, and so nobody saw it.

## The review

Every `unsafe`-marked function in the 36 modules was read (the dump is
reproducible: the `: unsafe` signatures and their clauses). They fall into
three kinds, all of which the modules already on the list contain:

| Kind | Modules | What the helpers are |
| --- | --- | --- |
| Structural recursion over data | browsercalc, browsermedia, clientcalc, javascript, mqtt (`utfGo`, `continuation`, `filterLevels`, `decodeFrames`), printertelemetry (`scan`), reloadcatalog, sessionauth, watch (`forward`, `findCandidate`), httpclient (`controls`, `tokenGo`, `fieldValue`, `digits`, `firstDelimiter`, `hexGo`) | an index advancing to `strlen`, a list consumed, an AST walked; a measure would prove each, and none has one yet |
| I/O loops bounded by a budget and a limit | httpclient (`line`, `headers` with count <= 100, `untilEnd`, `chunked` with chunks < 65536, `response` with interim < 8), mjpeg (`headerGo`), transport (`someGo`, `exactGo`, `writeGo`: zero progress is a `DriverViolation`), connect (`attempts` over the address list, `establishing`), crypto (`await`), resolver (`resolving`), tls (`drive`) | each step either makes progress toward a stated limit or waits under `R.gate budget`, which refuses when the deadline passes; this is `std/stream`'s `readGo` shape, already on the list |
| Actor loops that run until stopped | readiness (`begin`, `waker`, `waking`, `loop`), watch (`watch`, a poll every 300 ms) | servers by design, as `std/poller` and `std/tcp` are |

Eighteen modules have no `unsafe` function at all (appearance,
browserautocomplete, browserconsole, browserfeedback, browserformfill,
browserstorage, gitrevision, livemetrics, livenotice, livereload, money,
mqttclient, mqttsession, native, osconnection, reload, sockettransport,
watchedtransport); they were refused only through the modules they call.
`checkdemo` is a demonstration of the cost checker with an intentionally
unsafe `main`.

Nothing found asks for more than the list already trusts, so all 36 are
admitted. The list now holds every std module, and `tests/check_trust.py`
(run from `check_base.py`) refuses a std module that is not on it or an
entry whose file is gone. A new module is admitted by adding it to the
list AND a line to the table above saying what its unsafe helpers are.

## What was not done, on purpose

Admission is trust, not proof. The structural recursions of the first kind
could carry measures and leave `unsafe` altogether (`controls text at` is
`measure (strlen text - at)`); that is the right next move for the
modules the apps lean on (httpclient, mqtt, javascript, clientcalc), and it
is library work with its own tests, not part of admitting them.

## The applications, compiled safe

With the list complete, the apps' own refusals were the ones the audit
counted: todo 1, logbook 1, inventory 7, pos1 20. All are gone and the four
files open with `profile base.`:

- **Index loops over a string** (`numGo`, `sbGo`, `wdGo`, `seGo`, `cWhole`,
  `cFrac`) carry `(i : Int | measure (n - i)) -> (n : Int)`. The checker
  wants the floor visible: `cFrac`'s `| i >= n or mul == 0` had to become
  two clauses, since a disjunctive guard does not show that the measure is
  at least 0 on the recursive clause.
- **`stretch n`** (the password hash's 200 rounds) carries `measure n`,
  with a `| n <= 0` guard in place of a literal `0` pattern, which the
  checker does not read as the floor.
- **List searches and filters** (`sGet`, `sDel`, `findP`, `mapP`, `live`,
  `dropStaff`, `findSale`, `pinOk`, `qtyOf`, `covered`, `takeN`,
  `noteKind`) became `List.find`, `List.filter`, `List.map`, `List.take`,
  `List.any` and `List.append`: shorter, and recursion through the library
  is the sanctioned kind.
- **`run`/`runW`** (pos1's console) were mutually recursive only for the
  `help` word, which now answers directly.
- **logbook's `load`** recursed to clamp a page past the end; it now
  fetches at most twice and does not recurse.
- **todo's `dropGo`** counts bytes remaining with `measure k` instead of an
  index that goes to -1.

## Evidence

`fpr build` of todo, logbook, inventory and pos1 as `profile base.`
programs; `tests/check_trust.py`; the suites and the apps' own checks
(`check_std`, `check_pos_reload`) as recorded in the commit.

## Open

- Measures for the first-kind helpers in the library (above).
- A reason, per module, written where the module is: the table here is the
  register, but a header comment in each module naming its unsafe kind
  would make the review local.
