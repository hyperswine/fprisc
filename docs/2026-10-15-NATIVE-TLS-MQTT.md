# Native transport, TLS and MQTT

Kind: design decision and implementation record.
Applies to: this checkout's Base/ExtBase libraries, after the generated
inventory-console work in [the local UI record](2026-10-14-LOCAL-UI-AND-NATIVE-SERVICES.md).
Status: bounded DNS/TCP setup, checked native lifetime, shared directional
readiness, a Unix OpenSSL 3 TLS client and an initial MQTT 3.1.1 QoS 0/1 client
are implemented. MQTT username/password authentication and an opt-in native
printer telemetry collector are available. Native shared camera framing and
MJPEG streaming now have an opt-in gateway path; public gateway/login and HTTPS
migrations remain.

## Architecture and ownership

Application behavior, protocol formats, state machines, limits and retry policy
belong in FP-RISC. Small native adapters provide socket operations, clocks,
entropy and established TLS engines. Running a Python MQTT client or curl for
HTTPS does not meet this boundary. Reimplementing cryptography is not required.

| Layer | Responsibility |
|---|---|
| Base mechanisms | nonblocking descriptor operations, directional readiness, monotonic time, entropy and native resource lifetime |
| `std/transport` | byte-stream driver contract; partial I/O, absolute deadlines, cancellation, chunk bounds and reported transfer progress |
| `std/sockettransport` | connected TCP adapter, actor ownership and nonblocking socket adoption |
| `std/readiness` | shared directional registrations, absolute expiry, correlation IDs, cancellation acknowledgement and watcher lifecycle |
| `std/watchedtransport` | connects the common byte-stream driver to a caller-owned Readiness service |
| `std/resolver`, `std/connect` | bounded caller waits and resolver admission; one budget across DNS, address attempts and nonblocking TCP setup |
| `std/tls` | secure transport over an established engine; explicit trust/capability policy, handshake and shutdown orchestration |
| `std/mqtt`, `std/mqttsession`, `std/mqttclient` | incremental packet codec, pure session/effects and a transport pump; acknowledgements, subscriptions, keepalive and explicit reconnects |
| application library | printer topics/telemetry, JSON model merging, camera framing and viewer sharing |

One actor owns a connection and serializes access to its driver/TLS context.
Protocol state never lives in a browser or a Python bridge. An application
receives typed messages and failures and chooses its policy. Per-operation
cancellation does not implicitly release the connection; cleanup is explicit.

## Common transport contract

A backend exposes one read attempt, one write attempt, a bounded readiness
wait, a monotonic clock and release. A read/write can make progress, reach EOF,
fail, or request readable/writable/either readiness. TLS reads may need writes,
and TLS writes may need reads. The protocol layer must honor the returned
interest rather than infer it from the operation being performed.

Every operation receives an absolute monotonic deadline, with either an explicit
`Uncancelled` budget or a nonblocking cancellation query in `Budget`. The wait
backend receives the full budget. Retries, progress and readiness changes retain the
same deadline. Gates run before attempts, before waiting and after successful
progress. Cancellation takes precedence when both cancellation and expiry are
observed by the same gate. A completed transfer observed after expiry returns
failure with its progress, rather than claiming it finished inside the budget.
Backend I/O and cancellation queries must themselves be nonblocking/bounded;
the transport cannot interrupt a blocking callback.

`readSome` and `readExactly` return consumed bytes on failure as well as the
failure reason. `writeAll` reports committed byte count on failure. A caller
must not replay a partially written MQTT packet from byte zero blindly.
Unexpected EOF in `readExactly` is distinct from a successful EOF in `readSome`.
An empty/overlong data step, a zero/negative/overreported write count, or invalid
sizes refuse explicitly. The connection's positive chunk limit bounds each
backend buffer/attempt; protocol code separately bounds whole messages.

The first implementation uses state-threaded `Connection s` values: retain
only the returned connection after an operation. `close` returns `Shut` and
does not release that returned handle twice. `withConnection` closes on normal
Result success/failure paths, preserves cleanup errors, and reports both errors
when an operation and cleanup fail. It is not panic/kill-safe finalization.
Socket adapters reject use from an actor other than the adopter.

The language does not enforce linear use. The first adapter used raw descriptor
aliases; the third slice adds checked native identities and actor-death cleanup
for managed sockets/TLS. Custom backends and unsafe raw-descriptor escapes still
need their own lifetime contract. Backend state and connections are not
persistence or Wire values.

## TLS backend

An initial portable backend can bind Mbed TLS behind a narrow native seam.
The native context owns stable buffers and native engine resources. In
particular, a suspended write must preserve the buffer/retry requirements of
the selected engine; FP-RISC strings must not become borrowed pointers that
outlive their call. FP-RISC drives incremental handshake/read/write/shutdown
steps and their deadlines/readiness. TLS CPU work also needs bounded steps or
an off-hart execution mechanism; nonblocking socket I/O alone does not bound
cryptographic work.

Trust configuration is explicit: system roots where supported, a private CA,
or an explicitly pinned peer. Certificate/name verification and its diagnostic
result are not silently bypassed. Unsupported trust/backend/version choices
answer an explicit failure. Entropy and certificate-time requirements are
reported as platform capabilities. Do not claim a backend works on every board
because it runs on the host. See the [Mbed TLS API](https://mbed-tls.readthedocs.io/projects/api/en/v3.6.3/api/file/ssl_8h/)
for nonblocking readiness and buffer/verification contracts; pin the actual
library version/configuration when implementing the adapter.

The same secure byte-stream interface will serve HTTPS, MQTT and a separate
printer-camera protocol. HTTP parsing stays FP-RISC. Removing curl follows
TLS validation, rather than replacing HTTPS with cleartext or a success stub.

## MQTT protocol/session

The initial target is MQTT 3.1.1 with QoS 0/1. Unsupported features must be
explicit; MQTT 5 and QoS 2 are later work. The codec keeps partial fixed headers,
Remaining Length fields and payloads across reads, checks flags/lengths/UTF-8,
and applies a caller-selected packet bound before allocating a large payload.
The session can follow a pure state/effect shape:

```
step : Event -> Session -> (Session, List Effect)
```

Events cover transport bytes/results, timers, connection loss and application
requests. Effects cover sending frames, delivering publications, scheduling
timers and reporting failures. Session state includes packet identifiers,
in-flight acknowledgements, subscription outcomes, keepalive and reconnect
policy. Reconnection must use actual broker session state and preserve the
specified MQTT retransmission behavior. Whether in-flight state survives a
process restart is an explicit persistence policy, not implied by QoS 1.
See the [MQTT 3.1.1 standard](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html).

Printer telemetry subscribes through this client and updates the FP-RISC model.
Camera framing/sharing remains a separate application library over transport.
Preserve read-only behavior, stale/offline visibility, per-tab camera controls
and last-viewer cleanup during that migration. Broker/demo acceptance and
physical-printer acceptance remain separate evidence.

## Sequence and acceptance

1. Bounded connected byte streams: fake-backend partial-I/O/refusal tests and
   real TCP reads/writes, deadlines, cancellation, ownership and cleanup.
2. Extend readiness to an interrupt-driven read/write poller with cancellable,
   timed registrations; bound connection establishment. Resolver work must not
   block a hart. A timed-out caller may abandon a resolver result even when the
   OS resolver itself cannot be interrupted.
3. Add one TLS backend. Test valid/private trust, wrong peer/name, expiry,
   handshake stalls, partial I/O, cancellation and resource cleanup. Replace
   HTTPS's curl path after these pass.
4. Implement the MQTT codec/session and run interoperability tests against a
   broker over plain TCP and TLS, including refusal, fragmentation, keepalive,
   disconnect/reconnect and QoS 1 state.
5. Replace printer Python transport and validate the real devices separately.

## First implementation (2026-10-15)

`std/transport.fpr` introduces the driver, finite budgets, partial-progress
operations, chunk limits and state-threaded cleanup. `std/sockettransport.fpr`
adopts connected TCP sockets and enforces their adopting actor on backend calls.
`Os.readyFor` adds zero-time read/write/either readiness with static successful
results, and `Os.prepareSocket` checks stream-socket type, connected state and
nonblocking setup.
These are POSIX/lwIP mechanisms; retry, deadline, chunk and cancellation policy
remain in FP-RISC. Unavailable Tang Nano mechanisms return explicit errors.

The portable transport module obtains time only from its injected backend.
`deadlineFrom now ms` checks deadline arithmetic; callers construct a `Budget`
with that deadline and their cancellation query. The connected-socket adapter's
`within ms cancelled` convenience helper reads the host monotonic clock.

After successful adoption, discard the original `Stream` and thread only the
returned connection through operations. Do not combine adoption/Transport
cleanup with `Tcp.serve`'s automatic `Stream.close`: that would release the
same descriptor twice. The integration fixture accepts sockets explicitly and
assigns each socket exactly one cleanup owner.

The first adapter used yielding/timer waits capped to the smaller of 1 ms and
the remaining deadline. It does not use the existing read-only Poller, whose
wait currently has no deadline. The second slice below adds shared directional
waits through a separate module; the simple adapter remains available.
The generic operation loops allocate temporary state; this slice does not claim
allocation-free long idle sessions. Future session actors must own reclamation
boundaries, since a library function cannot reset its caller's heap safely.

Connected-socket adoption does not bound DNS or TCP connection establishment:
the existing `Tcp.connect` is still synchronous. No TLS/MQTT API, HTTPS change,
native TLS availability or physical printer result is claimed by this slice.

## Executed validation (2026-10-15)

- `python3 tests/check_transport.py` passes on macOS AArch64 with one and four
  harts. Its scripted backend tests cover fragmented transfers, opposite/either
  readiness, absolute budgets across partial progress, cancellation, consumed
  and committed progress on failure, invalid driver results and cleanup errors.
- The same runner's real loopback sockets cover 256 KiB duplex transfer,
  fragmentation, short EOF, slow-drip timeout, a 16 MiB backpressured write,
  cancellation during a quiet wait without consuming unrelated messages,
  wrong-actor read/close refusal, repeated close of the returned closed handle,
  and refusal to adopt a regular file.
- Ten thousand successful directional-readiness primitive calls leave the
  actor's heap gauge unchanged. This proves the primitive's successful path,
  not allocation-free operation loops or long-session memory bounds.
- Existing `tests/std/tcp.fpr` and `tests/std/httplimits.fpr` match their expected
  output with one and four host harts, including the existing 2 MB echo and
  HTTP header/body/read limits.
- `make bare-metal-run PROG=tests/std/transport.fpr
  BUILD=/private/tmp/fpr-transport-rv64
  IMAGE=/private/tmp/fpr-transport-rv64.elf` passes the portable scripted tests
  under two-hart RV64 QEMU. This check caught and removed a host-clock dependency
  from the portable module. The existing runtime/compiler warnings remain.
- The updated Tang Nano unavailable-mechanism shim compiles with the RV64
  freestanding toolchain. No physical-board networking, Linux RV64 socket,
  ESP-IDF integration, TLS, broker or real-printer acceptance was executed.

The next transport work after this first slice was timed/cancellable directional
readiness (implemented below), bounded connection establishment, generation-checked
lifetime and actor-death cleanup. TLS integration builds on those mechanisms;
MQTT codec/session work keeps protocol decisions in FP-RISC.

## Second implementation: shared directional waits (2026-10-15)

`std/readiness.fpr` adds a separate service for read/write/either readiness with
finite absolute deadlines. Existing `std/poller` keeps its compatibility API.
Each registration has a fresh correlation ID and an adopting actor. Duplicate
waiters on the same descriptor remain independent, and a writable event does
not satisfy a readable-only waiter. Expired registrations fail even if
readiness was reported in the same service turn.

`register fd mask deadline poller` returns an admitted ticket; `await ticket`
parks on the service's mailbox. `awaitUntil` combines those operations and
checks the absolute deadline again when the caller resumes. `cancel ticket`
can run in the waiting actor or a controller that holds the ticket. It removes
only that registration and acknowledges after replacing the kernel watch set.
An owner cancelling its own ticket drains any preceding completion before the
acknowledgement. This covers cancellation racing readiness or expiry without
leaving a stale note to answer the next wait. Registration admission is
acknowledged before a ticket can be handed to a controller, so cancellation
cannot overtake an unprocessed registration from another sender.

The API requires one outstanding ticket per actor per service. Await it or
cancel it before reusing that return address; keep the descriptor open until
completion or acknowledged cancellation. Tickets enforce the awaiting actor,
but do not make connection aliases linear. Stop admission before `stop`,
coordinate one shutdown caller and discard the stopped service. Pending waits
receive failure; the service disarms, unbinds the waker and waits for native
watcher teardown before returning its IRQ slot. Do not kill this service.

`Os.watchArmEvents` accepts directional descriptor masks and a relative kernel
timeout; `Os.watchTakeEvents` reports direction masks. The off-hart worker waits
in `poll`, recomputes its remaining kernel timeout after interruptions, and
raises a one-shot IRQ for readiness or timer expiry. FP-RISC selects the nearest
absolute deadline and decides which registrations expire. A new arm replaces
the native generation and clears queued old events; allocation failure disarms
the old set before refusing. The existing read-only watcher seam still works.
No retry, cancellation, registration-capacity or protocol policy moved into C.

`Readiness.startPolling` selects the directional timer fallback explicitly; a
failed `watchOpen` selects the same fallback automatically. A service without
registrations sleeps in its mailbox. With the native watcher, quiet parked
waiters require no per-waiter timers or periodic descriptor polls. `stats`
reports active registrations, IRQ wakes and re-arms without re-arming the set.
Use it from an actor without an outstanding ticket on that service.

`std/watchedtransport.fpr` supplies `adoptOn poller chunk stream` through
`SocketTransport.adoptWith`. It receives the whole transport budget, so it
registers once with the original absolute deadline. `SocketTransport.forMs`
constructs an `Uncancelled` budget that parks until readiness/expiry. The simpler
socket adapter does not import the readiness service or require watcher symbols.

An arbitrary cancellation callback has no wake notification. `awaitChecking`
and watched transport's callback budget therefore still check at most 1 ms
apart, while the descriptor is registered once with the shared watcher. Prefer
explicit ticket cancellation for fully parked cancellable waits. A future
transport cancellation token can connect that notification path end to end;
this slice does not pretend a callback can wake a sleeping actor by itself.

Cancellation acknowledgement and startup/shutdown handshakes can wait for
service scheduling, mailbox admission and native teardown after expiry. These
are cooperative deadline contracts, not hard real-time completion bounds.
Unconsumed Readiness tickets remain registered until completion/expiry/stop;
automatic ticket cleanup on actor death remains pending. Callback polling and transfer loops still
allocate temporaries and are not a long-session memory-bound proof. The current
32-bit host clock wraps; wrap-safe long-duration budgets on RV32 require separate
work. No ESP-IDF or physical-board acceptance is claimed here.

### Second-slice acceptance

- The expanded `tests/check_transport.py` passes with one and four macOS
  AArch64 harts: existing scripted/TCP cases plus native read/write/either waits,
  duplicate descriptor registrations, wrong-owner refusal, quiet parking,
  nearest deadline, cancellation before/after readiness publication, no stale
  completion, unrelated mailbox preservation, stop and explicit timer fallback.
- Watched transport passes a fragmented read, quiet deadline, callback
  cancellation and a 16 MiB backpressured write retaining its committed prefix.
  No active registrations remain after those operations.
- `tests/check_posix_watcher.py` passes the existing start/failure/re-arm/close
  checks and new directional/timer-only IRQ, earlier timer replacement,
  stale queued event and injected allocation-failure disarm checks.
- `tests/check_posix_facilities.py` passes primitive-export and dependency
  boundaries, including the four primitives added across the two slices.
  Its export check now recognises the current native direct-call ABI wrappers.
- Existing TCP, HTTP-limit and Poller-stop fixtures match their expected output
  with one and four host harts, including repeated legacy watcher start/stop.
- The updated portable transport policy tests pass under two-hart RV64 QEMU;
  the Tang Nano unavailable-mechanism shim compiles with its RV64 toolchain.
  These are not native socket/device acceptance results.

After the second slice, bounded DNS/TCP establishment, checked native lifetime,
TLS and MQTT were next. The third slice implements them below. HTTPS curl
replacement and printer migration still remain.

## Third implementation: establishment, lifetime, TLS and MQTT

### Bounded establishment and checked native lifetime

`std/resolver` creates a caller-selected worker pool. Each admitted lookup runs
the OS resolver on a detached native worker; there is no unbounded job queue.
The FP-RISC caller checks its original absolute budget and cancellation query
while waiting. On timeout/cancellation it abandons its result lease and returns.
An OS resolver call may remain uncancellable: it retains its native buffers and
pool slot until it actually finishes. A saturated pool refuses new work as
`resolver busy`. Reuse the pool; creating unlimited pools is not an application
resource bound. The owner closes the pool; other actors may resolve through it.

`std/connect.connectWith wait budget pool host port chunk` resolves, tries the
returned numeric IPv4/IPv6 addresses and drives nonblocking connection setup.
Every address attempt retains the same absolute deadline. The numeric connect
mechanism does no DNS. Address ordering/fallback, readiness, retry and cleanup
are FP-RISC policy. This initial policy tries addresses sequentially; it is not
Happy Eyeballs. Legacy `Tcp.connect` remains synchronous for compatibility.

`std/sockettransport` now uses checked native leases. Native resource IDs are
never reused; registry entries and descriptor numbers may be reused. Every
managed operation checks identity and actor ownership, including zero-length
operations. Closing an old `Open` alias cannot read, write or close a later
socket that reuses its descriptor. Duplicate adoption is refused. A TLS upgrade
consumes the TCP identity, so old plaintext aliases cannot touch the TLS socket.

The runtime now has a native resource cleanup chain independent of its one
transactional-request cleanup hook. Resources unlink before release, and the
actor reaper releases them before reclaiming actor pools/stacks. Sockets are
closed on actor death. Resolver jobs drop their result lease; still-running
workers keep their own reference. TLS retirement shuts down peer I/O promptly,
but reserves the descriptor until an active engine call finishes, preventing
descriptor reuse underneath that call. Its worker slot remains occupied too.

This enforces managed native lifetime, not affine use of every `Connection s`
value in the language. Custom backends still supply their validity contract.
Raw `Os.*`, `Stream` aliases and direct descriptor access are unsafe escapes:
discard the original stream after adoption and do not mix managed cleanup with
`Tcp.serve`'s automatic close. A routed QOS plane without the resource-chain
capability refuses native ownership rather than accessing a foreign ACB.

### Native TLS client

`std/tls` orchestrates setup, handshake, read/write, readiness and explicit
`close_notify` shutdown over Transport. The optional Unix adapter is
`machine/unix/tls_openssl.c`, tested with OpenSSL **3.6.5**. Link it explicitly:

```sh
./fpr build my-app.fpr --with machine/unix/tls_openssl.c \
  --cflag -I/path/to/openssl3/include --link -L/path/to/openssl3/lib \
  --link -lssl --link -lcrypto -o my-app
```

Without an engine, weak unavailable definitions return `Unsupported`; they
perform no TLS and never report an unverified connection as secure. The new
owned-socket/resolver capabilities explicitly refuse on ESP-IDF until ported
and validated. Tang Nano has explicit unavailable primitives. No board TLS or
Linux RV64 socket acceptance is implied by portable protocol tests.

Trust is `DefaultRoots` (OpenSSL's configured trust paths, including its normal
environment configuration) or `CaFile path`. This does not automatically import
macOS Keychain trust. Peer chain, validity dates and DNS/IP identity are verified;
DNS identities also set SNI. Minimum versions are `TLS12` or `TLS13`. Verification
diagnostics include the engine's certificate failure reason. Pinning and client
certificates are not implemented; there is no insecure trust mode.

`TLS.upgrade budget peer trust minimum tcp` consumes the TCP lease on success
or failure. It chooses a 16 KiB maximum plaintext chunk and a default native
worker admission capacity of 16 in FP-RISC. `upgradeWith capacity ...` lets the
caller select that admission bound. All admitted/retiring TLS contexts count
against it until native teardown finishes; refused opens consume/close their
input TCP lease too. Each current native worker has a 512 KiB stack. This is
bounded admission, not a proof of whole-application memory or crypto WCET.

Certificate-file reads, setup, cryptography and engine teardown run on native
workers outside the hart pool. Calls are serialized per context. Native buffers
own pending read/write data across retries; borrowed FP-RISC string pointers do
not survive a call. `SSL_get_error` runs on the same worker immediately after
the engine call. Read/write can request opposite-direction readiness. A retained
read waiting for readable I/O can yield to a write, allowing MQTT PINGREQ while
idle; its read buffer/size remain stable. A write needing writable I/O must resume
before other engine I/O. These follow the [OpenSSL error/retry contract](https://docs.openssl.org/3.0/man3/SSL_get_error/).

Transport's backend now supplies validity and failure-retirement hooks as well
as I/O/wait/clock/release. `Progress` readiness represents pending native CPU
work; its completion is checked on a bounded actor timer, rather than watching
a writable socket in a busy loop. A timed-out/cancelled asynchronous TLS transfer
may have committed bytes before its result is collected. The failure is
`OutcomeUnknown reason` alongside the confirmed prefix, and the native identity
is retired. Never automatically replay that write from byte zero. Ordinary
`Transport.close` releases the lease; `TLS.shutdown` explicitly exchanges
`close_notify` and reports shutdown failure instead of hiding it.

### FP-RISC MQTT codec, session and pump

`std/mqtt` implements MQTT 3.1.1 packet encoding and incremental decoding with
separate body and input-chunk limits. Remaining Length is checked before body
extraction; incomplete prefixes survive reads and coalesced packets are decoded
in order. Fixed flags, field lengths, UTF-8, packet identifiers, publish topics
and filter grammar are validated. Binary publication payloads are preserved.
CONNECT supports anonymous, username-only and username/password authentication,
plus QoS 0/1, subscribe/unsubscribe, acknowledgements, ping and disconnect.
Wills, QoS 2 and MQTT 5 remain explicit unsupported features.

`std/mqttsession.step event state` is pure and emits typed effects. In-flight
admission is bounded by configuration; outgoing IDs are not reused before their
acknowledgement. QoS 1 publications survive explicit reconnect in memory and
resend with DUP and their original ID. Connection epochs reject late events.
CONNACK session-present is exposed; callers restore desired subscriptions when
the broker has lost its session. Previously completed subscription filters are
not automatically persisted/recreated by this slice. Refused SUBACK grants
remain visible as code 128. Keepalive emits PINGREQ, and missing connection,
publication/subscription or ping acknowledgements close the session explicitly.
Reconnection/backoff is caller policy; no process-restart persistence or exactly
once application delivery is claimed. See the [MQTT 3.1.1 standard](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html).

`std/mqttclient` applies those effects over any Transport. `begin`, `publish`,
`subscribe`, `unsubscribe`, `next`, `reattach` and `stop` thread client state.
Publication/subscription calls admit work and flush when the current native
operation permits; acknowledgements arrive through `next`. The application
outgoing queue has a configuration-derived bound, including QoS 0 requests.
`next` uses one-attempt reads and shorter readiness deadlines for session timers.
An idle caller budget returns `Ok Nil` while retaining the pending read, allowing
keepalive without destroying/recreating the TLS connection. Network failures
retire the connection and preserve the configured QoS 1 reconnect state.

A received publication is kept in `takeNotices` if sending its PUBACK fails,
so the application can still consume that delivery on the error path. Incoming
QoS 1 duplicates remain visible; application idempotence/durable processing is
separate. If a pending engine operation prevents sending DISCONNECT before
`stop`, cleanup still runs and the unsent control packet is an explicit failure.

Library calls cannot reset the caller's pool. Use finite pump budgets and an
owning session actor that reclaims its complete retained state between calls
for a long-lived service. These tests are not a multi-hour memory soak. The
existing 32-bit host clock wrap also remains outside this Unix validation.

The native setup sequence is illustrated in
[`tests/mqttclient.fpr`](../tests/mqttclient.fpr): create/reuse a Resolver pool,
start Readiness, connect with `WatchedTransport.wait`, optionally upgrade to TLS,
create the MQTT client, begin and pump its effects, then stop and close owners.
Python and Docker in the acceptance harness are test drivers only; neither is
called by these FP-RISC libraries or their native engine adapter.

### Third-slice acceptance

`tests/check_native_services.py --openssl-prefix /path/to/openssl3 --broker`
builds isolated executables and tests one and four macOS AArch64 harts. The
broker image is pinned to Mosquitto 2.0.22's manifest digest; its disposable
container binds only loopback and is removed after the test. Public OpenSSL
test identities and their license are kept under `tests/fixtures/tls`.

Acceptance covers deterministic delayed DNS, pool saturation after abandonment
and recovery, cancellation, localhost IPv4/IPv6 fallback, connected transfers,
duplicate adoption refusal, stale/empty-operation refusal, wrong-owner refusal,
forced descriptor-number reuse without stale-alias access, and socket cleanup
after killing its actor. TLS covers verified echo, a 256 KiB
fragmented echo, wrong name, unrelated CA, expired certificate, rejected minimum
version, handshake/read stalls, explicit unavailable engine and a synchronized
blocked trust-file read whose abandoned worker retains/reclaims its admission
slot. MQTT covers published wire vectors, all incomplete byte prefixes, bytewise
fragmentation/coalescing, bounds/refusals, in-flight IDs, DUP reconnect effects,
subscription refusal, stale epochs, keepalive and delivery retention after a
failed PUBACK. Real Mosquitto TCP/TLS tests cover subscribe, publish, QoS 1 echo
and idle keepalive on the same connection.

The existing transport/readiness suite and TCP, HTTP-limit, Poller-stop and
actor-call fixtures pass on one and four host harts. Native facility export/
dependency checks and watcher regressions pass. Portable Transport and MQTT
codec/session tests also pass under two-hart RV64 QEMU. Tang Nano refusal shims
and host-compiled ESP-IDF refusal branches compile; those are not physical-board
or ESP-IDF runtime validation.

Remaining integration: replace HTTPS's curl path, validate native telemetry
and cameras against real printer certificate/device policies, and migrate
gateway authentication and process supervision. Existing application helpers
remain until those migrations have acceptance evidence.


## Implementation slice 4: authenticated MQTT and native printer telemetry (2026-10-15)

`MQTT.Connect client clean keepalive` remains the anonymous packet. The new
`ConnectAuth client clean keepalive credentials` takes `UserName name` or
`UserPassword name bytes`. Usernames use MQTT's UTF-8 rules; the password is
0..65535 binary bytes, with no UTF-8 or NUL restriction. CONNECT flags and
payload ordering are checked on decode, including password-without-username,
reserved/will bits, truncated fields and trailing data. Both fields are bounded
at 65535 bytes. Errors describe the field/condition without copying its value.

`MQTTSession.config` preserves the anonymous configuration helper.
`configAuth credentials client clean keepalive ackMs capacity` validates and
retains explicit credentials for subsequent `Start`/reconnect effects. Broker
CONNACK refusals remain `Down` notices. These pure APIs do not provide transport
secrecy: an authenticated application must use verified TLS. Credentials are
ordinary immutable runtime values, not zeroizing secret buffers; do not print
packets, configuration or client state. No AWS secrets are fetched by this code.

`examples/printer-telemetry.fpr` is the first application migration. It connects
through bounded DNS/TCP and verified native TLS, reads one access code from the
specified environment variable, authenticates as `bblp`, subscribes to exactly
`device/SERIAL/report`, and requests `pushall` on `device/SERIAL/request` only
after SUBACK. There are no print, motion or temperature commands. It restores
the subscription/status request after reconnect with 1..30 second backoff.
The original 5-second setup budget covers TCP and TLS; protocol reads use
250-ms turns and keepalive. `Sys.loop` reclaims turn scratch. There is one
collector process, resolver slot and active TLS connection per configured
printer (at most 24 through the gateway).

`std/printertelemetry` performs the public report projection in FP-RISC.
It retains an allowlist of bounded display fields, merges scalar deltas and
keeps AMS/external filament labels, ignores command acknowledgements as fresh
telemetry, preserves last known values offline, and uses monotonic freshness.
A 256-KiB body and depth-32 preflight bound parsing; labels and tray counts are
bounded. Numeric fields accept integers and bounded plain decimals, rejecting
exponents rather than risking non-finite values in downstream JSON consumers.
Report rate uses at most thirty one-second buckets (a quantized 30-second
window). The stdout projection never includes access codes, raw reports, host
configuration or arbitrary JSON fields.

The gateway's opt-in `--native-telemetry=EXECUTABLE` path supervises this
collector and consumes its public JSON projection. It does not import Paho or
parse MQTT/report payloads in native mode. Each child receives only its selected
printer code under `FPR_PRINTER_CODE`; codes are absent from arguments, public
snapshots and the UI process environment. Camera framing, login/signature
verification, HTTP/WebSocket proxying and supervision still use Python. The
existing default path is unchanged; no deployed dashboard was restarted.

Native mode currently requires explicit `--config` entries with `tls_ca` and
`tls_peer` (and optional `mqtt_port`, default 8883). The peer must match the
printer certificate and the CA file must establish trust. The old Python LAN
adapter disables certificate verification; that behavior is intentionally not
an available native fallback. Discovering/checking real Bambu certificates,
device-specific trust requirements, and physical-printer acceptance remain.
See [the application instructions](../examples/printer-dashboard/README.md#native-telemetry-opt-in).

Acceptance executed on macOS AArch64:

- Authenticated CONNECT wire vectors, binary/empty passwords, username-only,
  invalid flags/lengths/UTF-8, session refusal and reconnect; portable codec and
  session checks also pass on two-hart RV64 QEMU.
- Pinned Mosquitto 2.0.22 anonymous/authenticated TCP and TLS, invalid-password
  refusal, QoS 1 echo and idle keepalive on one/four harts. All native DNS/TLS
  setup, ownership, worker-bound and failure regressions still pass.
- A synthetic TLS printer plus the actual gateway supervisor on one/four harts:
  authenticated CONNECT, exact report subscription, read-only status request,
  fragmented/coalesced reports, wrong-topic exclusion, delta retention across
  reconnect, resubscribe, private-field exclusion, auth refusal and wrong-peer
  TLS rejection. Test identities/credentials are public or synthetic.
- Pure projection checks cover freshness, AMS/external deltas, invalid numeric
  values, packet/depth bounds and expiry/bounds of rate storage.

This is local/simulator evidence, not real A1/P1S validation, a completed
Python removal, or a long-duration process memory bound.


## Implementation slice 5: native shared camera framing and streaming (2026-10-15)

`examples/printer-camera.fpr` runs a private, loopback HTTP camera service.
`examples/printer-dashboard/cameraframe.fpr` owns the Bambu application framing:
80-byte login (four little-endian words plus two NUL-padded 32-byte UTF-8/byte
fields), then a 16-byte record header whose first little-endian word is the
JPEG payload length. The other twelve bytes are opaque, preserving the legacy
bridge behavior. Empty, overlong or embedded-NUL login fields are refused.
A payload length outside 4..4194304 is rejected before any body read/allocation.
JPEG SOI/EOI markers are checked; this is not a full JPEG decoder or integrity
check. Fragmented headers/bodies are read exactly; a truncated/invalid record
ends that upstream connection. Partial prefixes are never replayed as a new
record.

The camera worker owns bounded DNS/TCP, verified native TLS and the login/frame
connection. A single 5-second setup/login budget and a single 10-second budget
per complete header/body prevent indefinite handshake or drip-feed reads.
Camera trust defaults to the configured telemetry CA/peer, with explicit
`camera_tls_ca`/`camera_tls_peer` overrides. No verification-disabled fallback
exists. `camera_port` defaults to 6000. Real Bambu camera certificates may need
independent trust/identity configuration; no device certificate is guessed.

A native manager owns one upstream worker and latest frame for up to eight
viewers. First-viewer admission starts the worker; final-viewer departure kills
it, triggering native resource cleanup, and drops the cached frame/rate state.
Three-second renewable viewer leases cover abandoned/killed handlers. Generation
IDs and source identity reject late publications/failures from a retired worker.
At most sixteen HTTP handlers are admitted before spawning, including bounded
header/stats requests. Mailbox admission/calls are bounded. A source publishes
one frame then waits for its acknowledgment, so there is no unbounded frame
queue; each viewer polls for the latest sequence and can skip frames.

`std/mjpeg` provides reusable checked-Transport multipart output. Header,
payload and CRLF share one absolute budget without accumulating an entire
response. Slow viewers get a 1.5-second whole-part write budget and are detached
on failure. Their partially written parts are never retried from byte zero.
The native HTTP adapter accepts bounded header-only GETs (8192 bytes, two seconds,
at most 64 headers), refuses bodies/transfer coding, and closes after streaming.
Clients disconnected while waiting for a frame are detected without waiting for
the upstream 10-second record deadline. The manager and worker/viewer/accept
turns use `Sys.loop` to reclaim scratch. There is no hard whole-process memory
bound or long-duration soak claim; a latest frame plus in-flight viewer copies,
transport buffers and runtime bookkeeping still occupy memory.

The gateway's `--native-camera=EXECUTABLE` option supervises one private native
service per configured printer, starting it only on the first authenticated
camera request. The idle service can retain its local listener, but no upstream
TLS connection or frame is retained without viewers. A randomly generated
runtime capability (`FPR_CAMERA_GATE`) protects the private `/stream` and
`/stats` endpoints; only the gateway supplies it. Printer code and capability
are sent through the native process environment, not command-line arguments,
public JSON or the UI environment. Native `/stats` contains only public camera
metadata. Python reads those metadata and relays the native multipart HTTP body
as opaque bytes: it no longer parses camera records, validates JPEGs, creates
multipart parts or owns upstream viewer sharing in native-camera mode.

Public gateway login, origin checks, camera availability checks, browser media
lifecycle and logout/expiry remain enforced. Stream relay rechecks authorization
at most every 250 ms while waiting, with the existing bounded client-write timeout
when a browser is slow. Revocation closes the private stream and removes its
viewer. A source error before the first frame returns camera-unavailable; after
HTTP output begins it closes the stream. The default legacy/demo camera path is
unchanged. Public gateway/authentication and supervision still use Python.
No running dashboard was restarted or actual printer contacted by these checks.

Acceptance on one and four macOS AArch64 harts uses public OpenSSL test identities
and synthetic codes:

- Byte-fragmented 16-byte headers/JPEG bodies, multiple consecutive valid multipart
  parts, exact binary lengths and redacted public metadata.
- One source shared by two/eight viewers, refused ninth viewer, one-viewer departure
  preserving the others, final-viewer socket/frame release, and fresh generation
  after reconnect. A missing/wrong private capability never starts upstream TLS.
- Oversized lengths rejected before body reads, malformed JPEG markers, truncated
  bodies, stalled header deadline, and wrong verified TLS identity.
- A non-reading viewer with a 4-MiB part is retired by the write deadline and releases
  the upstream source. Cancellation during a partial/stalled record releases the
  upstream within two seconds instead of waiting for its 10-second read budget.
- The real authenticated gateway relays consecutive native multipart JPEGs; anonymous
  access does not start the service, and logout closes an active stream/upstream.
- Pure login/record/multipart checks run on the host and two-hart RV64 QEMU. Existing
  dashboard/login/camera/WebSocket and native telemetry regressions pass.

Run `tests/check_native_camera.py --binary=build/printer-camera` with the same
Python test environment as the dashboard tests. See the [camera setup](../examples/printer-dashboard/README.md#native-camera-opt-in).
Initial evidence was simulator-based. The subsequent deployment below covers
actual A1/P1S trust and camera compatibility; longer lifecycle/soak validation
remains separate.


### Production acceptance (2026-10-15)

Both physical printers now run through native telemetry and cameras on the
public dashboard. Bambu Studio's installed public printer CA bundle validates
both MQTT and camera certificate chains; each configured peer is the recorded
printer serial, matching the certificate CN. No verification bypass or trust
on first use was added. A runtime-only public config and selected-code
`--credentials-env-file` loader keep code values out of the source/arguments.

Authenticated public HTTPS checks observed both printers ONLINE with fresh
reports, two consecutive valid camera JPEGs per printer, and native camera
OFF/zero-viewer state after closing the feeds. Anonymous status remained 401;
logout revoked the checking session. The [deployment record](../examples/printer-dashboard/README.md#production-native-deployment-2026-10-15)
has the launcher, CA provenance and ignored evidence locations. Public gateway
login/proxying and supervision still use Python. This acceptance is a real
read-only printer transport/camera check, not a print completion or memory soak.

## Native HTTP client follow-through (2026-10-15)

The curl replacement is now implemented in `std/httpclient` and used by
`std/http`. It uses bounded DNS/checked TCP/verified TLS and a shared absolute
request budget, with strict bounded response framing and deterministic cleanup.
The [completion record](2026-10-15-PURE-APPLICATIONS.md) describes API limits,
caller-owned DNS admission and one/four-hart simulator evidence. Python public
gateway/authentication removal remains separate work.

## Native application host (2026-10-15)

The [pure-application record](2026-10-15-PURE-APPLICATIONS.md) now describes the
single-process FP-RISC public gateway, authentication, actor supervision and
generated login/session/client behavior. Python runtime code was retired to
legacy test fixtures. Local TLS simulator and browser acceptance is distinct
from the still-required native-host production/real-printer redeployment gate.
