# Printer dashboard outage, 2026-10-20

## Outcome

The socket-lifetime fix and bounded TCP/TLS diagnostics are now deployed.
After the owner allowed the pending macOS prompts, the exact staged release
passed public A1/P1S telemetry, cameras, WSS and logout acceptance. Earlier
failed attempts and rollbacks are retained below as incident history. See the
final permission-approved deployment section for current identity and evidence.

Restored `https://3dprint.cswine.cloud` by sending SIGTERM to only the unhealthy
Printer Host process on the M1 Mac mini. The existing system LaunchDaemon
restarted it. Public GET `/health` and `/` returned 200; anonymous `/api/status`
remained 401. No printer motion, temperature, upload, print, IP configuration,
auth allowlist, Nginx production configuration or maintenance data was changed.
Existing login sessions expire on application restart.

Fresh authenticated public acceptance also passed: both A1 and P1S ONLINE
with fresh telemetry, WSS snapshots/updates and camera controls, two consecutive
JPEG frames per printer, shared upstreams, final-viewer cleanup and logout
revocation. Maintenance retained ten tasks, revision zero and zero history
entries. The checker saved only sanitized evidence, not private keys, bearer
cookies or camera pixels.

Missing HTTP health supervision allowed the outage to persist: the process
stayed alive and listening while resetting requests, so launchd KeepAlive did
not restart it. A socket lifetime defect was subsequently reproduced and fixed (see follow-up below). Whether it alone caused the sustained outage remains **unconfirmed**.
A same-user HTTP watchdog was installed as containment, with important login
session limits described below.

## Evidence and timeline (Australia/Sydney, UTC+11)

- Current process began Sunday 18 October at 01:22:01, PID 1095. At inspection it
  had run roughly 58 hours. The mini itself remained online and reachable.
- The earliest retained reset error for this run was 20 October 09:38:42
  (Nginx log timestamp `2026/10/19 22:38:42` UTC). There may have been an earlier
  silent onset; request logs do not establish the exact failure transition.
- The public check at 11:31:29 returned 502. Direct access to the app's Tailscale
  listener also reset, including a curl executed on the mini itself. This
  isolates the failure below public DNS/TLS/Nginx.
- At 11:34, PID 1095 still owned port 6730. lsof showed only about 26 lines,
  two established printer MQTT sockets, and its internal listeners. RSS was
  roughly 18 MiB; sample reported physical footprint 116.7 MiB, peak 116.8 MiB.
  There was no evidence of descriptor exhaustion or a continuously growing
  memory peak in that snapshot. It does not prove absence of leaks over time.
- The three-second sample showed scheduler waits and active accept-loop paths.
  This is not evidence of a whole-process CPU spin or a proven global deadlock.
- Existing logs were preserved before restart. They include historical
  `gateway: cannot listen` and `live: restart failed: no program named` entries;
  these untimestamped accumulated messages cannot be assigned to this outage.
  The former corresponds to an earlier launch attempt, not proof of why PID
  1095 later reset requests.
- SIGTERM of PID 1095 let launchd start PID 96122. Health recovered immediately.
  The same binary and configuration were used; no compiler/runtime rebuild was
  deployed. Printer MQTT sockets remained/re-established after recovery.

Maintenance snapshot SHA-256 before and after recovery:
`5b7be6d7369c1141daf4e9d27028ab5699f9c2d49055520bb8d3ac7a3750b2f3`.

Signed deployed executable SHA-256:
`d9c0b0f20a577ac9431e682a477c3f48026e5a6dae62ce960e6593cdf886facf`.
Source/application release is `b4158705155c9fc901d9b2bd3e07e968636d99cc`.

## Investigation and what is not established

The deployed release already contains the earlier gateway fix that reaps dead
handlers even when completion notices are lost. We must not assume that earlier
32-handler exhaustion bug explains this incident. Socket adoption/read/write
failures are not sufficiently observable in the deployed gateway to identify
the exact reset path from retained logs alone.

An isolated demo run of the corresponding unsigned release binary (SHA-256
`496fed453a38a22d7c605a7f408614c8ccf2b14acf36f421169bf944c3c721dc`)
passed 1,000 sequential health requests, 2,000 requests with concurrency eight,
and 240 malformed/early-close connections using four harts, followed by healthy
responses. It ran for 16.39 seconds and used no printers or production data.
This short probe did not reproduce the fault and does not cover 58-hour uptime,
real telemetry reconnects, authenticated view traffic or camera concurrency.

Public scanners reached the app with unrelated Host names before/during the
failure; the application normally rejects those with 403. Their presence is
not proof of causation. Neither a printer DHCP-address change nor a Tailscale
outage explains the locally reproduced HTTP reset with established MQTT sockets.

## Containment and recurrence evidence

Installed `deploy/printer-dashboard/watchdog/watchdog.py` on the mini. The
LaunchAgent probes HTTP every 30 seconds, requires three consecutive failures,
allows 120 seconds for a newly observed PID, and limits recovery to once per ten
minutes. It checks process owner/path and the system launchd identity; it leaves
intentionally stopped services alone. Before SIGTERM it saves bounded logs,
thread sample, sockets and maintenance hash and repeats the identity/health
checks. It never starts a second app or writes maintenance data. Eleven recovery
guard tests passed. The deployed launchd context returned success with zero
failures against the healthy app.

**Coverage limit:** this watchdog currently belongs to jq's GUI login session,
not the system boot domain. It loads at login and stops at logout. System-wide
installation requires admin access unavailable through passwordless sudo in this
session. The original app still runs as a system LaunchDaemon. No reboot or
production failure injection was performed. See the
[watchdog runbook](../deploy/printer-dashboard/watchdog/README.md).

If this recurs, inspect `diagnostics/watchdog-<timestamp>/` before changing
versions. A repeat needs targeted adoption/read/write failure counters and
application actor state to distinguish a transport ownership fault from a
handler/runtime liveness problem. Avoid calling the underlying defect fixed
until a reproduction and a specific regression test exist.

## Operational documentation correction

The tracked Nginx template and old deployment introduction still pointed to
retired `100.94.229.117:6730`, although production correctly used the mini at
`100.107.153.43:6730`. Updated those tracked references so redeploying the template
cannot silently restore the old upstream. This stale template was not the cause
of today's outage; live Nginx configuration was correct and unchanged.

Initial SSH diagnosis used the workstation's default username and was denied.
The documented accounts, `root@localhost-0` and `jq@100.107.153.43`, worked.
No SSH credentials were changed. A proposed external watchdog route from the
Linode was not adopted because SSH trust was not configured there; no host-key
checks were disabled and no private keys were copied.

## Evidence locations

On the mini, retained before recovery:
`/Users/jq/printer-host/diagnostics/incident-20261020/` contains launchd state,
stdout/stderr and the native stack sample. The snapshot contains no dumped
credential files. The local ignored directory
`build/printer-incident-20261020/` contains the copied stack sample, bounded
request-probe script, probe stderr and `public-acceptance.json`. Future watchdog captures have bounded
retention of ten incidents, separate from this initial evidence.

## Follow-up: reproduced cross-connection WebSocket write (20 October)

A combined isolated workload exposed a concrete defect in `std/live.fpr`.
The WebSocket reader sent `Stop` to its sibling writer and returned immediately.
`std/tcp` then closed their shared raw descriptor. The writer could still send a
close frame or a queued view update after the OS reused that descriptor for a
new connection, including the public gateway's checked HTTP connection.

This is confirmed by captured synthetic wire failures, not just source review:
health responses began with `88 02 03 e9` (a WebSocket close frame, code 1001)
followed by `HTTP/1.1 200 OK`. Another contained a JSON WebSocket update before
that close frame and HTTP header. Camera HTTP headers and new WebSocket JSON
were also corrupted. The original deployed binary produced 18 malformed health
responses during a 120-second churn run. A clean rebuild of the exact deployed
source reproduced the same wire signature.

The fix makes reader teardown send Stop and await writer termination within one
two-second budget, then retire a stuck writer before the socket can be closed.
The reader and writer are pinned to the same hart by `spawnWith`, so retirement
cannot race a native write on another hart. The refused-join path also retires
its writer. This is a socket lifetime fix, independent of process restarts.

`tests/check_live_writer_lifetime.py` uses the real Live reader teardown with a
deliberately delayed writer and a writer that never finishes. The old source
fails deterministically because EOF arrives before the delayed close frame.
The fixed source passes on one and four harts: close frame before EOF, bounded
stuck-writer retirement, and clean subsequent HTTP responses. The test is wired
into `tests/check_base.py`. It also passes using the current development compiler.

A first repaired build passed 31,698 health requests, 1,733 WebSocket sessions,
2,623 camera requests, 10,235 malformed/aborted requests, 75 synthetic MQTT
connections and 41 synthetic camera connections in 120 seconds with no wire
errors. Deliberately interrupted camera sources occasionally return 503, then
recover; these are expected unavailable responses, not corrupt HTTP. The final
bounded candidate also passed all native gateway acceptance cases (demo and TLS
printer/camera peers, each with one and four harts). Final release and deployment
results are recorded below.

Socket adoption now emits exponentially sampled diagnostics by failure stage
(socket type, peer check, nonblocking setup or ownership), preserving the error
returned to callers. Entries contain time, count, descriptor number and errno;
no request bytes, cookies, keys, peer addresses or printer credentials. This
provides evidence if a separate persistent-reset defect recurs.

**Causality limit:** the reproduced defect explains malformed responses and
intermittent failures. The tests have not reproduced the original state where
every request reset after roughly 58 hours. It is not yet established that this
race alone caused that sustained outage. Keep the watchdog as containment and
retain recurrence evidence; a successful short soak is not long-term proof.

### Reproduction and evidence

Historical baseline worktree: `/private/tmp/fprisc-printer-rootcause`, detached at
`b4158705155c9fc901d9b2bd3e07e968636d99cc`. Production candidates use that baseline
plus only the Live lifecycle fix and bounded adoption diagnostics, avoiding
unrelated compiler/runtime changes on current main. The regression fixture and
fix are also present in the primary checkout. The later commit/push and
redeployment attempt are recorded below.

Run the deterministic check on current source:

```sh
python3 tests/check_live_writer_lifetime.py
```

Ignored `build/printer-incident-20261020/` retains `churn_probe.py`,
`churn-baseline.out`, `churn-fixed.out`, `churn-candidate.out`, and bounded stderr
logs. The churn probe uses generated test identities, disposable data, loopback
TLS fixtures, repeated upstream disconnects and concurrent HTTP/WS/camera
traffic. It does not contact real printers or write production maintenance data.

### Targeted release tested; deployment rolled back

Two controlled deployment attempts (approximately 12:06 and 12:10 AEDT) kept
HTTP and public-key login working but left both printers OFFLINE with zero
reports. The second explicitly force-registered the bundle with LaunchServices;
that did not restore printer access. **Both attempts were rolled back.** See the later redeployment below
for current status. No permission settings
or privacy databases were changed.

The original approved binary immediately re-established both MQTT connections
after the first rollback. Full authenticated acceptance then passed A1/P1S
telemetry, WSS, both cameras, shared streams, cleanup, maintenance and logout.
Final acceptance after the second rollback is recorded separately below.

Evidence points to a macOS app/network identity problem, but a specific Local
Network denial has not been directly observed. `nehelper` reported that it could
not find the bundle ID/display name for `printer-host-recovery` at both attempted
starts, despite the installed bundle and code signature using
`cloud.cswine.printer-host`. Both binaries load the same OpenSSL dylib paths.
Their ad-hoc designated requirements and Mach-O UUIDs differ, as expected for
changed executables. At this point, inspection of the app's Local Network permission from
the mini's desktop was the next diagnostic step. Do not describe this
as proof that a particular privacy setting is disabled.

The user was asked whether they can access the mini's desktop. The approved app
was restored instead of leaving the public dashboard with unavailable printers.

- Release: `releases/b415870-writer-lifetime-20261020/` on the mini.
- Unsigned artifact SHA-256: `4dea9def87375eae17f341b6c66d1ec70959552494bde46b0986985a5c1e36cf`.
- Signed candidate artifact SHA-256: `ea48172ab32f7fe113c29c3b8937bfc440fcf0903429c285b4484816475f0776`.
- Exact source patch SHA-256: `6e51c9d7c098f657687e31097e1cc12349d719e87addb3b41169989630131454`.
- Rejected candidates retained at `rollback/writer-lifetime-20261020T010631Z/unaccepted-PrinterHost.app` and `rollback/writer-lifetime-20261020T011023Z/unaccepted-PrinterHost.app`.
- The original signed app is restored at `PrinterHost.app`, hash `d9c0b0f20a577ac9431e682a477c3f48026e5a6dae62ce960e6593cdf886facf`.
- Persistent maintenance snapshot hash remained unchanged across deployment.

The final bounded candidate completed 35,049 health requests, 1,993 WebSocket
sessions, 2,848 camera requests, 10,370 malformed/aborted requests, 75 MQTT
connections and 40 camera connections in 120 seconds with zero wire errors.
The final deployable build (including diagnostics) passed all four gateway
acceptance cases. Native ownership tests passed with one and four harts,
including duplicate rejection, descriptor reuse, stale aliases, owner death,
DNS recovery and cancellation; the expected duplicate-adoption diagnostic was
emitted without changing the returned failure semantics.

`socket-fix-deployment.json` records installation and hashes in the local ignored
evidence directory. The versioned release on the mini also retains the exact
patch, unsigned binary, installer, first attempt, deployment and rollback records.
Future installation must leave current `data/` untouched. HTTP health alone is
not deployment acceptance: fresh authenticated telemetry from both printers and
camera checks must pass before promoting this build.

### Recovery verification after the second rollback

After the second rollback, the service runs PID 97596 with the original signed
binary hash. Both printer MQTT sockets are established. The watchdog records
zero failures and no watchdog restarts; the maintenance snapshot retains its
original hash. A first public acceptance attempt reached fresh telemetry but
timed out reading the authenticated page. The repeat passed full final acceptance: both printers ONLINE with fresh
reports, authenticated page and WSS updates, two JPEG frames per printer, camera
sharing and final-viewer cleanup, maintenance controls and logout revocation.
Evidence is `build/printer-incident-20261020/public-final-restored.json`. The
initial timeout is retained as an observation, not explained away.

For the next deployment investigation, distinguish observed loss of LAN access
from the hypothesis about macOS privacy identity. Do not edit the privacy database,
spoof the prior executable UUID/hash or disable protection to make it pass. Check
the updated app in the mini's desktop context and inspect the Local Network
permission/identity before promoting it. Current production stays on the approved
binary until the fixed build passes real telemetry and camera acceptance.


### Requested redeployment: native diagnostics and remaining OS access blocker

At the owner's request, a further release was built from the same `b415870`
baseline with the Live writer fix and bounded native failure diagnostics.
TCP connect failures now record a stage and numeric errno; TLS failures record
operation, count, errno and certificate verification result. Counters retain
only the first four and powers of two per stage/operation. Neither records
printer credentials, auth material, payloads, peer names or certificate paths.
The existing caller error and TLS verification behavior are retained.

The investigation did not establish a credential parser failure. The prior
candidate passed the full synthetic gateway suite with credentials supplied
through `--credentials-env-file`, including quoted/exported test values, on
one and four harts. A temporary diagnostic app launched in the desktop context
then passed real A1/P1S telemetry, both cameras, WebSocket updates, cleanup,
maintenance and logout through an SSH tunnel. Substituting the exact earlier
release binary in that same isolated bundle failed fresh telemetry. Therefore
success of the diagnostic artifact was not treated as acceptance of the release.
The temporary apps were stopped and their LaunchServices registrations removed.
No privacy database, executable UUID or OS protection was altered.

The original production process also lost printer reconnects during these concurrent app/registration tests. HTTP continued working. Re-registering the canonical app
and restarting the original binary did not immediately restore printer sockets.
Thus earlier successful rollback evidence must not be presented as current
printer availability after these tests.

The new release was installed at approximately 12:49 AEDT (PID 99022). HTTP and
login worked; public real-printer acceptance failed. Native logs now establish
that `connect()` fails immediately with macOS errno **65 (No route to host)**,
before TLS verification or MQTT authentication. Both printer ports were reachable
at the same time with `nc` from SSH. This strongly supports an app/context-specific
macOS network permission or identity problem rather than a physical printer,
LAN routing or credential failure; the exact permission record remains unverified.
The owner cannot access the mini desktop to inspect/allow Local Network access.
The candidate was rolled back rather than accepted with both printers offline.

- New release directory: `releases/b415870-writer-lifetime-v2-20261020/`.
- Unsigned SHA-256: `18901dde6216f4385552442b6364a54457eb4ad06e40f8631b37a09d78e3c9ca`.
- Signed SHA-256: `04eb35dfa6033ec28fd7258031cc375ad871332bb72f383ce094fda439550070`.
- Exact baseline source patch SHA-256: `21a8a370db71354baa7a0ceb11a7bd6387e412c6a7d9fce9a246a51ef3a15ead`.
- Rollback directory: `rollback/writer-lifetime-20261020T014924Z/`.
- Maintenance snapshot hash unchanged: `5b7be6d7369c1141daf4e9d27028ab5699f9c2d49055520bb8d3ac7a3750b2f3`.

Validation for the source changes: the deterministic Live writer regression
passed with one/four harts; all eleven watchdog tests passed; native connection,
MQTT, TLS echo/large payloads, wrong identity/untrusted/expired certificate
rejection, TLS minimum-version rejection, handshake/read deadlines and worker
capacity recovery passed with one/four harts. The final binary passed all four
synthetic gateway/auth/camera cases. These checks do not establish real-printer
production acceptance or a fix for the original 58-hour sustained outage.


### State after the failed redeployment attempt (superseded below)

The final rollback runs PID **99153**, the original signed executable
`d9c0b0f20a577ac9431e682a477c3f48026e5a6dae62ce960e6593cdf886facf`.
Fresh public HTTPS acceptance passed after this rollback: both printers ONLINE
with fresh reports, authenticated page and WSS updates, camera toggles, two JPEG
frames per printer, shared upstreams, final-viewer cleanup, maintenance controls
and logout revocation. Maintenance still has ten tasks, revision zero and no
history entries. Evidence: `build/printer-incident-20261020/public-after-v2-rollback.json`.
Both test app processes and the temporary SSH tunnel have been stopped.

The requested source changes are committed for push to `main`; the new release
is staged with its exact patch and rollback evidence but is **not promoted**.
The local branch already contained five commits ahead of `origin/main`; the
normal push includes those ancestors as well as the scoped printer fix. The
unrelated untracked `.claude/` directory is excluded. No release tag is created.

At that point, next deployment acceptance required the updated app to have working Local
Network access in its actual system LaunchDaemon context. Inspect permissions
from the mini desktop, then install the staged bundle and repeat real-device
acceptance. Retain the original app rollback until that passes. A diagnostic
app's success, SSH TCP reachability and `/health` are each insufficient alone.


### Permission-approved production deployment

At approximately 14:19 AEDT on 20 October, the owner reported allowing all
pending prompts on the M1. The **same** staged v2 artifact was installed again,
without rebuilding, changing its signature identity, weakening TLS checks or
editing privacy databases. It passed full public HTTPS acceptance: both A1 and
P1S ONLINE with fresh telemetry, authenticated view/WSS updates, camera toggles,
two JPEG frames per printer, shared upstreams, final-viewer cleanup, maintenance
controls and logout revocation. The initial process was PID 3354.

- Active release: `releases/b415870-writer-lifetime-v2-20261020/`.
- Source: historical `b4158705155c9fc901d9b2bd3e07e968636d99cc` plus the exact
  three-file runtime/Live patch; the fix is committed as `c36aa5b` on main.
- Active signed SHA-256: `04eb35dfa6033ec28fd7258031cc375ad871332bb72f383ce094fda439550070`.
- Previous accepted app: `rollback/writer-lifetime-20261020T031906Z/PrinterHost.app`.
- Pre-approval deployment, rollback and provenance records were copied into a
  timestamped `attempt-before-permission-retry-*` directory before installation.
- Evidence: `public-after-permission-approval.json` in the local ignored incident
  directory and alongside the release on the mini.
- Maintenance hash remains `5b7be6d7369c1141daf4e9d27028ab5699f9c2d49055520bb8d3ac7a3750b2f3`:
  ten tasks, revision zero, zero history entries.

The watchdog was also kicked in its actual `gui/501` launchd context and observed
healthy HTTP, zero failures and no watchdog restart. Its login-session limitation
still applies. No printer control/print operation was sent by these checks.

This controlled retry strongly supports macOS permission as the prior deployment
blocker: the artifact, device config and runtime credentials were unchanged,
and the owner approved prompts before the successful retry. This is separate
from the original sustained HTTP outage; the long-duration causality caveat
above still applies.

The app is still ad-hoc signed. Apple's [local network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
recommends an Apple-issued signing identity so macOS can reliably track the
program across builds. For future releases, keep the canonical bundle ID/path,
use a stable Apple-issued signing identity when available, and require real
printer acceptance in the launchd context. Approval of this binary does not
prove approval of every future rebuild. We did not grant unrelated privacy
permissions or disable macOS protections; the exercised service paths establish
that their required permissions are available.


A deliberate normal launchd restart then replaced PID 3354 with PID **3460**,
using the identical signed executable. Full public acceptance passed again,
including both cameras, sharing/cleanup and logout; both MQTT sockets were
established, and no new connect-denial entries appeared after that restart.
Evidence: `permission-restart.json` and `public-permission-restart.json` in the
release directory. This confirms permission survives a process restart; a
whole-machine reboot, future rebuild and long-duration soak remain untested.
