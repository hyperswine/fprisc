# Printer dashboard on the M1 Mac mini

Deployed 2026-10-17, Australia/Sydney. `https://3dprint.cswine.cloud` now routes
through Linode nginx to the M1 Mac mini at `100.107.153.43:6730`. The original
workstation's host is stopped. The mini runs as **jq**, using the approved
**Printer Host** app identity; the optional root-runtime installer was not used.

## Runtime and startup

- SSH: `jq@100.107.153.43` over Tailscale.
- Runtime: `/Users/jq/printer-host`, separate from the existing source checkout.
- System LaunchDaemon: `/Library/LaunchDaemons/cloud.cswine.printer-host.plist`,
  owned by root:wheel, mode 0644. The actual process runs as jq:staff, with four
  harts, an empty external-tool PATH, umask 077, RunAtLoad, KeepAlive and a
  ten-second restart throttle. The duplicate GUI LaunchAgent remains disabled.
- `current` points to `PrinterHost.app/Contents/MacOS`. This selects the signed
  app with bundle ID `cloud.cswine.printer-host` and an explicit Local Network
  purpose description, matching the owner's desktop approval.
- Persistent files are in `data/`, outside the release and app bundle. Printer
  credentials and maintenance snapshots are mode 0600. Only the two selected
  printer access-code bindings were transferred, with explicit user approval.
  No private login key was copied to the mini or printed.
- Logs: `logs/host.stdout.log` and `logs/host.stderr.log`.
- Current AC policy disables sleep and enables restart after power failure.
  System-service registration and automatic process restart were verified;
  a whole-machine reboot and long-duration soak were not performed.

Inspect the service over SSH:

```sh
launchctl print system/cloud.cswine.printer-host
```

Administrator commands for an intentional restart or stop:

```sh
sudo launchctl kickstart -k system/cloud.cswine.printer-host
sudo launchctl bootout system/cloud.cswine.printer-host
```

Do not run the earlier root-runtime installer: the working deployment remains
unprivileged. The unused alternative installer is retained only as a rollback
artifact, rather than at its old executable command path.

## Executable identity

The original identity below remains active. On 20 October, the targeted
`b415870-writer-lifetime-20261020` fix passed isolated tests but failed real printer
access after installation; both attempts were rolled back. See the
[outage follow-up](2026-10-20-PRINTER-DASHBOARD-OUTAGE.md) for the reproduced
socket race, candidate hashes, validation and macOS app-identity investigation.

Source commit: `b4158705155c9fc901d9b2bd3e07e968636d99cc`.

Original tested release artifact SHA-256:
`496fed453a38a22d7c605a7f408614c8ccf2b14acf36f421169bf944c3c721dc`.
It remains unchanged in `releases/<commit>/printer-host`.

The app bundle was ad-hoc signed for its identified macOS packaging; installed
executable SHA-256:
`d9c0b0f20a577ac9431e682a477c3f48026e5a6dae62ce960e6593cdf886facf`.
The bundle signature and deployed executable hash were verified. Printer TLS
identities, trusted CA bytes and the public login allowlist were preserved.
The CA file paths were relocated to the mini's data directory.

## Maintenance preservation

The old host was frozen before snapshotting and gracefully stopped before public
cutover. Its authoritative log was compared again immediately before switching;
it had not changed since the verified transfer. The mini's previous initial data
was preserved separately before atomic replacement. Full decoded maintenance
model equality was checked through the authenticated mini API.

Snapshot SHA-256 before and after transfer:
`5b7be6d7369c1141daf4e9d27028ab5699f9c2d49055520bb8d3ac7a3750b2f3`.
The preserved snapshot has ten tasks, revision zero and zero history entries.
No maintenance completions, workshop observations or print outcomes were invented.

Final original-host backup:
`build/printer-mini-migration/final-cutover-20261017T080712Z/`.

Mini's prior initial data:
`/Users/jq/printer-host/rollback/before-maintenance-20261017T075202Z/`.

The mini is now authoritative. Subsequent rollback or deployment must preserve
its latest primary maintenance snapshot and any backup, rather than overwriting
new observations with the original workstation's historical copy. Run only one
host against any maintenance path.

## Proxy and rollback

Linode: `root@localhost-0`.
Active site: `/etc/nginx/sites-available/3dprint.cswine.cloud`.
Upstream: `http://100.107.153.43:6730`.
Only the upstream and descriptive comment changed. TLS certificates, public-key
login boundary, forwarded headers, WebSocket upgrade and unbuffered MJPEG settings
were retained. `nginx -t`, reload, active-upstream readback and public health passed.

Previous nginx site backup:
`/etc/nginx/printer-rollback/3dprint-20261017T080716Z.conf`.

Original host launch arguments remain in ignored
`build/printer-mini-migration/old-host-rollback.json` on the workstation. Its
verified reachable binding is loopback `127.0.0.1`; the old Tailscale proxy route
was `100.94.229.117:6730`. Before rollback, stop/freeze the mini, retain its latest
log and backup, transfer that data to the old runtime, start only the old writer,
restore the nginx backup, validate and reload, then repeat public acceptance.
Restarts invalidate login sessions.

## Acceptance and device boundary

Public wire acceptance passed authenticated HTTPS/WSS, fresh real A1 telemetry,
shared camera upstreams, immediate camera reconnect, final-viewer cleanup,
maintenance schedules/controls and logout revocation. Anonymous protected routes
returned 401. Isolated Chromium acceptance passed generated login, A1 camera
image decoding, 1300/390 px layouts, all maintenance tabs and sign-out, without
persisting or transmitting the private login key. Camera pixels were not saved.

Evidence remains in ignored `build/printer-mini-migration/` on the workstation:
`precutover.json`, `mini-public-acceptance.json`, `mini-browser-acceptance.json`,
`frozen-source.json` and `mini-deployment.json`. Copies of sanitized final records
are retained beside the mini's runtime.

The P1S initially remained OFFLINE because its old configured address,
`192.168.0.28`, is now the mini's own en1 address. It was subsequently discovered
at `192.168.0.27`, with SSDP serial `01P00A442400974`. The existing CA and hostname
verification confirmed that same identity on both TLS ports, 8883 and 6000.
Only its public host address was changed, with the previous configuration saved
at `rollback/p1s-address-20261017T081340Z/` on the mini. Its trusted identity and
runtime credentials were retained. A graceful restart preserved the maintenance
snapshot hash. Both A1 (`192.168.0.63`) and P1S then passed public HTTPS/WSS
telemetry, camera-sharing, reconnect/cleanup and logout acceptance. Updated
evidence is `both-printers-public-acceptance.json` and `p1s-address-update.json`
in the ignored migration directory and the mini's diagnostics directory. Full
Chromium acceptance also passed both real camera decodes (A1 1536×1080 and
P1S 1280×720), responsive layouts, maintenance tabs and sign-out; see
`both-printers-browser-acceptance.json`.
The retired workstation's public configuration also records the corrected
address for rollback. No printer movement, temperature change, upload or print
was commanded.

## Permission and earlier stall evidence

A standalone native connection probe succeeded from SSH but failed with
`Io No route to host` under the unapproved user/system role-account launch
contexts. A system-domain job configured with UserName jq still required Local
Network permission; the original expectation of a blanket daemon exemption was
incorrect. [Apple's role-account clarification](https://developer.apple.com/forums/thread/759955)
explains the distinction.

After the owner approved the desktop prompt, the service was aligned with the
identified app bundle and restarted. Real A1 telemetry and camera then passed.

Before that restart, the old mini process retained its listener but timed out on
HTTP requests. A short native stack sample was retained at
`diagnostics/before-permission-restart.sample.txt`; it showed sleeping scheduler
threads and accept-loop activity. Restart recovered HTTP service. Its exact
trigger remains unconfirmed, and the successful acceptance is not a long-running
reliability or reboot test.

## Follow-up: recurring HTTP outage, 2026-10-20

The process remained alive but reset HTTP requests after roughly 58 hours.
A restart recovered service with maintenance data unchanged. The
[incident report](2026-10-20-PRINTER-DASHBOARD-OUTAGE.md) records evidence,
the unconfirmed underlying trigger and the deployed HTTP watchdog. Its current
GUI-session scope does not provide boot-wide recovery; see the watchdog runbook.

The follow-up socket-lifetime fix and bounded native diagnostics are tested in
source, but the 20 October redeployment was rolled back. The updated app reported
TCP errno 65 before TLS, while SSH could reach both printers. The original
signed app remains installed. Resolve the mini's app/context-specific Local
Network access and repeat full authenticated A1/P1S acceptance before promoting
the candidate; HTTP health alone is insufficient. See the incident's final
redeployment section for artifact hashes, rollback and validation evidence.
