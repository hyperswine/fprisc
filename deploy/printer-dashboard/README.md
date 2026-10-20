# Printer dashboard proxy

## Current deployment

Production uses `root@localhost-0` (Linode Nginx) to proxy to
`jq@100.107.153.43:6730` (M1 Mac mini Printer Host system LaunchDaemon).
The tracked Nginx template now matches this upstream. Use the
[migration runbook](../../docs/2026-10-17-PRINTER-MAC-MINI-MIGRATION.md) for
current service/data paths and rollback. The old macm4 host is retired.

A 2026-10-20 outage was recovered by restarting the living-but-unhealthy app.
See the [incident report](../../docs/2026-10-20-PRINTER-DASHBOARD-OUTAGE.md) and
[HTTP watchdog runbook](watchdog/README.md), including its GUI-session limitation.
The tested socket-lifetime update was rolled back pending macOS printer-network
access in the updated app context; the original signed binary remains installed.

## Historical workstation deployment (superseded 2026-10-17)

`3dprint.cswine.cloud` resolves to the Linode (`root@localhost-0`). The app
runs on macm4 at `127.0.0.1:6730`; its private FP-RISC listener and printer
credentials stay on that machine.

Route:

```
https://3dprint.cswine.cloud
    -> Linode nginx (TLS, public login endpoint)
    -> Tailscale 100.94.229.117:6730
    -> macm4 127.0.0.1:6730
    -> native FP-RISC host / A1 and P1S LAN services
```

The Tailscale route is a TCP forward, preserving the public Host and Origin
headers (HTTP Serve's hostname routing would reject the custom domain):

```sh
tailscale serve --bg --tcp=6730 tcp://127.0.0.1:6730
# remove only this route:
tailscale serve --tcp=6730 off
```

nginx configuration: `nginx/3dprint.cswine.cloud`.
The access snippet `/etc/nginx/snippets/3dprint-access.conf` now contains only
comments: there is no IP allowlist. The app requires public-key login before
serving printer data, WebSockets or cameras. The bootstrap file exposes only the certificate
challenge and otherwise returns 404. Obtain the certificate using:

```sh
certbot certonly --webroot -w /var/www/3dprint-acme \
  -d 3dprint.cswine.cloud --non-interactive --keep-until-expiring
```

Validate with `nginx -t` before reloading. Back up an existing site/access
snippet before replacing it, restore them if validation fails, and verify
HTTPS, live WebSocket patches and two consecutive MJPEG frames afterward.
Keep the existing Certbot renewal timer; its deploy hook should validate
nginx and reload it only for this certificate's lineage.

The app is not a boot service: this proxy requires macm4 to be awake, connected
to Tailscale, and running the dashboard. Its current launcher is documented in
`examples/printer-dashboard/README.md`. No printer access codes belong in
nginx, a remote deployment file, or Git.

## Public-key authentication

Launch the bridge with `--origin=https://3dprint.cswine.cloud` and its public
Ed25519 `--auth` allowlist. It now requires challenge-response login for
the page, WebSocket, status and camera. The nginx IP restriction has been
removed by user request; authorized devices may sign in from any network. Proxy the `/auth/*`
routes exactly like the rest of the app; preserve Host/Origin and Set-Cookie,
disable caching, and do not log request bodies. The login private key stays
in the browser. See the application README for key formats and expiry.

## Deployment verified 2026-10-14

The Linode serves the domain over HTTPS without a source-IP restriction.
After backing up the access snippet, its allow/deny rules were removed,
`nginx -t` passed and nginx was reloaded. A request from the Linode's public
IP, previously rejected with 403, now receives the login page (200) and can
request a challenge (200). Anonymous `/api/status`, `/ws` and
`/camera/a1.mjpg` requests still receive 401 from the app. HTTPS challenge
cookies remain Secure. No other site was changed.

Earlier authenticated verification covered the HTTPS page and real A1 status,
WebSocket 101 upgrade/live patches/card controls, and two valid consecutive
JPEG frames through nginx. The external browser also showed the live page
and the real camera. The P1S was excluded during that initial check; it is
now enabled alongside the A1 after verifying its status and camera at its
current LAN address. Use `--printers=a1,p1s` when restarting the bridge.
The TLS certificate expires on 2027-01-12 and uses the existing Certbot
renewal timer, with `/etc/letsencrypt/renewal-hooks/deploy/30-3dprint-nginx`
validating/reloading nginx only after this certificate renews.

The previous bootstrap config and the staged access snippet were backed up
under `/root/nginx-backups/` on the Linode. No other site was edited. Tailscale
Serve persists the private TCP route, but the dashboard itself must still be
running on macm4; no macOS boot job was installed by this proxy deployment.


## Native services deployed 2026-10-15

The dashboard is running with both `--native-telemetry` and `--native-camera`.
FP-RISC now owns each printer's MQTT, verified camera TLS, camera framing,
shared viewers and MJPEG output. Python retains public authentication, HTTP/
WebSocket proxying, snapshot aggregation and process supervision. Public
origin, nginx and Tailscale routing were preserved.

The launcher now uses ignored `build/printer-native-runtime/printers.json` for
public identities/trust and `--credentials-env-file=../3d-models/.env` for only
the selected runtime access-code bindings. Both printers' MQTT/camera chains
and serial identities validate against Bambu Studio's installed printer CA
bundle. See [the exact launcher and acceptance record](../../examples/printer-dashboard/README.md#production-native-deployment-2026-10-15).
Native telemetry and two consecutive native-camera JPEGs per printer were
verified through authenticated public HTTPS, followed by final-viewer cleanup
and logout revocation. Anonymous status still returns 401. The PID/log/evidence
live under ignored `build/printer-native-runtime/`; no boot job was installed.

## Single-process native host verified 2026-10-15

The Python gateway has now been replaced by `build/printer-host` from application
commit `9782b38420bb24c5b61d095adecfaea93abd3be2`. The old gateway and all its
helper processes exited. FP-RISC owns the public gateway, Ed25519 authentication,
Live view, telemetry register and both MQTT/camera services within one process.
The native host uses four harts and an empty tool PATH; it has no child processes.
The existing nginx/Tailscale route, origin, public allowlist, runtime access-code
file and verified vendor CA/serial identities were preserved.

Authenticated real-device acceptance through public HTTPS and WSS covered fresh
ONLINE A1/P1S reports, live snapshots/updates/camera controls, consecutive JPEGs,
one upstream shared by two viewers per camera, final-viewer cleanup and logout
revocation of active WSS/camera responses. Chromium also decoded both real camera
images after the generated login, checked wide/narrow layouts and signed out.
Anonymous protected routes remain 401. Existing browser sessions expired during
the switchover, so users must sign in again.

The [current launcher and repeatable acceptance commands](../../examples/printer-dashboard/README.md#single-process-native-host-deployed-2026-10-15)
replace earlier Python commands. Sanitized evidence and rollback files are under
ignored `build/printer-native-runtime/`. No proxy change or boot service was needed.
This is read-only deployment acceptance, not a printer operation or long soak.
