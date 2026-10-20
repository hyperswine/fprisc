# Printer dashboard HTTP watchdog

Installed on the mini on 2026-10-20 after a live-process / failed-HTTP outage.
The application itself remains the same signed FP-RISC binary. This separate
Python standard-library check does not load credentials or contact printers.

Every 30 seconds it GETs `/health` directly on `100.107.153.43:6730`, with the
required `Host: 3dprint.cswine.cloud`, expecting exactly HTTP 200 and `ok\n`.
A bad public DNS/proxy route alone cannot trigger an app restart.

Recovery requires three consecutive failures, at least 120 seconds observing
the same PID, and at least 600 seconds since a prior watchdog restart. The
running system launchd job, process UID and canonical executable path must all
match. An absent/stopped service is left stopped. Before signaling, it saves
bounded logs, socket metadata, a two-second stack sample and the maintenance
snapshot's hash, then rechecks health and identity. It sends only SIGTERM;
existing launchd KeepAlive owns replacement. It does not launch a second writer
or escalate to SIGKILL. Captures retain the newest ten watchdog incidents, and
the dedicated activity log rotates at 1 MiB.

## Current deployment and limits

- Script: `/Users/jq/printer-host/ops/watchdog.py`
- Agent: `~/Library/LaunchAgents/cloud.cswine.printer-watchdog.plist`
- Domain: `gui/501/cloud.cswine.printer-watchdog`
- State: `/Users/jq/printer-host/diagnostics/watchdog-state.json`
- Log: `/Users/jq/printer-host/logs/watchdog.log`
- Evidence: `/Users/jq/printer-host/diagnostics/watchdog-<timestamp>/`

The actual LaunchAgent context was verified to reach the healthy app and exit
with code zero. It runs while jq's GUI login session exists and loads on login;
it does **not** provide recovery before login or after logout. The underlying
Printer Host remains a system LaunchDaemon and still starts at boot. Installing
the watchdog as a system LaunchDaemon with UserName jq requires administrator
access, which the current SSH account lacks (`sudo -n` requires a password).
Do not claim boot-wide watchdog coverage until that install and reboot are tested.

`/health` proves the gateway's request/response path, not authenticated view,
telemetry freshness or camera correctness. A failed printer alone must not
restart this process. This is a containment measure, not a proven fix for the
unidentified application/runtime trigger. Repeated captures should guide a
specific fix; do not replace diagnosis with an unlimited restart loop.

## Verification and operations

`python3 tests/check_printer_watchdog.py` verifies consecutive-failure threshold,
healthy reset, PID changes, startup grace, cooldown, stopped/unrelated process
protection, recovery during capture, identity races and state-write failure.
Eleven tests passed before deployment. No outage was intentionally injected into
production to test the watchdog; manual SIGTERM recovery through the existing
system daemon was verified during the incident.

Inspect from `ssh jq@100.107.153.43`:

```sh
launchctl print gui/501/cloud.cswine.printer-watchdog
cat ~/printer-host/diagnostics/watchdog-state.json
tail ~/printer-host/logs/watchdog.log
```

Disable without stopping the app:

```sh
launchctl bootout gui/501/cloud.cswine.printer-watchdog
```

Remove the matching LaunchAgents plist as well to prevent loading at next login.
For a temporary application stop, boot out its **system** job deliberately;
this watchdog respects the absence of a running service. Killing the app alone
allows its existing KeepAlive policy to restart it.

A future admin installation should use the same script, root-owned plist in
`/Library/LaunchDaemons`, and explicit UserName jq / GroupName staff. Disable the
GUI agent before enabling the system job; retain locking as defense in depth.
Verify macOS network permission in that actual context before enabling recovery.
