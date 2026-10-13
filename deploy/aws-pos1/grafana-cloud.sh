#!/bin/sh
# Connect the instance's Alloy to your Grafana Cloud stack and upload the
# POS v1 dashboard.  Reads fprisc/secrets.env (gitignored, mode 0600):
#
#   GRAFANA_URL=https://<stack>.grafana.net
#   GRAFANA_TOKEN=glsa_...         a service account token: reads the stack's
#                                  Prometheus/Loki endpoints, writes the dashboard
#   GRAFANA_WRITE_TOKEN=glc_...    an access policy token with metrics:write and
#                                  logs:write -- what Alloy pushes with
#
# Tokens never appear in a command line: curl reads its header from stdin and
# the instance gets its env file over ssh's stdin.
#   ./grafana-cloud.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
secrets=${SECRETS:-$here/../../secrets.env}
set -a; . "$secrets"; set +a
: "${GRAFANA_URL:?GRAFANA_URL missing from $secrets}" "${GRAFANA_TOKEN:?GRAFANA_TOKEN missing from $secrets}"
GRAFANA_URL=${GRAFANA_URL%/}
api() { printf 'header = "Authorization: Bearer %s"\n' "$GRAFANA_TOKEN" | curl -fsS -K - "$@"; }
ds() { api "$GRAFANA_URL/api/datasources/uid/$1" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["url"].rstrip("/"), d["basicAuthUser"])'; }

# ---- the dashboard (service account token)
api -X POST -H 'Content-Type: application/json' --data-binary @"$here/grafana/pos1-dashboard.json" \
  "$GRAFANA_URL/api/dashboards/db" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("dashboard:", d.get("status"), sys.argv[1] + d.get("url",""))' "$GRAFANA_URL"

# ---- Alloy's destination (access policy token)
if [ -z "${GRAFANA_WRITE_TOKEN:-}" ]; then
  echo "No GRAFANA_WRITE_TOKEN in $secrets: Alloy is not connected yet." >&2
  echo "Create one at grafana.com > Administration > Cloud access policies (scopes metrics:write, logs:write)," >&2
  echo "add GRAFANA_WRITE_TOKEN=glc_... to $secrets, and run this again." >&2
  exit 2
fi
set -- $(ds grafanacloud-prom); prom_url="$1/push"; prom_user=$2
set -- $(ds grafanacloud-logs); loki_url="$1/loki/api/v1/push"; loki_user=$2
echo "metrics -> $prom_url (user $prom_user)"
echo "logs    -> $loki_url (user $loki_user)"
. "$here/state.env"
printf 'GCLOUD_PROM_URL=%s\nGCLOUD_PROM_USER=%s\nGCLOUD_LOKI_URL=%s\nGCLOUD_LOKI_USER=%s\nGCLOUD_TOKEN=%s\n' \
  "$prom_url" "$prom_user" "$loki_url" "$loki_user" "$GRAFANA_WRITE_TOKEN" |
  ssh -i "$SSH_KEY" "ec2-user@$PUBLIC_IP" \
    'sudo install -m 0600 -o root -g root /dev/stdin /etc/alloy/grafana-cloud.env && sudo systemctl restart alloy'

# ---- arrival: ask the stack itself, through its datasources
echo "waiting 90s for the first scrape and push..."
sleep 90
q() { api -G "$GRAFANA_URL/api/datasources/proxy/uid/$1" --data-urlencode "query=$2" | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(len(r))'; }
echo "metric series for instance=pos1: $(q grafanacloud-prom/api/v1/query 'count by (job) ({instance="pos1"})')"
echo "log streams for instance=pos1:   $(q grafanacloud-logs/loki/api/v1/query 'count_over_time({instance="pos1"}[10m])')"
# only the Alloy started above: the one it replaced logs its placeholder
# destination's errors as it shuts down, which is expected
ssh -i "$SSH_KEY" "ec2-user@$PUBLIC_IP" 'pid=$(systemctl show -p MainPID --value alloy)
  n=$(sudo journalctl _PID=$pid --no-pager | grep -cE "level=(error|warn)")
  echo "alloy errors/warnings since restart: $n"
  [ "$n" = 0 ] || sudo journalctl _PID=$pid --no-pager | grep -E "level=(error|warn)" | tail -3' || true
