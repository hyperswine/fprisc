# Home inventory on the Mac mini, public at inv.cswine.cloud

`examples/inventory.fpr`, built natively (macOS arm64, links only libSystem),
runs on the Mac mini as a launchd agent bound to its Tailscale address. The
Linode terminates TLS and proxies to it over the tailnet, as it does for
logbook and pos1.

```
phone ──https/wss──▶ nginx on localhost-0 (Linode) ──tailscale──▶ jqs-mac-mini-1 100.107.153.43:6720
                     inv.cswine.cloud, Let's Encrypt              ~/inventory/inventory  ──▶ ~/inventory/inventory.log
```

| Script | Does |
|---|---|
| `deploy.sh` | build, copy to `~/inventory`, back up the log, (re)start `cloud.cswine.inventory`, probe both URLs |
| `add-member.sh NAME` | add a member or set a new password (asked without echo, sent over ssh stdin), then restart |
| `nginx.sh` | the site on the Linode: HTTP for the ACME challenge, certificate by webroot, then the TLS site from `nginx/` |

Settings are in `state.env`. Redeploy after changing the app: `./deploy.sh`.

## On the Mac mini

- `~/inventory/inventory.log`: the inventory. One JSON line per change, never
  rewritten; `deploy.sh` copies it to `backups/` before each restart (newest 30
  kept). It holds password hashes and device-token hashes, never a password or a token.
- `~/inventory/inventory.out`: the server's output.
- `launchctl kickstart -k gui/$(id -u)/cloud.cswine.inventory` restarts it.

## Moving the old app's data again

The Firestore collection was imported on 2026-10-13 (48 items). The importer
skips items that are already there (same name and place), so a fresh export can
be imported again:

```
curl -s "https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/inventory?pageSize=1000&key=$API_KEY" > firestore.json
scp firestore.json jq@jqs-mac-mini-1:inventory/
ssh jq@jqs-mac-mini-1 'cd ~/inventory && ./inventory --store=inventory.log --import=firestore.json && launchctl kickstart -k gui/$(id -u)/cloud.cswine.inventory'
```

## Tear down

`launchctl bootout gui/$(id -u)/cloud.cswine.inventory` and remove the plist on
the Mac mini; on the Linode remove `/etc/nginx/sites-{enabled,available}/inv.cswine.cloud`,
reload nginx, and `certbot delete --cert-name inv.cswine.cloud`.
