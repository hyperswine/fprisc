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
service; a capture in progress at viewer disconnect can run up to eight seconds.

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
