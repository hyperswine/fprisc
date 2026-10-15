# Pure FP-RISC application completion contract

The POS, inventory and printer applications must define their behavior,
presentation and protocol policy in FP-RISC. Generated browser artifacts are
allowed. Handwritten JavaScript/CSS application fragments, embedded foreign
source blobs and runtime subprocess integrations are not. Moving a literal
fragment into a library, a raw-code node or a generated file does not satisfy
this requirement.

Native system APIs and linked libraries supply mechanisms that FP-RISC cannot
implement on its own: sockets, readiness, clocks, entropy and established TLS
and signature engines. Application limits, admission, trust selection, framing,
sessions, retries and lifecycle belong in FP-RISC. Browser APIs likewise need
an explicit capability boundary and structured FP-RISC definitions. Generator
syntax tokens are permissible; executable foreign-source templates that own
application or shared runtime behavior remain migration work.

Presentation is compositional and local. Put typed attributes on each node,
including explicit inherited palette/font scopes and the document body.
Conditional appearance uses typed state/viewport variants. Do not add selector
strings, global class registries, pseudo-elements that encode application
content, arbitrary CSS property/value escapes or style.cssText adapters.

## Completion checklist

- [x] Printer view: typed local presentation and document attributes, explicit
  progress/switch nodes and generated media lifecycle.
- [x] Printer login/session UI: generated presentation and browser behavior.
- [x] Native printer host: FP-RISC configuration, telemetry/camera actors,
  aggregation, bounded HTTP/WebSocket routing and streaming, lifecycle and
  shutdown. Remove Python defaults and fallbacks after native acceptance.
- [x] Native authentication: linked Ed25519 verification and secure entropy;
  FP-RISC challenge/session/origin/cookie/admission/expiry/logout policy.
  Preserve authentication on HTML, status, WebSocket and every camera route.
- [x] Inventory: generated device persistence, autocomplete, pending/loading
  effects and list transitions. Existing generated history/scroll/paging remain.
- [x] Logbook: generated form-fill behavior and typed local presentation.
- [x] Shared browser runtime: replace handwritten Live/client-effect runtime
  bodies with structured generation. Port shared semantics, including input
  synchronization, keyed morphing, reconnect, timers and suspension; do not
  merely wrap scripts in an AST Raw constructor.
- [x] Shared presentation: remove legacy View/Ma global reset and selector
  dependence from these apps, including notifications and hidden-empty policy.
- [x] HTTP client: native DNS/TCP/TLS without curl or other child processes;
  explicit certificate policy, strict framing, body/header limits and one budget.
  Repeated-request services must reuse a caller-owned resolver pool and impose
  aggregate admission; the convenience one-request pool cannot bound unrelated
  concurrent callers.
- [x] Application source and transitive runtime closure audit: no process/tool
  call on an ordinary application path and no handwritten JS/CSS assets.

Test drivers and development build/reload tooling are separate from runtime
application dependencies. They may drive external browsers, brokers and
simulators; they must not be needed by a deployed application. Any remaining
runtime dependency must be named explicitly instead of reporting completion.

## Required acceptance

Run meaningful pure-function, native one/four-hart and real browser checks for
each changed boundary. Validate failure paths as well as success: overflow and
malformed data, capacity rejection, absolute deadlines, cancellation, peer
identity refusal, stale state, session revocation, slow viewers and last-viewer
cleanup. Browser checks cover narrow/wide layouts, keyboard focus, independent
component scopes, storage refusal, reconnect and pagehide/BFCache lifecycle.

The printer replacement additionally needs the existing TLS/broker/camera
simulators and fresh authenticated real-device checks through public HTTPS and
WSS. Successful host compilation is not physical-device or deployment proof.
The current Python production gateway stays until its native replacement passes
these gates; legacy helpers are then removed from the deployment path.

## Implementation record

The printer page now uses `examples/printer-dashboard/presentation.fpr`, typed
local View declarations and `Live.serveProjectedBody` for the document body.
No application stylesheet, selector registry, pseudo-element content, inline
style mutation or raw camera script remains in `examples/printers.fpr`.
`std/browsermedia` expresses the active-source rule as FP-RISC data, evaluates
it natively and lowers it through `std/javascript`, whose syntax tree has no
Raw node. Media-owned shadow contents use a generated typed view. This backend
was initially limited to media; the completion section below records its
adoption throughout Live and BrowserCalc.

`std/http` now delegates client requests to `std/httpclient`. The parser handles
partial/coalesced input, binary bodies, Content-Length, close delimiting,
chunked encoding, interim responses and bounded trailers. Ambiguous framing,
malformed headers/statuses/chunks, overflow, unsupported transfer encodings and
oversized bodies are refused. Native TLS verifies the URL host and selected CA
policy; absent support returns Unsupported. A single absolute budget covers
DNS, TCP, TLS, request writes and every response phase. Cleanup happens on
success and failure. No HTTPS/plaintext downgrade or subprocess fallback exists.

Acceptance on macOS AArch64:

- Native HTTP simulator tests on one/four harts pass with PATH=/nonexistent:
  binary request/response, nondefault Host port, fragmented chunked replies,
  connection-length completion before peer close, public Http wrapper, unknown
  engine, wrong identity/trust, oversized length and stalled/slow responses.
- Deterministic transport tests cover malformed and ambiguous framing, truncation,
  line/body limits, integer overflow, deadlines that progress cannot renew,
  cancellation before I/O, URL parsing and request-header injection refusal.
- Printer Chromium checks on one/four harts pass for local generated rules only,
  wide/narrow layout, focus, progress and media geometry, telemetry preserving a
  stream, visibility/disconnect, error without retry loops, toggle, BFCache and
  detached-host cleanup. Shared theme/inventory and dashboard wire/authentication
  checks pass as well. Final native Live browser checks also pass: a real progress
  update delivers new local CSS without replacing the shadow image or starting a
  second stream, and collapsing details removes its source. Syntax checks verify
  assignment/identifier refusal, script-tag/Unicode escaping and prototype-like
  property names remaining data.

## Native host and remaining-browser completion (2026-10-15)

`examples/printer-host.fpr` is now the supported runtime. It starts FP-RISC
actors for telemetry, cameras, the public snapshot register, Live rendering,
authentication and the gateway in one process. It never launches another
program. Configuration and selected credentials are read through native file /
environment APIs; the view gets only the public register. The CLI supports
public JSON configuration and explicit trust identities; automatic discovery
and RTSPS remain unsupported rather than falling back to Python.

`std/sessionauth` owns the one-use origin/browser-bound challenges, per-address
attempt windows, pending/session admission, hashed bearer tokens, expiry and
logout. `machine/unix/crypto_openssl.c` supplies off-hart entropy and one-shot
Ed25519 verification through an optional linked OpenSSL 3 engine. Native job
identities have actor cleanup, and retiring jobs retain capacity until finished.
No private login key is accepted by the server. The [OpenSSL Ed25519 contract](https://docs.openssl.org/3.0/man7/EVP_SIGNATURE-ED25519/)
uses one-shot verification with no external digest.

The public gateway bounds admission (32 handlers), request headers/body/depth,
upstream headers, connection deadlines and relay buffers. A single actor owns
both ends of each checked relay, including write deadlines and repeated session
checks. Logout terminates WebSockets and cameras, including while waiting for
a first upstream header. WebSocket declared payloads are checked before body
accumulation, including integer overflow and fragment-count bounds. The public
snapshot contains explicit allowlisted telemetry and camera metrics only.

Login/session programs, Live bootstrap/reconciliation/local synchronization/reconnect,
BrowserCalc runtime/effects and ClientCalc lowering now construct typed
JavaScript syntax nodes. No Raw/source node or executable template remains.
Inventory storage, autocomplete and pending feedback and logbook form-fill use
these facilities. Loading prototypes and Web Animations transforms are generated
from typed presentation. Local styles cover the application trees, Ma
components, hover/focus, selected local state and empty-notice visibility; global
resets, pseudo-element content and selector-based empty hiding are removed.
Legacy class annotations remain DOM hooks, not application styling registries.
Explicit legacy styling APIs remain compatibility APIs with typed lowering;
these applications do not use them for appearance.

Reusing the printer view exposed a compiler bug: imported `@Msg` / `@Model.field`
literals did not qualify their local type name. Module qualification now does
so before codec/path expansion, retaining public wire labels. A focused imported
codec/path regression and the native host exercise that boundary.

The former Python runtime is retained only in `tests/legacy`. Public browser
assets under tools are generated compatibility exports for the earlier running
process; the native host serves definitions directly. Build/validation drivers
may use Python/Node/browser simulators, but these are absent from runtime paths.

Local macOS AArch64 acceptance includes native crypto vectors and pure auth
policy checks on one/four harts; generated login/sign-out browser tests; native
gateway tests with empty PATH, replay/origin refusal, oversized WebSocket length
refusal, MQTT/TLS and shared camera/TLS peers and logout cleanup; 1031 arithmetic
and 765 metric comparisons; real POS carts/checkout; inventory autocomplete,
history/scroll and scoped themes; local-style/cache tests; and native logbook
editing/reconciliation. Individual test outputs establish their stated scope.

The final source boundary guard (`tests/check_pure_applications.py --binary
build/printer-host`) checks the 87-module application closure, the explicit
development-only reload boundary and reproducibility of the compatibility
exports. It is a regression guard, not a proof of dynamic reachability. The
generated-feedback browser fixture also verifies timer/animation cleanup on
pagehide, refusal while suspended, BFCache restoration, and script-safe initial
Live data and document titles. Native crypto checks cover retained admission
through completion, explicit close and invalidated job identities as well as
the signature/entropy vectors.

## Public native deployment acceptance (2026-10-15)

Application commit `9782b38420bb24c5b61d095adecfaea93abd3be2` was committed and
pushed before replacing the public Python process with the native host. The
previous gateway and helper processes exited. One native FP-RISC process now
serves port 6730 with four harts, an empty tool PATH and no child processes;
the existing public proxy, allowlist, configuration and printer trust remain.

Fresh verified public HTTPS/WSS checks against real A1/P1S printers passed:
signature login, fresh ONLINE reports, live snapshots/updates and controls,
consecutive camera JPEGs, two viewers sharing one upstream, final-viewer cleanup,
and logout revocation of active WSS/camera responses. Anonymous protected routes
return 401. Chromium also exercised generated login/sign-out, public WSS,
decoded images from both cameras and wide/narrow layout. Test drivers keep
private keys, bearer cookies and camera pixels out of output/saved evidence.
See the [launcher and acceptance record](../examples/printer-dashboard/README.md#single-process-native-host-deployed-2026-10-15).

The deployment gate for these read-only paths has passed. This does not establish
a long-duration memory/stress bound, every-target acceptance or a physical print.

## Broader repository audit (2026-10-15)

The completed runtime migration above covers the native Base/ExtBase POS,
inventory, logbook and printer applications. A broader source audit found these
remaining boundaries outside that scope:

- The audit originally found `compiler/Sol/Web.hs:clientPage` embedding the HostedBytecode profile's
  browser runtime and global stylesheet. This is used by the Sol blog, dashboard,
  POS/POS2, todo/todo2 and terra examples via `View.serve`. `sol/lib/ui.sol` names
  global CSS classes rather than typed node-local declarations. This backend
  needed structured browser generation and local presentation. The completion
  below supersedes this remaining item.
- `examples/report.fpr` and `examples/ideal/report.fpr` invoke Git for revision
  metadata. Sol's system-report/archive scripts and Git library use external
  commands as well. These are actual tool integrations, even though they are
  structured rather than shell-interpolated; a repository-wide no-tools goal
  would require native APIs/libraries for those operations.
- Live's explicitly selected development reload still invokes the compiler;
  process demonstrations deliberately exercise subprocesses. Python remains in
  test/build/benchmark/device-development drivers and the legacy test fixtures.
  No Python runtime integration was found in the native application paths.

This audit also caught `pos1.cssAll` calling the compatibility `cssWith` path,
which emitted class-based rules despite the nodes already owning typed utilities.
It now uses `cssFor`, and the application source guard rejects compatibility
stylesheet calls. View/Ma retain explicit legacy stylesheet APIs for other
callers; the migrated applications no longer call those APIs.
The tightened source guard and native/browser POS checks pass, including 1,031
calculation comparisons and independent carts/checkout/focus on one/four harts.

## Sol hosted web generation completed (2026-10-15)

`sol/web/client.fpr` is the authoritative browser runtime, built entirely from
`std/javascript` syntax nodes and the same DOM reconciler as native Live.
`sol/web/presentation.fpr` owns typed `std/view` declarations for the document,
controls, components, table cells/rows, focus/hover and responsive variants.
No Raw/source node, handwritten browser program or stylesheet is used.

`tools/generate_sol_web.fpr` produces the checked-in `Sol.WebAssets` module and
`sol/lib/webstyles.sol`. The host links these build exports and serves separate
HTML/JS/CSS resources; `View.serve` never launches a generator/compiler or reads
browser source from disk. A clean checkout can build the compiler from the
checked-in exports. Run `make sol-web-assets` after changing their source and
`make sol-web-assets-check` to refuse stale exports. Generated exports are not
authoring sources.

Sol's appearance values carry `(stage, property, utility)` atoms. Composition
deduplicates by stage/property on each node before emitting utility class values,
so overrides depend on local composition rather than stylesheet ordering.
The stylesheet contains only generated utility selectors and their local state /
viewport variants: no resets, `:root`, named class registry or table descendants.
Table appearance is attached directly to the table, rows and cells. The common
View breakpoint is 760px. New typed declarations preserve border collapse,
selection policy, gradient text, brightness and backdrop blur.

`sol/lib/ui.sol` now takes typed appearance lists; POS2's string lists were
migrated, and todo2's UI pin was refreshed. The legacy record vocabulary in
`sol/lib/web.sol` also takes local appearance lists. Old pinned libraries/apps
using arbitrary class strings must update their pin and calls; there is no global
CSS fallback. The host serializes typed elements with `classes` arrays, and the
client refuses legacy `cls` or non-utility class values and executable elements.

The generated client preserves session tokens and the existing event/patch
protocol, with nonfatal storage refusal, delegated form/event handlers, keyed
reconciliation, draft/focus/selection preservation, reconnect backoff and
pagehide/BFCache cleanup. Old socket callbacks cannot overwrite a resumed page.
These changes do not replace Sol's HTTP/session/persistence host with FP-RISC
policy or alter its existing authentication model.

Acceptance: `node tests/check_sol_web.cjs` checks all seven real hosted examples
on isolated servers with no tools on PATH, plus controlled malformed style/text,
storage, draft/handler, reconnect and suspension cases. The library contract and
application trace suites pass; non-view model/command trace lines are unchanged.
Native View utility checks cover the added declaration types, and the source
boundary guard now includes the Sol renderer. These are hosted macOS/Chromium
checks, not deployment or every-target certification.
