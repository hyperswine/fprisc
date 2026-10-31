# Logbook restored on the M1 Mac

Restored 30 October 2026, Australia/Sydney. The owner explicitly selected a new
database after the previous deployment's temporary data directory could not be
found. No surviving database was overwritten. Production starts with zero
entries; this is a fresh database, not recovery of the old observations.

## Service and data

- Host: `jq@100.107.153.43`, `JQs-Mac-mini.local`, Apple M1, macOS 27.0.1.
- Runtime: `/Users/jq/logbook`, independent of source checkouts and compilers.
- Release: `releases/9d086f0-20261030/logbook`, selected by the `current` symlink.
- Source revision: `9d086f0c5c52d9cd684d6d0cf26c6735bf7709ac`.
- Executable SHA-256:
  `82217563a725d2dc25269b2c5ce9f254a8606a9ac055a1ce2cb7725cf5c23f00`.
- Database: `/Users/jq/logbook/data/logbook.kvlog` and its adjacent
  `logbook.kvlog.store/` shard directory. Back up the entire `data/` directory.
- Logs: `/Users/jq/logbook/logs/stdout.log` and `stderr.log`.
- Startup definition:
  `/Users/jq/Library/LaunchAgents/cloud.cswine.logbook.plist`.
- Service: `gui/501/cloud.cswine.logbook`; `RunAtLoad`, `KeepAlive`, a ten-second
  restart throttle, umask 077 and four harts. It binds only the M1's Tailscale
  address on port 6700.

This is a user LaunchAgent: it starts when **jq logs in**, continues without an
SSH session, and restarts if the process exits. It does not start before login
or remain available after logout. Installing a system LaunchDaemon would need
administrator authorization; non-interactive sudo was unavailable. No login or
power settings were changed, and a whole-machine reboot was not tested.

Inspect and intentionally restart it over SSH:

```sh
launchctl print gui/501/cloud.cswine.logbook
launchctl kickstart -k gui/501/cloud.cswine.logbook
```

For a consistent manual backup, stop the writer, copy all of `data/` to a new
timestamped directory under `backups/`, verify the copied file hashes, and then
reload the service. Do not run a second instance against the live database.
The stop/start commands are:

```sh
launchctl bootout gui/501/cloud.cswine.logbook
# Copy and verify data here while the writer is stopped.
launchctl bootstrap gui/501 "$HOME/Library/LaunchAgents/cloud.cswine.logbook.plist"
```

The initial empty database is retained at
`/Users/jq/logbook/backups/initial-20261030T024619Z/`, including its hash manifest.
The initial kvlog SHA-256 is
`b8183b25e799f7763c2e2031a54c74d234ef524699142b0e34123f13c713bdda`.
That initial snapshot is not a substitute for backing up future observations.

## Public route and rollback

The public Linode host (`root@100.71.255.16`) still pointed Logbook at the original
workstation, `100.94.229.117:6700`. Its existing nginx site now proxies to
`http://100.107.153.43:6700`; HTTPS, forwarding headers, WebSocket upgrade,
timeouts and unbuffered responses are unchanged. Configuration validation and
reload passed.

- Active site: `/etc/nginx/sites-available/logbook.cswine.cloud`.
- Previous site backup:
  `/etc/nginx/logbook-rollback/logbook-20261030T024642Z.conf`.

The previous route is retained for reference; restoring it alone would return
to the unavailable original service. Any future rollback must first preserve
the latest M1 data and establish a healthy replacement. To switch executable
releases, stop the service, snapshot `data/`, change `current` to an already
validated compatible release, and start exactly one writer. Do not restore the
initial empty snapshot over subsequently recorded entries.

## Validation

- The exact deployed ARM64 executable passed `tests/std/logbook_ws.py` on the
  M1 against a separate disposable database: add/edit/delete, pagination, two
  tabs, isolated searches, journal replay, and process restart with 24 retained
  fixture entries. None of those observations entered the production database.
- The live LaunchAgent served the new database, then automatically restarted
  after SIGTERM, returning HTTP 200 and retaining zero entries.
- Public `https://logbook.cswine.cloud/` returned HTTP 200 with the Logbook title,
  observation form and empty-state content; HTTP redirected to HTTPS.
- Public WSS `/ws` passed the upgrade handshake and accept-key validation, two
  simultaneous tabs, search/clear round trips and search isolation. Production
  still contained zero entries after these checks.
- Browser rendering was not inspected because local browser control was
  disabled. HTTP and real TLS WebSocket protocol checks were performed.

Sanitized deployment and service evidence is retained on the M1 in
`/Users/jq/logbook/deployment.json` and `validation/`. Local build and public
acceptance evidence is under ignored `build/logbook-mini-2026-10-30/`.
