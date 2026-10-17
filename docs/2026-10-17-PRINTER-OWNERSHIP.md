# Linear printer connections and camera buffers

Date: 2026-10-17. Local acceptance only: remote Macs and real printers are
unreliable/unavailable for this task. No remote connection, deployment or
physical-printer claim is part of this work.

This implements the ownership follow-up from
[contracted application cores](2026-10-17-CONTRACTED-APPLICATION-CORES.md).

## Application ownership

`std/ownedtransport.fpr` defines a linear `Connection` and an explicit linear
`Opened` result. TCP setup/adoption creates one owner. TLS upgrade consumes the
TCP owner on success or failure. Reads, writes, readiness and pauses consume
the current owner and return its successor, including operation failures.
`close` consumes the final owner and returns only the cleanup result.

`std/ownedmqtt.fpr` similarly owns the existing MQTT pump through `Client`,
`Created` and `Slot`. These explicit sum types retain linear constructor-field
shapes rather than depending on generic Option/Result ownership propagation.
Creating a client with invalid decoder limits closes the consumed connection.
If cleanup also fails, the result preserves both failures. Graceful `stop`
consumes the client too; the fast `close` remains available for failed sessions.
Metadata queries and retained-notice drains return the successor client.

The actual telemetry collector and `printer-host` separate unrestricted status
metadata from their linear client slot. Reconnect/error paths consume and close
the old client; a replacement starts from an empty slot. The camera source,
private viewer connections and multipart adapters also thread the linear owner.
Camera source termination returns its final connection to one terminal close.

The checker now recursively checks constructor patterns for discarded linear
fields: `Opened _` cannot silently leak a successful connection or buffer.
Direct aliases, old generations, ignored successors and duplicated closures are
covered by refusal tests.

## Buffer mechanism and publication

`examples/printer-dashboard/framebuffer.fpr` supplies a linear `Buffer` over
`machine/posix/os_frame.c`. The native adapter provides bounded byte storage and
checked actor identities, using the existing native resource registry. It does
not implement JPEG framing, TLS/MQTT policy, retries or presentation.

`cameraframe.readOwned` validates the 16-byte protocol header before allocating
the exact admitted payload capacity. Each body step reads at most 16 KiB into
the buffer in a scratch-arena iteration. One-byte network fragmentation cannot
accumulate an entire frame's strings or list nodes. JPEG marker validation stays
in FP-RISC. Publication consumes the buffer, creates one immutable snapshot and
frees native storage; failures close it. The shared manager/viewers receive
immutable snapshots, not aliases to mutable buffer storage.

Actor death also frees the buffer. Snapshot allocation installs a cleanup node
inside the native allocation, never on the shared native CSTACK. IDs never reuse;
native stale/foreign-actor access is rejected even through a low-level test seam.

## Explicit resource bounds

| Resource | Enforced limit |
| --- | ---: |
| One native frame payload | 4 MiB |
| Active native frame buffers per process | 16 |
| Sum of native buffer payload capacities per process | 32 MiB |
| One native append/read offer | 16 KiB |
| Source frame read budget | One absolute 10-second budget |
| Viewers per camera | Existing maximum 8 |
| Reserved private handlers per camera | Existing maximum 16 |
| MQTT packet / read chunk / in-flight entries | Existing 256 KiB / 16 KiB / 8 |

Native buffer metadata adds at most 16 buffer headers and registry entries.
During publication both the admitted native payload and one same-size immutable
snapshot can exist. TLS buffers, actor messages, retained snapshots and the
allocator's reservations are additional; 32 MiB is not a total process RSS bound.

`resourcecore.fpr` declares and proves these FP-RISC scalar bounds:

| Function | Work | Allocation |
| --- | ---: | ---: |
| `remaining` | 4 | 0 |
| `readSize` | 3 | 0 |
| `chunks` | 3 | 0 |
| `backoff` | 4 | 0 |

Capacity arithmetic subtracts only admitted bounded integers. Backoff saturates
at 30 seconds, including caller-supplied intermediate values. `chunks` describes
full-sized chunk scheduling (maximum 256), not network fragmentation: up to one
successful body read per payload byte is possible. Wait attempts depend on
readiness/deadlines. Native copy/crypto, waiting, parsing and actor delivery costs
remain opaque to the compiler. No whole-frame WCET declaration hides those costs.

## Trust and language boundary

The linear guarantee applies through the named owner APIs. FP-RISC currently
exports constructors; these forwarding modules/native declarations are trusted
mechanism seams, not opaque capabilities. Raw transport/native IDs, generic
`keep`/`drop`, and deliberate owner reconstruction are low-level escapes rather
than automatic native-resource disposers. Application paths use explicit
`close`/`finish`; native quotas and actor-death cleanup remain the backstop.
The [compiler ownership corrections](2026-10-17-OWNERSHIP-CORRECTIONS.md) now
preserve known record fields and control-flow results. General propagation
through polymorphic containers, unknown row tails and arbitrary higher-order
captures remains separate compiler work; the linked audit records accepted
bypasses even through normal owner APIs.

The two std facades have no new recursive/unsafe-marked helpers and join the
[reviewed safety allow-list](2026-10-15-SAFETY-ALLOW-LIST-REVIEW.md).

## Local validation

The dedicated suite is `tests/check_printer_ownership.py` (registered in
`check_base.py`), with `tests/printerownership.fpr` as its runtime fixture.
It tests one/four harts, explicit owner refusals, native quotas, exact and
incomplete publication, fragmented/truncated/invalid JPEG reads, cleanup after
errors, stale IDs, wrong actors and cancellation. Twenty consecutive 4 MiB
snapshots return native live accounting to zero and increase the actor heap by
less than 1 MiB. Independent arithmetic references and deliberately insufficient
work/allocation declarations exercise the resource core.

Local TLS collector/camera suites use openly published test certificates,
synthetic identities and loopback printer peers. Python is a test driver only.
The actual native-host gateway acceptance runs with an empty external-tool PATH.

Completed acceptance on the local macOS AArch64 host:

- Dedicated suite passes on one/four harts: 12 compile-time ownership refusals,
  eight proven scalar resource declarations, 303 independent reference cases,
  insufficient work/allocation refusals, graceful MQTT stop, cleanup-error
  preservation and all runtime buffer lifetime/quota/heap-plateau checks above.
- `check_native_camera.py` passes on one/four harts against loopback TLS camera
  peers: sharing, viewer/handler limits, binary frames, oversized/malformed/short
  bodies, trust refusal, slow viewer deadlines, final-viewer cancellation and
  authenticated gateway handoff.
- `check_printer_native.py` passes on one/four harts against local TLS/MQTT
  peers: authentication, delta/freshness projection, reconnect/resubscribe/pushall,
  authentication/trust refusal and handoff.
- The complete native `printer-host` builds. `check_native_gateway.py` passes
  in demo and loopback TLS-peer modes on one/four harts with an empty tool PATH:
  telemetry, cameras, native authentication, WebSocket live state and logout
  revocation all work together.
- Existing transport/readiness and native/Sol higher-order contract suites pass.
  The safety allow-list covers all 94 std modules; the pure-application audit
  passes across 101 native modules plus Sol web/automation. The pagination
  module's earlier missing allow-list entry was also corrected.

No remote Mac, real printer, deployment, hardware WCET, complete-process RSS or
long-duration soak was tested.
