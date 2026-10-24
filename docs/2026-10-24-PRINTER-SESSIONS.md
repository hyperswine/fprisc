# Printer dashboard: 30-day persistent sessions

Deployed 2026-10-24, Australia/Sydney, to https://3dprint.cswine.cloud.

Previously the native host issued an eight-hour cookie and kept its hashed
session records only in memory. Every app restart forced another key login.
The printer-specific service now issues a 30-day persistent cookie and restores
valid sessions after restart. The generic `std/sessionauth` eight-hour default
is unchanged for other consumers.

## Contract

- Ed25519 challenge signing stays in the browser. No private login key is stored
  by the browser application or sent to the server. A 60-second challenge remains
  one-use, origin-bound and browser-bound; unfinished challenges do not survive
  restart.
- The random session cookie has `Max-Age=2592000`, `HttpOnly`, `SameSite=Strict`,
  and `Secure` over the public HTTPS origin. Expiry is fixed at 30 days from
  login. Restarting or reading the dashboard does not extend it indefinitely.
- A bounded server snapshot contains only SHA-256 token digests, origins and
  absolute expiry timestamps, plus a fingerprint of the public-key set. It
  contains no bearer cookies or private keys. Runtime checks retain monotonic
  deadlines; restoration converts the remaining wall-clock lifetime rather
  than issuing another month.
- Sign-out is acknowledged only after the revocation is persisted. Existing
  WebSocket and camera streams still recheck session validity. Persistence
  failures refuse authorization; a successful session/challenge/logout checkpoint can
  recover after storage is repaired. Corrupt/oversized/incomplete snapshots
  refuse startup and are preserved for inspection. Atomic replacement is not
  an fsync/power-loss guarantee, and auth snapshots have no rollback backup.
- Changing the authorized public-key set and restarting revokes every saved
  session. Renaming keys does not change that set. Clearing browser cookies
  or signing out requires a fresh key login.

`examples/printer-dashboard/authservice.fpr` owns persistence. The host accepts
`--session-store`; its default is `<store>.sessions.json`. On the mini this is
`/Users/jq/printer-host/data/native-view.kvlog.sessions.json`, outside the app
bundle, mode 0600 in a 0700 directory under the existing umask 077 LaunchDaemon.
The gateway now checks the explicit successful logout reply before clearing the
browser cookie; an RPC reply reporting failed persistence is not a successful
sign-out.

Old eight-hour in-memory sessions could not be migrated, so users need one final
login after this first deployment. Subsequent app restarts preserve valid logins.

## Validation

- `tests/sessionauthstore_policy.fpr`: exact 30-day/expiry boundaries, bounded
  restoration, origin binding, allowlist changes and invalid stores.
- `tests/check_printer_sessions.py`: synthetic one/four-hart native servers;
  cookie flags/lifetime, digest-only 0600 storage, restart, consumed challenges,
  durable logout, disk-write failure/refusal/recovery, revoked/expired sessions,
  malformed snapshot refusal.
- `tests/check_native_gateway.py`: demo and simulated TLS printer/camera peers
  on one/four harts; challenge/crypto, live fault updates, logout and stream
  revocation.
- `tests/check_printer_care.py`: one/four-hart maintenance persistence, restart,
  conflict handling and failed writes. Its view/session paths are now isolated
  within each test directory.
- Production HTTPS: verified the 30-day cookie, retained the same test cookie
  through a real dashboard restart, then confirmed logout revocation. The P1S
  globe remained RUNNING at layer 98/659 across this check; no printer control
  command was sent.
- Public P1S acceptance: authenticated telemetry, WSS cards/camera toggles,
  shared camera delivery, maintenance revision 2 with both issue entries,
  viewer cleanup, and logout closing WSS/camera streams all passed.

The older source-boundary guard `check_pure_applications.py` still fails at
line 53 because it expects legacy CSS text absent from `std/view.fpr` at HEAD.
That file is unchanged by this work. This is recorded as a pre-existing guard
failure, not a passing full suite.

## Deployment evidence

- The deployed artifact was built from baseline source HEAD `a6043da` plus the
  targeted auth changes. The saved patch and source hashes identify that build;
  unrelated working-tree edits are excluded from it.
- Release: `/Users/jq/printer-host/releases/a6043da-sessions30d-20261024`.
- Signed running executable SHA-256:
  `a5e9fb03869a22b86b34f894e3501efe49ce1a12c059bb387742993b0d443485`.
- Final verified PID: 56870, running as jq through the existing approved
  `cloud.cswine.printer-host` app identity.
- Prior app preserved at
  `/Users/jq/printer-host/rollback/sessions30d-20261024T103919Z/PrinterHost.app`.
- Maintenance snapshot unchanged across deployment:
  `4e35ad685e7e3aabc672749c5d92f1c6f399c5035c6522ff66a96dc7dd0a33df`.
- Local evidence: ignored `build/printer-sessions-20261024/`, including the
  source patch/hashes, deployment record, live session restart check and public
  acceptance. No credentials, cookie values or login signatures are recorded.

## 2026-10-25: mobile readings and reported early logout

The live mini still ran the expected signed 30-day build (PID 56870 and the
SHA-256 recorded above). Its three persisted sessions had approximately
29-30 days remaining. This confirms the update was active; it does not identify
which session belonged to the reporting mobile browser or establish why that
browser showed login again. No historical auth-event evidence established that
specific cause.

The gateway did have a separate false-expiry path: `Auth.authorized` flattened
RPC timeout/refusal into `False`, causing an HTTP 401 and a browser redirect to
key login. It now sends 401 only for an explicit negative session result and
503 for unavailable authentication. The cookie remains intact. After a failed
store write, ordinary checks may checkpoint and recover automatically; pending
revocations must be saved before access resumes. No private key is persisted.

The cards now round temperatures and targets to whole degrees and report/camera
rates to one decimal. The formatting uses bounded decimal arithmetic; raw API
telemetry is unchanged. Narrow-screen metric text is smaller and confined to
its grid column.

Validation passed: generated Chromium view at widths 320/375/390/1200, decimal
rounding cases, generated session checker retaining the page on offline/503
and redirecting on 401, synthetic native sessions and maintenance on one/four
harts, existing gateway demo/TLS-peer tests, and policy checks beyond the old
eight-hour cutoff. Production checks verified the same login before and after
deployment, preserved existing sessions/expiries and maintenance data, and
confirmed persistent secure cookies and fitting metric columns at 320/375/390.
These checks do not constitute a 30-day physical soak or reproduce the owner's
specific mobile logout. No printer-control commands were sent.

Release: `/Users/jq/printer-host/releases/ff96204-mobile-sessions-20261025`.
Signed executable SHA-256:
`89c239486c15c5590c072128865756150a5bb048e5f71b9e264da64de54e0e64`.
Rollback: `/Users/jq/printer-host/rollback/mobile-sessions-20261024T183014Z`.
Local evidence: ignored `build/printer-mobile-20261025/`.
