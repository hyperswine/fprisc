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

The current public production process has not been restarted or replaced.
Fresh real-device/public HTTPS/WSS acceptance remains a deployment gate for the
native host. This source migration does not claim that gate has passed.
