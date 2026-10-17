# Printer dashboard gateway recovery

Date: 2026-10-17, Australia/Sydney.

## Incident evidence

The deployed 2026-10-15 host (PID 82895, about 46 hours uptime) was alive,
with the public TCP listener still present. Requests to port 6730 ended in
connection resets/broken pipes before an HTTP response; public nginx returned
502. A private camera listener and the private Live listener could still send
HTTP responses. A short native stack sample showed scheduler sleeps and accept
loops, rather than a whole-process crash. No native failure appeared in the
startup-only gateway log.

Restarting the same executable restored local `/health` and the public login
page. A bounded burst of 400 health requests with four clients returned 200.
This establishes recovery by resetting process state; it does **not** establish
the exact original trigger or prove the original process's connection count.

## Connection lifetime repair

The gateway kept an admission list with a maximum of 32 handlers. It removed
entries only when each handler sent `Finished`. Socket-adoption refusal exited
without that notice; actor failure or a refused final send could also leave an
entry behind. Enough such exits could permanently exhaust admission.

The gateway now sends completion on adoption refusal and filters dead actors
from its admission list before applying the limit. Notices remain the fast
path; actor liveness is the authority. The native `Sys.alive` primitive already
exists and is also used by MVU. No new polling thread or external service was
added.

`tests/gateway_lifetime.fpr` checks 32 dead handlers with no completion notices,
retention of a live handler and completion after an invalid-descriptor adoption.
The optional `--lifetime-binary` flag includes these checks in the gateway
acceptance command on one/four harts.

## Camera response deadline repair

Public A1 testing reproduced another failure: a first camera connection returned
200 in about two seconds, while immediate reconnects returned 503 after roughly
3.2 seconds (`Native service unavailable`). The gateway allowed only three
seconds for all upstream response headers, but the private camera service
allowed twelve seconds for its first frame.

The private service now exports its first-frame/header budget. The public
camera proxy derives its header deadline from that budget: twelve seconds plus
two seconds for a bounded error response and scheduling. WebSocket upgrades keep
their three-second deadline. Origin checks, authentication and repeated session
checks remain active while waiting.

The synthetic camera peer can delay its first frame. Native gateway acceptance
uses a 3.5-second delay, above the old gateway deadline, on one/four harts.

## Deployment and preservation

The old executable, PID, log, receipt and maintenance store were copied into
private rollback directories under ignored `build/printer-native-runtime/`.
Configuration, public-key allowlist and maintenance-store hashes were checked
across replacement. Printer addresses, trust files and runtime credential paths
were retained; credential contents were not placed in logs or this report.

The replacement includes the repository's current linear connection/buffer
ownership changes plus the gateway repairs above. It retains one native host,
four harts, an empty external-tool PATH and the existing nginx/Tailscale route.
No printer movement, temperature changes or prints were commanded.

The deployment receipt records the executable SHA-256 and source hashes, and
marks that the application includes working-tree changes. Restarting invalidates
old login sessions.

## Verification boundary

- Failure-lifetime regression: one/four harts.
- Native gateway: demo and synthetic TLS telemetry/camera peers, one/four harts;
  includes origin/host checks, challenge binding/replay refusal, login, status,
  WSS, shared cameras and logout revocation.
- The P1S configured LAN endpoint refused TCP connections on 8883 and 6000. It
  must remain OFFLINE rather than be presented as a working printer. This is
  separate from the repaired public dashboard.
- Final public A1 acceptance passed: authenticated HTTPS/WSS, fresh telemetry,
  shared MJPEG upstream, immediate reconnect, final-viewer cleanup and logout
  revocation. Maintenance reads retained all ten schedules. Chromium decoded
  the A1 camera at 1536 × 1080 on its first attempt, checked 1300/390 px layouts
  and maintenance tabs, and confirmed sign-out without key persistence or
  transmission. Public `/health` and the login page return 200.
- Deployed executable SHA-256:
  `496fed453a38a22d7c605a7f408614c8ccf2b14acf36f421169bf944c3c721dc`.
  The receipt and sanitized live/browser evidence remain in the ignored runtime
  directory.

The original long-running process's triggering failure remains unconfirmed.
The repairs address independently demonstrated failure paths; they do not
constitute a 46-hour soak test.
