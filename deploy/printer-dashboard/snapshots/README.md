# Optional X1C snapshot decoder

This service is an adapter for the camera codec only. FP-RISC continues to own
public authentication, viewer lifetime, shared media, polling cadence and UI.
The A1/P1S camera path stays native. No changes to nginx are needed.

On the current Mac mini, install FFmpeg (`brew install ffmpeg`), place
`tools/printer_snapshot.py` at `/Users/jq/printer-host/printer_snapshot.py`, mode
0700, and install the adjacent plist in `/Library/LaunchDaemons`, root:wheel,
0644. It runs as jq, uses existing protected runtime credentials and listens on
loopback port 6741 only. Never expose that port through nginx or Tailscale Serve.

Before cutover, back up the signed `PrinterHost.app`, public `printers.json` and
record hashes of persistent maintenance/session data. Update only the X1C row
to `bambu-rtsps-snapshot` with camera port 322 and snapshot port 6741. Deploy the
new native host through the existing signed app identity; preserve data files,
the existing public auth allowlist and LaunchDaemon arguments. Start the decoder
service before restarting the host. The host should keep working when the
decoder is down; only X1C previews become unavailable and retry.

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/cloud.cswine.printer-snapshots.plist
sudo launchctl kickstart -k system/cloud.cswine.printer-host
```

Validate an actual JPEG on the mini, verify an intentionally incorrect camera
TLS identity is rejected, and then read two authenticated public X1C frames
roughly ten seconds apart. Confirm `camera_mode=snapshot`, fresh timestamps,
one upstream shared by multiple viewers, logout cleanup and anonymous 401.
Verify existing A1/P1S telemetry/cameras separately. Browser tests should cover
recovery and cancellation when the preview is off/hidden. Synthetic tests are
not a substitute for public deployment acceptance.

Rollback: stop the decoder with `sudo launchctl bootout system/cloud.cswine.printer-snapshots`,
restore the backed-up app bundle and public printer configuration, and restart
only Printer Host. Do not restore or replace maintenance/session stores. No
printer operation or other service needs to be restarted.

FFmpeg is an optional runtime dependency. Record its installed version and the
adapter/binary hashes with each deployment. Do not automatically upgrade it
while a preview is active. Neither video nor photographs are saved by this
service; a capture in progress at viewer disconnect can run up to fifteen seconds.

## Current installation without administrator access

The Mini's `jq` SSH account cannot use passwordless sudo. The decoder can use
`~/Library/LaunchAgents/cloud.cswine.printer-snapshots.plist` instead: remove
`UserName` and `GroupName` from the template and bootstrap `gui/501`. This
survives decoder failures and restarts when jq logs in, but **requires a user
login after a reboot**. The native dashboard remains its existing system
LaunchDaemon; only X1C pictures depend on this user service. An administrator
can later boot out the user service and install the system template above.
Never run both copies on port 6741.

## 2026-10-27 validation and deployment

Targeted decoder tests and native gateway snapshot tests passed, including
stale-frame rejection, recovery, shared captures and logout cleanup. Generated
browser checks passed on one/four harts, including retry cancellation when off
or hidden. Real X1C RTSPS capture from the Mini over SSH returned a 35,934-byte
JPEG in 3.87 seconds; an incorrect TLS identity was rejected. FFmpeg installed
for the adapter is 9.0.2.

The GUI LaunchAgent failed its pre-cutover camera probe. A credential-free
TCP/TLS probe in that same GUI domain returned macOS errno 65 (No route to host),
while SSH access worked. This is consistent with the Mini's earlier Local
Network permission problem. The install rolled back before replacing the app;
health returned 200, the original executable hash was unchanged, X1C camera
mode reverted to `none`, and the new service was removed.

After the owner allowed the Mini's Local Network prompts, the same background
TCP/TLS probe succeeded and deployment completed. Authenticated public HTTPS
acceptance received two different X1C JPEGs 8.91 seconds apart, confirmed sharing
between two viewers, fresh capture timestamps and logout stopping the preview.
The pre-deployment session remained valid; existing sessions and maintenance
data were preserved. A1/P1S each returned two camera frames, all three printers
reported ONLINE, and anonymous status/camera requests still returned 401.
No printer controls were sent. The optional decoder remains a GUI LaunchAgent
and requires user login after a Mini reboot, as described above.

Installed signed host SHA-256:
`2218cad22872791807cad4607acae0ff41bfe080e9cf734fda79d7606bf28613`.
Adapter SHA-256:
`c46b5c00e7fbe1e056e41e4d131f3df6efb85f8524033666d6c6925ad07a73ee`.
Rollback: `/Users/jq/printer-host/rollback/snapshots-20261027T124941Z`.
Deployment record on the Mini:
`/Users/jq/printer-host/releases/snapshots-20261027/deployment.json`.

Local artifacts, source hashes and the repeatable staged installer are under
ignored `build/printer-snapshots-20261027/`. The unrelated source-boundary guard
`check_pure_applications.py` currently stops on its existing `std/view.fpr`
`cssFor` expectation; HEAD already uses `entryStages` instead of `localCss`.

## 2026-10-29 camera reliability investigation

The deployed X1C adapter repeatedly returned 503 after approximately 8 seconds.
The unchanged decoder, run diagnostically on the Mini with a 25-second bound,
returned valid H.264-derived JPEGs after approximately 8.9-10.2 seconds. Its
8-second capture limit is below observed first-frame latency. The surrounding
budgets are also tight: snapshot HTTP 9.5 seconds, first frame 12 seconds and
gateway headers 14 seconds. Raising only the decoder limit is insufficient;
coordinate the bounded deadlines and validate in the deployed GUI context.
Shorter FFmpeg stream-analysis settings alone did not make capture reliably
finish within the current bound. No production setting was changed.

A1 and P1S each delivered 24 complete, independently decoded public JPEGs over
three reconnects without errors. The A1's original intermittent interruption
was not captured, so its underlying trigger remains unknown. However, actual
public-page desktop and mobile WebKit tests reproduced a recovery gap: after
one simulated transient request failure, the A1 retained a broken image source
and sent no automatic retry over 12 seconds. Manual off/on immediately restored
valid frames. `std/browsermedia.fpr` enables retry only for the configured
`snapshot` mode; native stream errors currently require manual reconnection.
Bounded native-stream retries should also cancel on off, hidden tabs and logout.

All printer camera/MQTT ports passed verified TLS from the Mini's SSH context;
that is not independent proof of GUI-domain Local Network permission. Both
deployed services were running. Diagnostics used only existing local credentials
on their current machines, closed test camera viewers and signed out test
sessions. No printer controls or service restarts were sent.

Sanitized evidence: [camera investigation](../../../docs/evidence/2026-10-29-printer-cameras.json).
The test WebKit profiles approximate desktop/mobile Safari; they are not a
recording of the owner's actual Safari session. The unrelated local
`compiler/Build.hs` edit was preserved.

## 2026-10-29 camera recovery deployment

The investigation above describes the pre-fix installation. The fixes are now
deployed through the same signed app identity and existing GUI decoder service.
The bounded X1C deadline chain is 15 seconds for FFmpeg capture, 18 seconds for
the native snapshot HTTP request, 22 seconds for the first snapshot and 24 seconds
for gateway response headers. Native A1/P1S first-frame time remains 12 seconds.
Snapshot polls pause at least 2.5 seconds after each capture, avoiding an immediate
hit on the adapter's two-second cache. Slow camera startup can make the effective
snapshot interval longer than the UI's approximate ten-second cadence.

Native image errors now reconnect automatically with 1, 2, 4, 8 and then 10-second
backoff. Each connection uses a fresh query nonce to avoid reusing a failed or
cached response. Success resets the backoff. Off, hidden/disconnected pages,
pagehide and detached camera elements cancel pending reconnects. Snapshot mode
retains its separate ten-second retry policy. Reload an existing dashboard tab
once to load the updated generated browser program.

Focused regressions passed: four decoder tests including a nine-second valid
capture; native gateway/authentication and slow snapshot gateway on one/four
harts; generated browser presentation, Live UI and media lifecycle on one/four
harts. Backoff, reset, actual network-abort recovery, query routing and timer
cancellation are covered. The delayed snapshot test also found and now covers
the adapter-cache polling issue.

The real supervised GUI decoder returned a 31,735-byte JPEG in 9.33 seconds before
app cutover. Public HTTPS acceptance independently decoded three JPEGs from each
of A1, P1S and X1C, including different successive frames, shared two viewers per
camera and verified viewer cleanup. All three telemetry connections were ONLINE;
this is a connectivity check, not a claim of successful physical print completion.
A session opened before deployment still returned 200 after the switch. Existing
sessions, public configuration and maintenance data were preserved. Anonymous
status and camera requests still returned 401. No printer controls were sent.

Desktop and iPhone-like WebKit profiles displayed real A1 images, recovered from
an injected connection reset without manual off/on, cancelled retries while
hidden and displayed X1C snapshots. The first mobile probe timed out before a
camera request; a separate mobile rerun passed the complete sequence. These are
WebKit profile tests, not physical Safari device acceptance. The original A1
interruption trigger remains unobserved; automatic recovery fixes the confirmed
gap. The optional decoder still requires Mini user login after reboot.

Installed signed host SHA-256:
`02c4f67ddfd669c46d35db318fb8a5697d69511ab4c4edafc85b045d879e3ba5`.
Adapter SHA-256:
`3dcaeea6c74c310072a50c3af30a6576875ec8ae30e2c168808580164e28b016`.
Rollback app and decoder:
`/Users/jq/printer-host/rollback/camera-recovery-20261029T042507Z`.
Restore only the app and adapter, preserving current maintenance/session stores.
The staged installer and deployment record are in
`/Users/jq/printer-host/releases/camera-recovery-20261029/`.

Sanitized [deployment evidence](../../../docs/evidence/2026-10-29-printer-camera-deployment.json)
records hashes, public frame checks, session continuity and browser recovery.
Ignored local build/test artifacts are under
`build/printer-camera-investigation-20261029/`. Concurrent compiler/Sol work was
preserved and was not included in this camera deployment.
