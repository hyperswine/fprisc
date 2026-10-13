#!/bin/sh
# Point Alloy at your Grafana Cloud stack.  Run ON THE SERVER:
#   sudo set-grafana-cloud
# Values are on grafana.com > your stack > "Prometheus" and "Loki" details
# (URL and numeric user), plus an access-policy token with metrics:write and
# logs:write.  The token is read without echo and kept root-only (0600).
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
f=/etc/alloy/grafana-cloud.env
printf 'Prometheus remote-write URL (…/api/prom/push): '; read -r pu
printf 'Prometheus user (number): '; read -r pn
printf 'Loki push URL (…/loki/api/v1/push): '; read -r lu
printf 'Loki user (number): '; read -r ln
printf 'Access policy token (hidden): '; stty -echo; read -r tok; stty echo; echo
umask 077
cat > "$f.new" <<ENV
GCLOUD_PROM_URL=$pu
GCLOUD_PROM_USER=$pn
GCLOUD_LOKI_URL=$lu
GCLOUD_LOKI_USER=$ln
GCLOUD_TOKEN=$tok
ENV
mv -f "$f.new" "$f"
systemctl restart alloy
sleep 20
echo "--- last Alloy errors (none is good):"
journalctl -u alloy --since "-30s" --no-pager | grep -iE 'level=(error|warn)' | tail -5 || true
