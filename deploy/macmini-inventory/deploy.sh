#!/usr/bin/env bash
# Build examples/inventory.fpr natively (macOS arm64) and install it on the Mac
# mini as the launchd agent cloud.cswine.inventory, listening on its Tailscale
# address only.  The Linode's nginx (inv.cswine.cloud) is the public front.
#
#   ./deploy.sh                 build, copy, (re)start
#   SKIP_BUILD=1 ./deploy.sh    copy and restart what is in out/
#
# The log (~/inventory/inventory.log) is never touched by a deploy; a copy is
# kept beside it before every restart.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
. "$here/state.env"

mkdir -p "$here/out"
if [ -z "${SKIP_BUILD:-}" ]; then
  (cd "$root" && make fpr >/dev/null && ./fpr build examples/inventory.fpr -o "$here/out/inventory")
fi

ssh "$MINI" "mkdir -p ~/inventory ~/inventory/backups"
scp -q "$here/out/inventory" "$MINI:inventory/inventory.new"
sed -e "s|@HOME@|$MINI_HOME|g" -e "s|@ADDRESS@|$ADDRESS|g" -e "s|@PORT@|$PORT|g" \
  "$here/cloud.cswine.inventory.plist" | ssh "$MINI" "cat > ~/Library/LaunchAgents/cloud.cswine.inventory.plist"

ssh "$MINI" bash -s <<'EOF'
set -euo pipefail
cd ~/inventory
if [ -f inventory.log ]; then cp inventory.log "backups/inventory.log.$(date +%Y%m%d-%H%M%S)"; fi
ls -t backups/inventory.log.* 2>/dev/null | tail -n +31 | xargs rm -f || true   # keep the newest 30
mv inventory.new inventory
uid=$(id -u)
launchctl bootout "gui/$uid/cloud.cswine.inventory" 2>/dev/null || true
# bootout returns before the agent is gone, and bootstrapping over it fails (error 5)
for i in $(seq 1 50); do launchctl print "gui/$uid/cloud.cswine.inventory" >/dev/null 2>&1 || break; sleep 0.2; done
launchctl bootstrap "gui/$uid" ~/Library/LaunchAgents/cloud.cswine.inventory.plist
sleep 2
launchctl print "gui/$uid/cloud.cswine.inventory" | grep -E "state =|pid =" || true
tail -n 3 inventory.out
EOF

curl -fsS -o /dev/null -w "direct http://$ADDRESS:$PORT/ -> %{http_code}\n" "http://$ADDRESS:$PORT/"
curl -fsS -o /dev/null -w "public https://$DOMAIN/ -> %{http_code}\n" "https://$DOMAIN/" || echo "public https://$DOMAIN/ not answering (see nginx/)"
