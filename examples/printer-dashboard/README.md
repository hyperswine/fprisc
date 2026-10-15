# Native printer dashboard

The current application is `examples/printer-host.fpr`: one FP-RISC process
owns configuration, Ed25519 authentication, the public HTTP gateway, Live UI,
MQTT/TLS telemetry and shared camera/TLS services. It launches no Python, curl
or helper programs. TLS and signature operations use linked OpenSSL 3 adapters;
application policy, limits and lifetime remain FP-RISC.

Build from the repository root (adjust the OpenSSL prefix for your host):

```sh
./fpr build examples/printer-host.fpr -o build/printer-host \
  --with machine/unix/tls_openssl.c --with machine/unix/crypto_openssl.c \
  --cflag -I/opt/homebrew/opt/openssl@3/include \
  --link -L/opt/homebrew/opt/openssl@3/lib --link -lssl --link -lcrypto
```

Run directly, using public printer configuration and a public key allowlist:

```sh
./build/printer-host --config=build/printer-native-runtime/printers.json \
  --credentials-env-file=../3d-models/.env \
  --auth=examples/printer-dashboard/auth.json --port=6730 \
  --origin=https://3dprint.cswine.cloud
```

Access codes are read at runtime from the configured environment bindings or
selected literal assignments in the credential file. They never belong in
arguments, public JSON, the UI model or logs. The file parser does not execute
shell syntax. Configure explicit `tls_peer` and `tls_ca`, plus optional
`camera_tls_peer`, `camera_tls_ca`, `mqtt_port` and `camera_port` overrides.
Set `camera` to `bambu-jpeg` for supported A1/P1S cameras or `none` otherwise.
Discovery and RTSPS are not implemented by this host; use recorded public
addresses and certificate identities. `--demo` also requires an allowlist and
uses no printer connection.

Login HTML, its script, session behavior, media lifecycle and shared Live client
are generated from FP-RISC. The checked-in files under `tools/printer_login.*`
and `tools/printer_session.js` are compatibility exports, regenerated with:

```sh
./build/printer-host --export-assets=tools
```

The native host serves its definitions directly and never reads these exports.
The former Python gateway and auth implementation now live under `tests/legacy`
solely for compatibility tests. Python test simulators are not runtime services.

Acceptance: `tests/check_native_gateway.py --binary=build/printer-host` covers
same-origin/auth/replay/revocation and isolated MQTT/TLS + camera/TLS peers on
one/four harts with no tools on PATH. `tests/check_native_login.cjs` drives the
actual generated login/session UI in Chromium. Shared browser/UI suites cover
the interactions and local styling. The native host was subsequently deployed
and checked against both real printers through public HTTPS/WSS; see the
[production acceptance record](#single-process-native-host-deployed-2026-10-15).
Simulator checks alone do not establish that deployment boundary.

## Maintenance, issues and print outcomes

The native host includes a shared **Care & print log**. Open it from a printer
card, then select Maintenance, Issues, Print watchlist or History. All registered
login keys may record workshop observations; this does not enable printer
motion, temperature changes or starting prints. These records are human reports,
not telemetry-derived claims of maintenance or print quality.

The maintenance log is stored separately from the executable, so redeployments
can preserve its schedules, observations and history.

- Maintenance schedules accept 1–3650 whole days. Log completed work with a
  note, change its cadence, or postpone its reminder by one day. Postponing
  never marks work completed. New schedules have no assumed past completion;
  their first reminder is one interval after creation.
- Issues cover noise/squeaking, artifacts, adhesion, feeding/extrusion and other
  observations. Attach a file/part label and settings, add follow-up notes, then
  resolve or reopen with an explanation. Record suspected causes as hypotheses.
- Print results record a file/object/part label, settings, observations and a
  Failed, Poor quality or Passed result. The active watchlist shows the latest
  unsuccessful result for each exact **printer + file label + settings**.
  A subsequent Passed result for that same combination clears it while keeping
  all attempts. Changing settings starts a separate combination. Names are
  labels rather than content identities; a changed file should use a new label
  or revision. Passing requires the operator's physical inspection.

Model presets were checked against Bambu's [A1 maintenance guide](https://wiki.bambulab.com/en/a1/maintenance/basic-maintenance)
and [P1 series guide](https://wiki.bambulab.com/en/p1/maintenance/p1p-maintenance)
on 2026-10-15. A1 X/Y rails use oil; P1S X carbon rods are cleaned without
lubrication. Both models include Z lead-screw grease checks. The P1S also has
Y/Z steel-rod cleaning and rust-protection checks; both have weekly fan checks
and an adjustable workshop reminder for the plate. Monthly/quarterly schedules
use 30/90 days. Plate cleaning is condition-dependent, so the weekly reminder
does not replace inspection before a print. Follow the linked guide and HMS
prompts for the actual procedure, and perform hands-on work when safely idle.
Usage, abrasive materials, filament dust and humidity may justify shorter
intervals. The display label `A1 + AMS Lite` uses the A1 presets.

Due items appear above the cards. **Browser reminders** explicitly requests
notification permission and toggles that browser's preference; no permission is
requested on page load. Alerts are deduplicated per due occurrence, including
after a snooze, and fall back to the visible due list if notifications or local
storage are unavailable. Delivery is best effort while a signed-in app tab is
open and connected. There is no service worker, push subscription or closed-app
delivery in this version.

### Storage and recovery

`--maintenance-store=PATH` selects a persistent JSON snapshot. By default it is
`<--store value>.care.json`, separate from the Live view store and telemetry.
Put it in a stable local directory, retain it across binary upgrades, and include
it in backups. The default-named files are ignored by Git; custom paths should
be inside an ignored/private data directory too. Demo and acceptance runs must
use their own path. Run only one host against each path: this is a single-process
store, without a cross-process lock or database replication.

One actor validates and serializes mutations. A view supplies the current log
revision, so stale tabs and retries cannot overwrite a more recent edit. The
actor checks the on-disk revision too. A successful save writes a temporary
snapshot, preserves the previous complete snapshot as `PATH.bak`, and renames
the new snapshot over `PATH`. Save acknowledgement follows replacement, and a
failed save keeps the in-memory log and draft. A later acknowledgement clears a
note only if it still matches the submitted note, preserving newly typed work.
Temporary files are never replayed automatically. Atomic replacement protects
against an interrupted process; the file API does not offer fsync, so this is
**not a power-loss durability guarantee**.

A damaged/unsupported log or a missing primary with an existing backup disables
logging and displays the reason. It never silently resets history or rolls back
to the backup. Printer telemetry and cameras can continue. Stop the host, retain
the damaged primary and all recovery files, inspect/validate a copy of the
backup, then deliberately restore that copy to `PATH` and restart. A transient
write error can be repaired and retried without restarting; review History if a
save was not confirmed. Old source-built binaries ignore the new log, so retain
the data file when rolling back the executable.

The store bounds tasks (256), issues (512), print attempts (1024), history events
(4096), file size (8 MiB), note size and JSON nesting. It refuses new entries at
capacity rather than deleting old observations. The UI shows the latest 20
issues, attempts, watched files and history entries; **Export log** downloads the
authenticated `/api/status` JSON, which includes the complete `maintenance`
object and a `maintenance_problem` field. Consumers must inspect that field.
Export and retain a checked archive before rotating a full log while the host is
stopped; keep both the primary and backup together. Auth sessions are not stored
with the log. Entries have event IDs and timestamps, but no claimed key-holder
identity: the existing session service does not expose an authenticated name.

The next useful integrations are content hashes/build-manifest IDs from CoScad,
structured material/nozzle/profile fields, print-hour/spool-count schedules,
photo/audio evidence, and closed-app notifications. The present watchlist is
advisory; it does not automatically block slicing, upload, or a printer job.

### Maintenance acceptance

```sh
XDG_CACHE_HOME=/tmp/printer-care-cache ./fpr build tests/printer_care.fpr -o build/printer-care-policy
./build/printer-care-policy
XDG_CACHE_HOME=/tmp/printer-care-cache ./fpr build tests/printercare_program.fpr -o build/printercare-program
node tests/check_printer_care_program.cjs build/printercare-program
python tests/check_printer_care.py --binary build/printer-host
```

The Python check needs the existing dashboard test environment's `cryptography`
dependency and creates only disposable synthetic keys/data. It covers two tabs,
stale revisions, bad inputs, successful/failed results, snooze/completion,
restart recovery, failed writes and corruption on one/four harts. The generated
browser-program check covers JSON form packing (including pipes and Unicode),
late-save draft preservation, disconnected saves, double clicks, notification
deduplication, permission revocation and unsupported browsers. The browser UI
was also exercised against a separate native demo, including a 390px phone view.
These checks do not establish public deployment, OS notification delivery on a
specific phone, or that any physical maintenance or print actually succeeded.

Additional migration checks:

```sh
python3 tests/check_pure_applications.py --binary=build/printer-host
./fpr build tests/browser_feedback.fpr -o build/browser-feedback
node tests/check_browser_feedback.cjs ./build/browser-feedback
./fpr build tests/sessionauth_policy.fpr -o build/sessionauth-policy
./build/sessionauth-policy
./fpr build tests/sessionauth_native.fpr -o build/sessionauth-native \
  --with machine/unix/crypto_openssl.c \
  --cflag -I/opt/homebrew/opt/openssl@3/include \
  --link -L/opt/homebrew/opt/openssl@3/lib --link -lcrypto
./build/sessionauth-native
```

Browser drivers require Playwright/Chromium; gateway simulators use Python's
`cryptography` package for synthetic test identities. These are test dependencies.

## Historical implementation and deployment records

The sections below describe earlier stages, including the retired Python
launcher. Their commands are historical; use the native entry point above.


A small read-only LAN printer dashboard. The application is
[../printers.fpr](../printers.fpr): a shared FP-RISC `std/live` model, typed
messages, per-browser expanded cards and camera switches, `std/view` trees,
and incremental WebSocket updates. It follows `pos1.fpr` and `inventory.fpr`.
The default Python transport handles Bambu MQTT/TLS and framed-JPEG cameras.
An opt-in FP-RISC collector now handles authenticated native TLS/MQTT and
telemetry projection. A separate opt-in native camera service handles framing,
sharing and MJPEG streaming; Python still serves login and gateway supervision.
JavaScript manages browser media lifecycle and local challenge signing; it does
not fetch/render printer status or own the dashboard model.

From the repository root:

```sh
./fpr build examples/printers.fpr -o build/printers
python3 -m venv /tmp/printer-dashboard-venv
/tmp/printer-dashboard-venv/bin/pip install -r tools/printer-dashboard-requirements.txt
/tmp/printer-dashboard-venv/bin/python tools/printer_dashboard.py --demo
```

Open [Print room](http://127.0.0.1:6730/) and sign in with an authorized key.
Demo mode requires the signature-verification dependency and an authorized
login key, but no physical printers. Both the telemetry and camera are explicitly
simulated; `demo-camera.jpg` is a generated illustration, not a printer photo.

## Public-key login

The public Ed25519 allowlist is `auth.json` beside this file (override with
`--auth=PATH`). The Mac and phone keys are registered there. The bridge reads
that single allowlist at startup and includes only its public entries in the
FP-RISC `Model.auth` field. Authentication is enforced by the gateway before
HTML, live WebSocket, status API or camera access; hiding a card is not an
authorization boundary. A missing or invalid allowlist prevents startup.

On the Mac, the generated private key is stored with mode 0600 at
`~/.config/fprisc/printer-dashboard/mac-ed25519.pem`. Copy it privately and
paste it into the login screen. Accepted formats are PKCS#8 PEM, a 32-byte
hex Ed25519 seed, or a 64-byte seed concatenated with its public key. This
last format is not a 64-byte expanded scalar key. Neither SSH-format nor
encrypted PEM keys are accepted. The browser imports a non-exportable signing
key, clears the input and sends only a challenge ID and signature. No key is
sent to the server, put in a URL, added to the live model, or saved in browser
storage. JavaScript memory is garbage-collected, so clearing a field is not
a guarantee of immediate memory erasure.

Challenges expire after 60 seconds, are one-use even on failure, and bind to
the origin and an HttpOnly browser cookie. There is a bounded challenge rate
and bounded in-memory state. Verified logins receive an eight-hour HttpOnly,
SameSite=Strict cookie (Secure on HTTPS). Sign out revokes that session;
already-open WebSockets and camera feeds check revocation while streaming.
Other tabs redirect to login on their next session check (up to 15 seconds).
Restarting the bridge expires all sessions. Change the public allowlist and
restart to add or revoke devices.

WebCrypto signing needs a current browser supporting Ed25519 and HTTPS, or
localhost. For the public proxy launch with
`--origin=https://3dprint.cswine.cloud`; the configured origin is used to
reject foreign Host/Origin headers and issue secure cookies. The existing
nginx IP restriction has been removed, so authorized devices can sign in
from any network. No third-party scripts load on the login page.

## Local printers

```sh
python3 -m venv /tmp/printer-dashboard-venv
/tmp/printer-dashboard-venv/bin/pip install -r tools/printer-dashboard-requirements.txt
cp examples/printer-dashboard/printers.example.json /tmp/my-printers.json
# Edit host, serial, name, location and model for each printer.
# Provide the named access-code variables in the process environment through
# your existing local secret mechanism. Do not put their values in this JSON.
/tmp/printer-dashboard-venv/bin/python tools/printer_dashboard.py --config=/tmp/my-printers.json
```

For the existing `3d-models/.env` layout, no separate JSON file is needed:

```sh
/tmp/printer-dashboard-venv/bin/python tools/printer_dashboard.py \
  --env-file=../3d-models/.env --printers=a1,p1s
```

The loader reads only `BAMBU_A1_HOST`, `BAMBU_A1_ACCESS_CODE`,
`BAMBU_P1S_HOST`, `BAMBU_P1S_ACCESS_CODE`, and optional matching `_SERIAL`
fields. It parses assignments without executing shell code, keeps access
codes only in the bridge's runtime environment, and strips them from the
FP-RISC child's environment. Missing serial IDs are discovered from LAN
advertisements from the configured hosts. Nothing is written back to `.env`.
`--printers=a1` skips the P1S completely; use `--printers=a1,p1s` when both
are powered on, or `--printers=p1s` for that printer alone. Discovery waits
up to 20 seconds; optional `BAMBU_A1_SERIAL` / `BAMBU_P1S_SERIAL` values
avoid waiting for advertisements on subsequent starts.

A1/P1-series MQTT status and port-6000 cameras use the same LAN protocol as
`../3d-models/bambu-lan/`. X1 RTSPS is not supported; set `camera` to `none`
for unsupported cameras. The A1 has been checked against the physical printer
(see validation below).
The P1S has also been verified against the physical printer and is now
enabled alongside the A1 (see the P1S validation below).
The bridge strips transport credential variables from the FP-RISC child’s
environment; no actual access code is needed by that process or the browser.
The public snapshot is an allowlist, not a copy of raw MQTT reports.

The default listener is loopback only. Use an HTTPS proxy and explicit
`--origin` for access from other devices. Printer TLS uses
self-signed certificates, with the same LAN-only trust assumption as the
existing scripts. No cloud or AWS services are involved.

## What the cards show

- State, job, progress, layers and estimated time remaining.
- Nozzle/bed temperatures and targets, Wi-Fi, filament and print error.
- Latest report age, MQTT connection state and measured report Hz (rolling
  30-second window; warms up during the first 30 seconds and decays to zero
  when messages stop).
- Camera stream state, measured frame Hz and last-frame age, so a stalled
  camera is not presented as a fresh image.
- Dashboard refresh target and actual interval, separately from printer Hz.
  `--poll-ms=1000` is the default (accepted range 250..10000).
- Expand a card for details. Switch its camera on for a same-origin MJPEG
  feed. The camera does not connect on page load. It suspends while the card
  is collapsed, the tab is hidden, or the dashboard is disconnected. Turning
  off/closing the final viewer closes that printer's camera socket. Multiple
  viewers share one upstream stream (max 8 per printer).

A printer is stale after 15 seconds without telemetry; a bridge snapshot is
stale after 5 seconds. Last-known data stays visible with a stale/offline label.
The dashboard never equates acceptance, PREPARE or RUNNING with a completed
physical print. Camera cadence is whatever the printer supplies; it is not
advertised as 30 fps. An unavailable camera says so and can be retried by
switching it off and on.

Only one status request (`pushall`) is published per MQTT subscription, including
reconnections. There are no pause/start/stop, temperature, G-code, upload or
slicing endpoints. Ordinary HTTP mutation methods are rejected; WebSocket
messages only change per-tab presentation state. Unknown printer IDs are ignored.

## Check

```sh
./fpr build examples/printers.fpr -o build/printers
/tmp/printer-dashboard-venv/bin/python tests/check_printer_dashboard.py
```

Checks delta merging, stale/offline states, missing AMS data, invalid numbers,
public field filtering, camera sharing and teardown, invalid configuration,
read-only HTTP routes, same-origin checks, real FP-RISC 1/4-hart sessions,
per-tab isolation, malformed/missing snapshot recovery, text escaping,
reconnection defaults, and the complete HTML/WebSocket gateway. Login checks
cover unauthenticated routes, browser WebCrypto signing in all three key
formats, unknown keys, consumed/expired challenges, origin/browser binding,
expiry, rate limits, logout, and closure of an established WebSocket. These
tests generate disposable keys and never read the real Mac private key.

No daemon is installed and nothing is published. Stopping the launcher stops
the private FP-RISC listener, MQTT connections, camera streams and temporary
snapshots. A print or motion test is outside this read-only dashboard’s scope.

## Preview and validation (2026-10-14)

![Dashboard demo with an expanded camera card](preview.jpg)

The example builds with the current compiler. Nine transport checks and the
real FP-RISC wire checks (one and four harts) pass. The desktop (1200 px) and
phone (390 px) layouts were inspected in a browser without horizontal overflow.
An enabled demo stream stayed at one upstream connection across progress
changes and expansion of the other card; collapsing the camera card removed
its image request. No physical printers were accessed during these checks.

## Physical A1 validation (2026-10-14)

The dashboard was switched from demo mode to the real A1 using the existing
`3d-models/.env`, with `--printers=a1`. The P1S was powered off and explicitly
skipped during this initial A1 check. The subsequent P1S check is below.

- 45.1-second observation: 15 additional MQTT reports, all 16 sampled states
  ONLINE; real nozzle, bed and Wi-Fi values changed in the browser.
- Camera: real 1536-pixel-wide JPEG images, roughly 0.43 frames/second at the
  printer's native cadence, with one uninterrupted upstream connection.
- A concurrent second viewer received two valid JPEGs (142269 / 142555 bytes)
  without opening another connection to the printer.
- Switching the camera off reached zero viewers and OFF; enabling it again
  successfully reopened the feed.
- Neither the HTTP page nor the public status JSON contained either access
  code. Only runtime environment values were loaded; `.env` was not modified.
- Nine transport checks plus the one-/four-hart FP-RISC wire and gateway
  checks pass after the `.env` loader and printer-selection changes.

The printer reported FINISH for a previous job. This is observed telemetry,
not a new print or a physical quality verdict. No print, motion, temperature,
light or upload commands were sent. The only printer request was the initial
MQTT status snapshot. Sanitized measurement evidence is kept locally under
`build/printer-dashboard-live-check.json` (ignored by Git).

## HTTPS endpoint

The Linode now proxies [3dprint.cswine.cloud](https://3dprint.cswine.cloud/)
over Tailscale to this app. The login endpoint is available from any network;
printer data, WebSockets and cameras require public-key authentication. See
[proxy configuration and operational notes](../../deploy/printer-dashboard/README.md).
The host Mac must remain awake and running the dashboard.

## Authentication verified (2026-10-14)

Ten transport/auth checks, the one-/four-hart FP-RISC checks, and the complete
gateway checks pass. The exact client signing code was exercised with Node
WebCrypto using disposable PEM, seed and seed+public test keys. An actual
browser showed the live HTTPS login page and cleared invalid input without
submission. The real Mac key successfully signed into the HTTPS endpoint;
the verified session received fresh A1 reports, two camera JPEG frames and
a WebSocket 101 upgrade. Signing out closed that established WebSocket and
returned the status route to 401. Anonymous status, WebSocket and camera
requests all received 401. The phone public key is registered, but a login
using the phone's matching private key has not been performed.

Sanitized evidence: `build/printer-dashboard-auth-check.json` and
`build/printer-dashboard-login.jpg` (ignored by Git). The running bridge uses
`--env-file=../3d-models/.env --printers=a1,p1s --port=6730
--origin=https://3dprint.cswine.cloud`.

The nginx IP restriction was subsequently removed by user request. A source
previously receiving 403 now receives the login page and challenge endpoint
(200), while anonymous status, WebSocket and camera requests receive 401.
nginx configuration validation passed before reloading; its previous access
snippet is backed up under `/root/nginx-backups/` on the Linode.

## Physical P1S and two-printer validation (2026-10-14)

LAN discovery found the P1S at a different address from its saved `.env`
HOST. Read-only MQTT and two valid camera JPEGs were verified before
correcting only `BAMBU_P1S_HOST` and adding its discovered `_SERIAL` in the
existing local configuration. Access-code values were preserved without
being printed or put into a backup. The live launcher now selects
`--printers=a1,p1s` with the existing HTTPS origin and public-key allowlist.

Authenticated HTTPS validation showed both printer cards in the actual
FP-RISC WebSocket view and fresh reports from both printers over an
eight-second observation. The P1S camera switch updated its own live card;
its HTTPS feed supplied two valid JPEGs (63204 and 64717 bytes). At that
observation the P1S reported RUNNING, 41%, layer 51/126, 88 minutes remaining,
with no reported error. This describes telemetry, not a completed physical
print. Anonymous status and P1S camera requests still received 401. Restarting
the bridge expired earlier sessions, so existing users need to sign in again.
Sanitized evidence is in `build/printer-dashboard-two-printers-check.json`
(ignored by Git).


## Native telemetry (opt-in)

Build the collector with the optional OpenSSL 3 engine, and build the view:

```sh
./fpr build examples/printer-telemetry.fpr -o build/printer-telemetry \
  --with machine/unix/tls_openssl.c \
  --cflag -I/opt/homebrew/opt/openssl@3/include \
  --link -L/opt/homebrew/opt/openssl@3/lib --link -lssl --link -lcrypto
./fpr build examples/printers.fpr -o build/printers
```

Use a public configuration like `printers.example.json`, adding `tls_ca` (an
absolute path to a trusted CA PEM) and `tls_peer` (the certificate's verified
DNS/IP identity) to each printer. `mqtt_port` is optional, default 8883. The
host/serial and access-code environment-variable name still belong in that
configuration; the access-code value does not. Use `--config` for this mode;
the existing `.env` discovery launcher does not yet carry trust metadata.
Certificates must chain to the configured CA and satisfy identity/validity
checks. There is no insecure fallback. Establish the real printer's trust
material before selecting this mode; simulator acceptance does not establish
A1/P1S certificate compatibility.

With each code already supplied privately in the caller's runtime environment:

```sh
/path/to/dashboard-venv/bin/python tools/printer_dashboard.py \
  --config=/absolute/path/printers.json \
  --native-telemetry="$PWD/build/printer-telemetry"
```

Native mode needs `cryptography` for existing gateway login, but does not load
Paho. One native process owns each printer's DNS/TCP/TLS/MQTT, report merging,
projection, keepalive and reconnect. Only its selected code is passed to it,
through `FPR_PRINTER_CODE`, with no code in arguments, public output or the UI
process environment. The only publication is the existing read-only `pushall`
status request after subscribing, repeated after reconnect. Python remains for
supervision, HTTP/WebSocket/login, cameras and snapshot aggregation. This is
an opt-in migration; the live deployment is unchanged.

Verify without a printer or real credentials:

```sh
/path/to/dashboard-venv/bin/python tests/check_printer_native.py \
  --binary=build/printer-telemetry
python3 tests/check_native_services.py --broker \
  --openssl-prefix=/opt/homebrew/opt/openssl@3
```

The first check uses an isolated TLS printer simulator and the actual gateway
handoff on one/four harts. It covers authenticated subscription/status requests,
fragmented/coalesced delta reports, reconnect/resubscribe, private-field
exclusion, bad-password refusal and verified-peer rejection. The second also
uses pinned Mosquitto for authenticated QoS 1 and keepalive. Real printer trust,
telemetry and camera acceptance were subsequently verified on both devices;
see the production native deployment record below.


## Native camera (opt-in)

Build the verified native camera service with the same OpenSSL 3 flags as the
telemetry collector:

```sh
./fpr build examples/printer-camera.fpr -o build/printer-camera \
  --with machine/unix/tls_openssl.c \
  --cflag -I/opt/homebrew/opt/openssl@3/include \
  --link -L/opt/homebrew/opt/openssl@3/lib --link -lssl --link -lcrypto
```

Add `--native-camera="$PWD/build/printer-camera"` to the `--config` gateway
launcher above. It can be selected independently of `--native-telemetry`.
Every printer requires explicit verified `tls_ca`/`tls_peer`. If camera and MQTT
certificates differ, add `camera_tls_ca` and `camera_tls_peer` overrides.
`camera_port` is optional, default 6000. Access-code values stay in the named
runtime environment variable. The camera protocol accepts at most 32 bytes;
it refuses empty, longer or embedded-NUL values. Native mode does not disable
TLS verification. Configure the actual device's trust before using this mode.

The first authenticated camera request starts a private local native service;
its first viewer starts one upstream TLS connection. FP-RISC owns camera login,
bounded JPEG records, one latest-frame cache, up to eight shared viewers,
MJPEG framing and per-viewer write deadlines. Final-viewer cleanup drops the
frame and closes upstream I/O, even during a stalled frame read. A retired
source cannot publish into the next viewing generation. The idle local service
remains available for later requests and stops with the gateway. Python retains
public login/session checks and process supervision, and relays the native HTTP
body without interpreting camera/JPEG/multipart framing. Logout and session
expiry continue to close active streams; browser hide/collapse behavior is
unchanged.

Test without a real camera or private code:

```sh
/path/to/dashboard-venv/bin/python tests/check_native_camera.py \
  --binary=build/printer-camera
```

The TLS simulator covers fragmented/consecutive frames, the exact 80-byte login,
shared viewers and capacity, final-viewer cleanup, new generations, malformed,
truncated, oversized and stalled records, identity rejection and slow clients.
It also exercises native multipart streaming through the authenticated gateway
and verifies that logout releases the upstream connection. Real-device
acceptance is recorded separately below.


## Production native deployment (2026-10-15)

The dashboard now runs native telemetry and cameras for both A1 and P1S. The
public origin and Ed25519 allowlist are unchanged. The native TLS peer identity
is each printer's recorded serial (its certificate CN); both MQTT and camera
certificates validate against the public printer CA bundle from the installed
Bambu Studio app, including identity and validity checks. The copied bundle's
SHA-256 is `36f2bcee347ec7adce719b5fd350099591a4d3d0ec4e039c7019890d78e152a0`.
No peer certificate was silently trusted in place of a verified CA chain.

The public deployment configuration is ignored by Git at
`build/printer-native-runtime/printers.json`. Its `tls_ca` points to the copied
vendor bundle in the same directory. Access codes remain in the existing
`../3d-models/.env` file. The new `--credentials-env-file=PATH` option, used with
`--config`, loads only the selected A1/P1S `*_ACCESS_CODE` bindings through the
existing non-executable parser. It does not copy hosts/serials or arbitrary
variables into the child environment. Code values never belong in that JSON,
command-line arguments, logs or Git.

From the repository root, with the binaries built as above:

```sh
/private/tmp/printer-dashboard-venv/bin/python -u tools/printer_dashboard.py \
  --config="$PWD/build/printer-native-runtime/printers.json" \
  --credentials-env-file="$PWD/../3d-models/.env" \
  --native-telemetry="$PWD/build/printer-telemetry" \
  --native-camera="$PWD/build/printer-camera" \
  --binary="$PWD/build/printers" --port=6730 \
  --origin=https://3dprint.cswine.cloud
```

The current background process PID and output are in
`build/printer-native-runtime/gateway.pid` and `gateway.log`. Previous binaries
were retained as `build/*.previous`. No boot service was installed and no
reverse-proxy configuration changed. A restart expires existing browser
sessions, so sign in again afterward.

Authenticated HTTPS checks observed fresh native telemetry from both printers,
two consecutive valid JPEGs from each native camera, and `OFF`/zero viewers on
both cameras after the requests closed. Anonymous status remained 401 and
logout revoked the validation session. Sanitized evidence is in the ignored
`build/printer-native-runtime/deployment-check.json`. This proves the real
read-only transport/camera path at deployment time; it is not a long-duration
soak or a physical-print verdict.

## Typed presentation and generated media (2026-10-15)

The printer view uses local typed declarations in `presentation.fpr`, including
responsive layout, focus, document-body attributes and explicit progress/switch
content. Its camera lifecycle is generated by `std/browsermedia` through a typed
JavaScript syntax backend with no Raw node. Shadow-DOM image styling is generated
from the FP-RISC view tree; no embedded camera script or stylesheet remains in
`examples/printers.fpr`. Shared Live client code and the Python public gateway
still require migration; see the [completion contract](../../docs/2026-10-15-PURE-APPLICATIONS.md).

`tests/check_printer_styles.cjs` runs real Chromium layout, focus, syntax safety
and media lifecycle checks on one/four harts. `tests/check_http_native.py` checks
the native HTTP/TLS client against isolated loopback simulators. These changes
have not been deployed by this implementation step.

## Single-process native host deployed (2026-10-15)

The initial single-process deployment ran `build/printer-host`, built from application commit
`9782b38420bb24c5b61d095adecfaea93abd3be2`. The previous Python gateway and its
native helper processes exited. One FP-RISC process owns the public gateway,
authentication, register, view, telemetry and cameras; it runs with four harts
and `PATH=/nonexistent`, with no child processes. nginx, Tailscale, the public
allowlist, printer configuration and CA trust were preserved.

The runtime command uses the current native entry point above, adding
`--store=build/printer-native-runtime/native-view.kvlog`. Runtime access codes
remain in the existing selected credential file. The PID, log, deployed source
commit, previous deployment backups and sanitized acceptance evidence remain
under ignored `build/printer-native-runtime/`. No boot service was installed.
Restarting expired existing sessions; sign in again to use the new host.

Fresh acceptance through `https://3dprint.cswine.cloud` established:

- Verified public HTTPS, signature login and Secure/HttpOnly/SameSite cookies;
  anonymous status, WSS, session script and both camera routes return 401.
- Both real A1 and P1S report ONLINE with fresh native telemetry. Public WSS
  upgrades, snapshots, subsequent updates and camera controls work.
- Two consecutive JPEG frames from each camera, two viewers sharing one native
  upstream, continued delivery after the first viewer closes, and OFF/zero
  viewers after the final viewer closes.
- Logout revokes the bearer and closes an already-open WSS connection and both
  active camera responses; another validation login observes source cleanup.
- Chromium performs the generated login, receives public WSS, decodes the real
  A1/P1S images, checks wide/narrow layout and signs out without persisting or
  transmitting the private key. The browser driver waits for the initial WSS
  snapshot before issuing controls, rather than assuming the initial HTML is
  already an interactive channel.

Repeat the explicitly live, read-only checks from the repository root:

```sh
/path/to/test-venv/bin/python tests/check_printer_public.py \
  --origin=https://3dprint.cswine.cloud \
  --key-file="$HOME/.config/fprisc/printer-dashboard/mac-ed25519.pem" \
  --output=build/printer-native-runtime/deployment-check.json \
  --commit=9782b38420bb24c5b61d095adecfaea93abd3be2
node tests/check_printer_public_browser.cjs https://3dprint.cswine.cloud \
  "$HOME/.config/fprisc/printer-dashboard/mac-ed25519.pem" \
  build/printer-native-runtime/public-browser-check.json
```

The drivers keep key contents, bearer cookies and camera pixels out of output
and saved evidence. The wire driver decodes HTTP transfer framing before MJPEG
framing, including nginx's chunked responses. These are deployment-time read-only
transport/UI checks, not a long-duration soak or physical-print verdict.
