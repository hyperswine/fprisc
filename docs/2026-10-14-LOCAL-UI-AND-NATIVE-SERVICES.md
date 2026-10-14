# Local UI composition and native application services

Kind: design decision and implementation record.
Scope: Base/ExtBase application libraries and the POS, inventory and printer examples.
Status: local styling, generated POS calculations, shared latency monitoring,
and inventory console history/scrolling are implemented. The native
[DNS/TLS/MQTT foundation](2026-10-15-NATIVE-TLS-MQTT.md) is also implemented;
remaining browser behaviors and application-service migrations are planned.

## Source of truth

Application behaviour and presentation should be defined in FP-RISC. JavaScript
and CSS are acceptable generated outputs. Handwritten programs embedded in
strings, including strings moved into library modules, do not meet this goal.
Protocols and service integrations should run directly through Base/ExtBase
libraries instead of Python helpers or subprocess transports such as curl.
Small platform adapters to established native libraries are acceptable; this
does not require reimplementing cryptography.

## Local, compositional presentation

Keep the Tailwind-like authoring model: compose utilities on the element that
they affect. Utilities are typed FP-RISC values, and reusable combinations are
ordinary values/functions. Application conditions select utilities through
ordinary FP-RISC expressions. No application-defined selectors, global class
registry, arbitrary ancestor/descendant matching or dependencies on another
component's internal DOM are required.

Element states and responsive conditions belong to the utility vocabulary.
The generator may emit selectors and media queries as an implementation detail.
Themes should be explicit values passed to components or declared inherited
theme scopes. Parent-dependent presentation requires an explicit input/context.

Composition must define precedence without relying on traversal or stylesheet
emission order: component defaults, variants and caller overrides compose in
that order; later declarations replace earlier declarations for the same
property and condition. Shorthands must expand before this resolution.

## Implemented first slice (2026-10-14)

`std/view` adds `utilities`, `narrow`, `wide`, `hover`, `focus` and `disabled`,
each accepting a list of typed declarations and returning an `Attr`. All such
attributes on an element compose in attribute order. `focus` means keyboard
focus (`:focus-visible`), and `disabled` means the native `:disabled` state.

```fpr
G = use "std/view".
base = [G.Display G.Flex, G.Direction G.Column, G.Gap (G.Px 12),
        G.Padding (G.Px 16), G.Width (G.Pct 100)].
card overrides kids = G.El "section"
  [G.utilities base, G.utilities overrides,
   G.narrow [G.Padding (G.Px 8)]] kids.
```

Typed declarations cover dimensions, display, flex direction, gap, padding
(including axes and individual sides), radius, font size, RGB/transparent/current
colours and opacity (integer percentage 0..100). RGB channels outside 0..255 and
opacity outside 0..100 fail explicitly. `Prop String String` remains available
to the legacy `Style` API and is refused by local utilities.

Resolution is per property and condition. Base rules are followed by narrow
(`max-width:760px`), wide (`min-width:761px`), hover, focus-visible and disabled
rules. State rules have equal specificity, so disabled overrides focus, and
focus overrides hover. Viewport conditions override base values; states override
both. Variants cannot yet be nested or combined. The existing breakpoints leave
the fractional interval between 760px and 761px at base styling.

Each surviving declaration receives a generated class containing its condition
and hex-encoded CSS declaration. This is deterministic and collision-free,
without a global counter, hash collision policy or new cache representation.
Cached `Fragment` class lists retain everything necessary to regenerate these
rules. The tradeoff is longer class names; compact identities can follow with
an explicit collision/definition contract. The `fpr-u-` class prefix is reserved.

Existing `Cls`, `Style`, `cssFor` and `cssWith` callers remain supported. Local
rules are emitted after legacy rules, but arbitrary legacy state selectors and
inline styles are outside the new composition guarantee. The old stylesheet
still includes global resets, theme rules and special selectors; removing those
is a later migration. Styles are trusted program data, not untrusted CSS input.

POS's two remaining inline dimensions and all eight named dimension styles now
use local utilities. Shared row/badge dimensions are ordinary attribute values.
Its legacy utility classes, reload-notice styles and browser scripts remain for
later conversion.

### Validation

- `tests/std/viewutilities.fpr`: default/override resolution, padding expansion,
  variants, unused rules, independent siblings and cached-fragment equivalence.
- `tests/check_view_utilities.cjs`: actual computed browser styles under viewport,
  hover, keyboard focus and disabled changes, including sibling reordering;
  invalid raw properties/colours/opacity fail explicitly.
- `tests/viewcss.fpr` and `tests/check_viewcache.py`: legacy generator and cache
  regressions. The new `viewutilities` fixture is also included in
  `tests/check_std.py`.

Executed on macOS AArch64: the new generator/Chromium checks, the legacy
`viewcss` fixture and POS checkout/reload checks on one and four harts pass.
The standard-library suite stopped at the unchanged poller fixture: 112 bytes
allocated versus its expected zero; that fixture does not import `std/view`.
The remaining standard-library checks were run separately and all passed.
The view-cache unit checks and cached/verification wire modes passed, but its
stateless wire comparison failed. The same comparison failed with the original
`HEAD:std/view.fpr` in an isolated module home, confirming it predates this change.
With that known failing comparison excluded in a temporary runner, the remaining
cache checks (pagination, editing, search, eviction and session isolation) pass.
Neither existing test file nor expectation was changed to suppress a failure.

## Second slice: application migration and live CSS (2026-10-14)

### Typed properties and themes

Local declarations now also cover margin (including automatic centering and
individual sides), alignment, justification, wrapping, overflow on both axes,
whitespace, pointer events, scrollbar width, position/offsets/z-index,
translations, shadows, font family/weight/line height and word wrapping.
Margin and overflow shorthands expand before local conflict resolution, just
like padding. RGBA colours use four channels in 0..255; font weights accept
1..1000, and line height is a nonnegative integer percentage.

`theme` accepts a `Theme` record with `bg`, `ink`, `dim`, `card`, `panel` and
`line` colours. It declares inherited custom properties on that element.
`ThemeColour token` reads a token, and `DefineColour token colour` overrides
one token in a nested scope. Themes are values passed explicitly; no selector
finds a theme elsewhere in the DOM. The existing applications still use their
legacy day/night stylesheet; moving those global theme rules is separate work.

### Styles that appear after initial load

Use `renderStyled` at the final Live page boundary. It renders the normal
statics/dynamics and a single `style[data-lv-local-css]` node containing the
current tree's local rules. That node stays present even when there are no
rules. Adding/removing the final utility therefore preserves the page root
and its live input state. The existing Live protocol and browser reconciler
deliver/style the node without additional handwritten JavaScript or a global
stylesheet registry.

Component caches continue using `render` and retaining their class lists;
`renderStyled` collects their rules at the final page boundary. New local
styles need not occur in the initial sample. Legacy string classes still need
their stylesheet definitions as before. Changing the rule set changes statics
and uses the normal structural-patch path; unchanged rules retain the existing
dynamic-only update path. This adds CSS text to structural render payloads;
payload compaction/performance measurements are not claimed by this slice.

POS and inventory now use `renderStyled`. Inventory's ten named styles have
been migrated to element-local values, including its conditional pager state.
One typed `chip` class adapter remains for buttons created outside the view by
the old autocomplete script. The inventory application and reload notice no
longer use raw `Prop` declarations. The notice owns its local positioning,
colours, typography and shadow; `Notice.styles = Nil` preserves compatibility
for older callers. Its legacy `hide-empty` helper remains to preserve text-only
notice updates until the generated client layer can own visibility.

### Second-slice validation

`tests/check_view_utilities.cjs` now checks typed layout, scoped/inherited theme
colours, invalid RGBA/weight values, and the actual inventory sample plus reload
notice at desktop and phone sizes. Its inventory fixture appends
`tests/inventorystyles.fprinc` to a temporary copy of the application with its
original main renamed; it accesses no account, real store or printer.

`tests/liveutilities.fpr` is a cached Live application whose initial local
stylesheet is empty. The browser check introduces new styles, exercises hover,
removes/reintroduces those styles, and verifies that two tabs update while the
style node, focused input, draft and selection survive. This runs with one and
four harts. Existing POS checkout/reload, view CSS, cache-unit and notice checks
are the migration regressions.

Executed on macOS AArch64: the complete expanded Chromium suite passes,
including the actual inventory/reload-notice sample at 1200x800 and 390x844 and
the live conditional-style checks with one/four harts. POS checkout/reload with
one/four harts, ordinary static pricing, the legacy view-CSS fixture, cache-unit
fixture and notice lifecycle fixture all pass. The actual inventory application
also builds. The earlier unrelated poller/stateless-wire baseline failures were
not rerun or changed by this slice.

Run `node tests/check_view_utilities.cjs` with Playwright and Chromium available;
`NODE_PATH` and `CHROME_BIN` can select an existing installation. The harness
builds its own binaries, uses temporary stores and loopback listeners, and cleans
them up. `tests/std/viewutilities.fpr` remains the native generator fixture in
the standard-library suite.

## Subsequent slices

The sections above record their implementation stages. The next dated section
updates the theme/autocomplete boundaries that were still open after slice two.

1. Complete the remaining local utilities as examples demand them, including
   remaining border variants and container conditions. Continue migrating legacy
   component selectors and resets. Local conditional styles now
   travel with `renderStyled`; initial samples remain necessary for legacy
   string classes. Explicit theme adoption and removal of the autocomplete
   adapter are implemented in slice three below.
2. Describe browser behaviour in FP-RISC: typed client state/computations and
   effects for storage, focus, scroll, autocomplete, console history and media
   lifecycle. Generate JavaScript from structured definitions. Merely wrapping
   raw JavaScript strings or moving existing scripts to std is insufficient.
   POS cart computations/effects and shared money/rounding definitions are now
   generated in slice four below; shared latency monitoring is generated in
   slice five; inventory console history and scrolling are generated in slice
   six. Extend that expression/effect subset to the remaining interactions.
   Server validation remains authoritative.
3. Introduce a reusable TCP/TLS transport boundary with deadlines, cancellation
   and explicit lifetime. Add platform TLS adapters with explicit certificate
   policy and support reporting. Replace the curl transport in `std/http`.
   The [native TLS/MQTT record](2026-10-15-NATIVE-TLS-MQTT.md) now defines this
   boundary and records bounded DNS/TCP establishment, checked native lifetime,
   actor cleanup and the optional native TLS client. Curl replacement remains.
4. Implement MQTT framing/session state in FP-RISC over that transport, with
   packet bounds, partial reads/writes, acknowledgements, keepalive, reconnect
   and refused-subscription behaviour. Test against a broker before claiming
   interoperability. Protocol facilities belong in ExtBase; minimal environment
   and resource primitives remain Base.
   The initial anonymous MQTT 3.1.1 QoS 0/1 codec, pure session and native pump
   now pass Mosquitto TCP/TLS acceptance, including idle keepalive. Authentication
   and printer-specific integration remain separate work in the native record.
5. Move printer telemetry merging, native camera framing and camera sharing
   into FP-RISC. Add reusable HTTP streaming and serve the dashboard directly.
   Keep Bambu-specific details in an application library. Preserve read-only
   behaviour, stale/offline visibility, per-tab controls and final-viewer cleanup.

The final acceptance applications build and run without handwritten JS/CSS
fragments or Python/curl runtime helpers. Generated outputs, native integration
tests and real browser checks are separate evidence. Physical printer acceptance
must be rerun after transport migration; historical Python-bridge validation
does not validate the replacement.

## Third slice: scoped palettes and autocomplete prototypes (2026-10-14)

Global colour palettes have been removed from `std/view` and `std/ma`: no
`:root`, `.day`, `.night` or `body:has(.day)` rule assigns a theme. Day/night
labels on arbitrary elements no longer change another element's colours.
`std/appearance` supplies the POS/inventory palettes, panel gradients and page
backdrops as FP-RISC values, attached directly to each page frame. Inventory's
centred content stays inside that full-viewport frame. The printer dashboard
also declares its palette on its own frame and retains its light native colour
scheme. Its broader literal stylesheet remains to be converted separately.

Ma's `page "day"` / `page "night"` API installs typed token declarations on the
page itself. `maCssFor` emits inert definitions for both palette variants for
compatibility with older callers; only an element carrying their generated
classes receives the tokens. Logbook uses `renderStyled` at its final page
boundary. Named colour/shadow tokens are scoped identifiers validated by
`NamedToken` (a lowercase ASCII letter, then lowercase letters/digits/hyphens).
The generator now also supports typed linear/radial gradients, multiple shadow
parts, borders, cursor and colour scheme. No raw CSS is needed for these values.

`cssFor` no longer supplies an implicit page palette. Callers supply `theme` or
an appearance frame explicitly. Existing global resets, font defaults, component
state/empty-slot selectors and the legacy `screen` scroll lock remain outside
this palette migration. This is not a claim that all global CSS has disappeared.

Inventory's autocomplete class adapter has been removed. A hidden prototype
group in the normal view describes the popup, normal/selected option buttons
and hint through local utilities. It also contains the popup's explicit palette.
The browser clones those nodes within the input's declared `data-ac-scope`;
there is no `chip` registry entry, hardcoded class list, popup CSS string or
computed-style token copying. The prototype rules remain available through
the final view render while the popup is outside the Live root. A server frame
refreshes an open popup from the current prototypes, including a theme change.
Suggestion labels are assigned as text. Keyboard, comma-tag and touch behaviour
remain in the existing browser script; generating that logic is still future
work. Its runtime positioning/visibility effects remain DOM operations.

### Third-slice validation

`tests/check_theme_autocomplete.cjs` checks independent View/Ma themes on one
page, inert legacy theme classes, generated gradients/shadows, absent body-level
palette variables and invalid token/gradient/alpha refusal. It also checks the
printer palette and viewport bounds at desktop/phone sizes using a pure sample
view. The actual inventory script runs against a presentation-only sample server
whose account/persistence operations are never invoked. Checks cover ranking,
arrow/Tab/Enter/Escape, contextual spots, comma-separated tags, literal-text
suggestions, pointer/touch selection and an open popup updating its palette
without losing the focused input/draft/selection. The live cases use one/four
harts. Existing styling, POS checkout/reload, logbook DOM and printer demo
transport/gateway checks provide the migration regressions.

No physical printer, real account or saved private store is used by these
checks. Physical printer validation from before the migration is not refreshed
by a demo or pure-view check. Run the new suite with
`node tests/check_theme_autocomplete.cjs` and Playwright/Chromium available.
Executed on macOS AArch64: the new theme/autocomplete suite passes, including
independent scopes, gradients/shadows, printer desktop/phone layouts and actual
inventory keyboard/touch/popup theme updates on one/four harts. The existing
styling/live-utility suite, POS checkout/reload (one/four harts plus static
pricing), logbook Chromium DOM editing, native generator/cache fixtures and
legacy view-CSS fixture pass. All nine printer transport unit checks, real
FP-RISC demo wire checks (one/four harts) and the same-origin gateway/shutdown
check pass. These are targeted migration checks; the earlier unrelated full
suite baseline failures are not being presented as resolved.

## Fourth slice: generated POS calculations (2026-10-14)

POS's `cartScript` is now a structured FP-RISC program. It describes reads of
catalogue attributes and Live locals, integer computations, scoped row loops,
text output and the empty-cart visibility effect. The app contains no JavaScript
fragment for that behavior. `std/browsercalc` generates its event handler from
those values; it has no raw-code constructor or general function-call escape.
Targets are IDs or attribute hooks, resolved within the current loop's DOM
scope. A sibling panel or an unrelated row outside it cannot contribute to its
subtotal or receive its output. These DOM hooks do not define CSS rules.

`std/clientcalc` is the pure expression vocabulary: integer arithmetic and
conditionals, boolean comparisons/short-circuiting, decimal text, concatenation,
zero-padded decimal integers and conditional text. Padding operates on integer
digits, avoiding byte-length versus browser Unicode-length ambiguity. Native
evaluation and JavaScript lowering consume the same expression values. This is a small library backend, not a
JavaScript compiler for arbitrary FP-RISC functions or a replacement for Live's
transport client. Numeric and text slots have separate dictionaries; a missing
slot refuses rather than silently becoming an undefined value. Slots are shared
within one projection invocation, so an outer accumulator can be updated by an
inner loop. No state survives into another event.

`std/money.amount` describes signed cents formatting and `taxExpr` describes the
existing `(subtotal * basisPoints + 5000) / 10000` rule. Native POS `money` and
`taxOn` now evaluate those definitions; the generated cart uses them too. Money
formatting handles the minimum Int without negating that entire value. The
rounding rule remains the existing POS rule; it is not a newly specified tax
policy for arbitrary negative transactions.

Browser arithmetic uses BigInt with the generating target's `intMin`/`intMax`,
checks each intermediate result, and divides toward zero. It does not convert
cents to JavaScript Number. Out-of-range results and division by zero refuse.
Inputs are decimal text: missing/malformed Live locals mean zero; malformed
catalogue attributes or out-of-range integers refuse. The generator queues DOM
writes until all computations succeed. A refusal leaves the previous display
intact and dispatches `fpr:client-error` with a message; the next valid event can
recover. This display projection does not authorize payment. The server still
clamps quantities, verifies stock and computes checkout independently.

Literal strings and slot names are quoted as data, including `<`, `>`, `&` and
Unicode line separators, so an embedded `</script>` cannot end the generated
script. Output uses textContent, never interpreted HTML. Runtime DOM visibility
remains an effect; it is not a handwritten application stylesheet.

### Fourth-slice validation

`tests/std/clientcalc.fpr` tests the native contract and produces differential
vectors. `tests/check_client_calculations.cjs` compares those native results
with generated JavaScript, verifies refusal at arithmetic boundaries, embeds
adversarial literal text in an actual script element, and exercises the actual
POS projection in Chromium. Its scoped duplicate-panel case, large exact cents,
half-cent rounding, malformed input, atomic refusal and recovery cover the
browser boundary. It also starts disposable real POS servers with one/four
harts and uses two independent browser registers to check live price changes,
focused tender draft/selection retention, checkout totals/receipts and per-tab
cart clearing. Run with `node tests/check_client_calculations.cjs` and
Playwright/Chromium available. The fixtures use isolated temporary stores and
the example's built-in demo cashiers.

Executed on macOS AArch64: all 1,031 native/generated differential vectors,
native refusal checks, script/text escaping and Chromium scoped-projection
checks pass. The real browser POS checks pass on one/four harts, including
matching native receipts and focused draft/selection retention. The existing
POS live-pricing/reload suite also passes on one/four harts, with invalid and
incompatible policy refusal, recovery, receipt history, notice expiry, log
rebuild and ordinary static-pricing startup. These are focused host/browser
checks; no hardware or physical printer acceptance is claimed.

The shared RTT monitor is converted in slice five below. `std/livejs`'s
transport/local-state implementation still contains handwritten JavaScript,
as do inventory's remaining browser behaviors.
The remaining literal component CSS, native TLS/MQTT and printer transport work
remain on the roadmap. This slice establishes generated application behavior
and shared computations; it does not claim the final no-JS/no-Python acceptance
goal is complete.

## Fifth slice: generated Live latency monitoring (2026-10-14)

The duplicated POS/inventory latency monitors have been removed. Each app now
uses `std/livemetrics.script` with its own output hook and optional explanation
text. The monitor's initial state, send/frame/disconnect transitions, bounded
recent-sample list, summary expression and timer subscription are FP-RISC values.
It is not a literal JavaScript monitor relocated into a shared module.

`std/clientcalc` now includes immutable integer-list expressions: values, named
sequences, append-one, a bounded tail, sorting, length, checked sum, maximum
with a lazy empty-list fallback, and checked indexing. `Env` supplies native
number/text/list bindings to `evalInt evalBool evalText evalList`. Sorting for
display copies the list, so calculating a median cannot reorder the chronological
recent-sample window. Existing scalar evaluation entry points remain available.

`std/browsercalc.program` adds page-local persistent state with `On`, `Every`
and `OnSuspend`. Effects include named sequences, conditions, a monotonic clock
read and text output that skips hidden elements. Each handler works with copied
state and queues its DOM effects. An input/expression failure commits neither
state nor queued output and reports `fpr:client-error`. This is not general DOM
mutation rollback. All list transforms are immutable, including through the
shallow copy of the named sequence dictionary. The generator owns subscriptions
and timers, removes them on pagehide, and restores them once on a persisted
pageshow. Monitor suspension clears a pending measurement while retaining stats.
The timer range is checked before emission (1..2147483647 milliseconds).

The only timing primitive is a quantized monotonic microsecond clock read.
Formatting is an FP-RISC integer expression for one decimal millisecond, with
half-up rounding and an exact ratio for the average. Statistics retain the last
32 samples for an upper median and all-time count/sum/maximum. All operations
use checked target-width integers; exhaustion refuses instead of wrapping. The
new native/browser checks run on a 64-bit host, not every FP-RISC target.

`std/livejs` now dispatches payload-free `live:sent`, `live:frame` and
`live:disconnected` events for its own socket. They are reserved transport
observations, separate from application `Live.Emit` names. A send event follows
a successful send, a frame event follows parsing and successful application of
the frame, and a disconnect event clears the pending observation. Inventory's
pending indicator and autocomplete refresh consume `live:frame` directly.
Neither app modifies the WebSocket prototype or wraps every socket's handler.

The measured value is explicitly a successful Live send to the next accepted
frame, including client patch application. Multiple sends replace the pending
timestamp; a frame samples it once. It is not request-correlated latency, pure
network RTT or server processing time. Unsolicited frames do not add samples;
disconnect/suspension prevents a later frame finishing an earlier observation.
The POS explanation about background-tab throttling remains.

### Fifth-slice validation

`tests/std/livemetrics.fpr` provides native integer-list/statistic and rounding
vectors and checks invalid counts, indices, reductions and timer bounds.
`tests/check_live_metrics.cjs` compares all 765 vectors with generated JavaScript
and runs the monitor in Chromium with controlled clocks, timers and socket
events. It checks time-zero sends, overlapping sends, unsolicited frames,
disconnect reset, chronological recent-32 retention while repeatedly sorting
for display, upper median, all-time average/max, hidden output, suspension and
restoration without duplicate timers, and state/output preservation after
computation refusal. The actual Live client runs against controlled socket
boundaries to check failed sends, invalid JSON, rejected patches, reconnects,
unrelated sockets, unchanged WebSocket prototypes and absent payloads on the
transport observations.

The existing calculation/POS and theme/autocomplete suites also assert that
the generated monitor displays real send/frame observations in POS/inventory
on one/four harts. Inventory's open autocomplete refresh, keyboard/touch behavior
and focused draft preservation exercise the new frame-event boundary. These
use isolated sample/demo stores; no account or physical printer acceptance is
inferred from them. Run the new suite with `node tests/check_live_metrics.cjs`
and Playwright/Chromium available.

Executed on macOS AArch64: all 765 new differential cases, native refusal
checks, deterministic Chromium monitor/lifecycle cases and actual Live
transport-hook cases pass. The existing 1,031 calculation comparisons and real
POS browser checks pass on one/four harts, including the generated monitor and
matching checkout receipts. The theme/autocomplete suite passes with inventory
monitor assertions on one/four harts and its printer pure-view checks. The
logbook Chromium DOM suite passes for insertion/deletion, node identity,
drafts, focus/selection, updated handlers and text deltas. POS, inventory and
logbook native builds pass. These are targeted host/browser results.

The transport/patch/local-state code in `std/livejs` is still handwritten.
Inventory's console history and scrolling are converted in slice six below.
Pending animations and autocomplete logic remain to be generated;
pending-indicator literal styling also remains to be migrated. Native TLS/MQTT
and printer services remain subsequent work.

## Sixth slice: generated inventory console and scrolling (2026-10-15)

Inventory's literal console script and pager-scroll script have been removed.
The app declares `Console.script` with its explicit console scope, input/run/
output hooks, storage key and history limit of 50. `Console.pager` declares the
Live root, pager-button hook and current list target. `std/browserconsole`
describes the history policy, capture-phase keyboard/click subscriptions,
field effects and scrolling as structured FP-RISC expressions and effects.
It does not contain a relocated JavaScript console implementation.

History retains the newest 50 commands. Commands are trimmed, blanks are not
remembered and consecutive duplicates do not consume another entry. A nonblank
submission resets the cursor to the newest end. ArrowUp/ArrowDown clamp the
cursor between the oldest entry and the empty position after the newest entry;
an empty history leaves the field and normal arrow handling alone. Recalling a
command assigns the input value and dispatches input, keeping Live's local
mirror current. History is loaded once per program from the existing
`inventory-console` localStorage key and persisted after a nonblank submission.
The decoder accepts only arrays entirely made of strings and initialization
truncates an oversized history to 50. Missing/malformed/unavailable storage
starts with empty history; failed writes leave in-memory recall usable. As
before, storage belongs to the origin and each page holds its own in-memory
history; this does not add cross-tab history merging.

Enter and a click on the run button record history during capture, then defer
clearing until after the existing Live target handler can send the original
command. Whitespace normalization affects history, not the transmitted command.
The clear borrows the exact input node and its value, and only clears a connected
node whose value is still unchanged. It cannot clear a replacement input or a
different draft entered before the callback. Clearing also dispatches input to
update the local mirror. Scope/keyboard matching prevents unrelated fields from
participating; clicking a child of the run button works through its declared
ancestor hook.

Console output scrolling now follows accepted `live:frame` and `live:locals`
events within the declared console scope, rather than observing every mutation
under the Live root. Visible output scrolls to its bottom, including when local
pane selection reveals it. Pager scrolling retains its existing 150 ms delay
and smooth/start behavior. The delayed effect reacquires the current list in
the declared Live root, so an earlier frame may replace that node safely. The
delay is a timing policy, not an acknowledgement that a page response arrived.

`std/clientcalc` adds immutable text-list values, conditional lists, bounded
tails, append, length, equality, recall indexing and whitespace trim. Text-list
indexing returns empty text outside the list, as required at the newest history
position; integer-list indexing still refuses. `TextEnv` adds native text-list
bindings without changing the existing three-binding `Env` constructor.
Trimming has a native UTF-8 implementation and a browser lowering; tests compare
all 25 supported whitespace characters, including Unicode boundaries.

`std/browsercalc` adds scoped capture-phase `Key`/`Click` handlers, ancestor and
document contexts, value/input effects, typed storage effects, explicit scrolling
and owned `After`/deferred-clear work. Delayed callbacks use current program state
and their captured DOM context; the pager explicitly switches to the document
to reacquire its targets. Program suspension cancels pending timeouts as well as
intervals and removes subscriptions; persisted restoration installs them once.
Deferred effects require `program` and are rejected in ephemeral `onLocals`
projections. Invalid delays, history limits and tail counts refuse generation.
Storage failures are deliberately nonfatal, matching the previous console.

### Sixth-slice validation

`tests/std/browserconsole.fpr` and `tests/check_inventory_console.cjs` compare
50 native/generated policy cases for Unicode trimming, history bounds,
duplicates/blanks, cursor bounds, text indexing and lazy list branches. Native
checks also refuse invalid limits/tails/delays and unowned deferred effects.
Chromium checks the production-generated console/pager scripts for command
delivery before clear, nested run-button clicks, input-event recall, 50-entry
retention, cursor clamping, newer/replacement draft preservation, scope isolation,
corrupt/mixed/oversized/unavailable storage, output scrolling, replaced list
targets and cancellation/restoration of pager delays.

A presentation-only inventory fixture runs the actual view and Live client on
one/four harts. It echoes command text without invoking any account, device or
application-persistence update, allowing the test to verify original command
delivery, recalled-command mirroring, actual output overflow/scrolling, focused
draft/selection retention during another page's frame, reload persistence and
page-change/smooth-scroll behavior. Run with
`node tests/check_inventory_console.cjs` and Playwright/Chromium available.

Executed on macOS AArch64: all 50 new native/generated cases, invalid-input
refusals, controlled Chromium history/storage/scroll cases and presentation-only
inventory checks pass, including one/four harts. The existing 765 latency cases
and monitor lifecycle/transport checks, 1,031 calculation cases and POS browser
checks on one/four harts, and theme/autocomplete suite on one/four harts also
pass. The latter includes printer pure-view checks. The inventory native build
and source syntax/diff checks pass. These are targeted host/browser results;
they do not establish physical-printer or every-target acceptance.

Inventory's pending animations, autocomplete logic and device persistence
script, plus Live's transport/local-state implementation, remain handwritten.
Remaining literal styling and native TLS/MQTT/printer-service migrations remain
on the roadmap.
