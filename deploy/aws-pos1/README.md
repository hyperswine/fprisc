# POS v1 on AWS (Graviton EC2) with Grafana Alloy

`examples/pos1.fpr`, cross-built on a Mac for Linux AArch64, runs on a t4g.small
(Amazon Linux 2023) in ap-southeast-2 behind Caddy (automatic Let's Encrypt),
with Grafana Alloy shipping metrics and logs to Grafana Cloud.

```
browser ──https/wss──▶ Caddy :443 ──▶ pos1 127.0.0.1:6710 ──▶ /var/lib/pos1/pos1.log
                                                                   │
                         Grafana Cloud ◀── Alloy ◀─────────────────┘ (+ host, Caddy, journald, probes)
```

## Scripts

| Script | Runs on | Does |
|---|---|---|
| `build.sh` | Mac | `fpr build --target=linux-aarch64 --cc aarch64-linux-gnu-gcc` into `out/pos1` |
| `provision.sh` | Mac | key pair, security group, instance, Elastic IP; writes `state.env` (idempotent) |
| `deploy.sh` | Mac | build, copy, run `server/install.sh` over SSH |
| `server/install.sh` | instance | users, pos1 + Caddy + Alloy units and config, restart (idempotent) |
| `grafana-cloud.sh` | Mac | reads `fprisc/secrets.env`, uploads the dashboard, finds the stack's endpoints and gives Alloy its credentials over ssh stdin, then checks data arrived |
| `allow-my-ip.sh` | Mac | replaces the SSH rule with your current IP |
| `server/set-grafana-cloud.sh` | instance | the manual alternative: `sudo set-grafana-cloud` prompts for URLs, users and token |

Redeploy after changing pos1: `./deploy.sh`. If SSH times out, your IP changed: `./allow-my-ip.sh`. SSH: `ssh -i ~/.ssh/pos1-key.pem ec2-user@<PUBLIC_IP>`.

## What Alloy collects

- **Host**: node_exporter metrics as `job="integrations/node_exporter", instance="pos1"`, so Grafana Cloud's Linux integration dashboards work.
- **Shop log as metrics**: `pos1_sales_total`, `pos1_revenue_cents_total`, `pos1_tax_cents_total` (labels `cashier`, `pay`=cash|card), `pos1_voids_total`, `pos1_restocked_units_total`. Derived from the append-only log, so pos1 itself is unchanged.
- **Stock**: pos1 runs with `--metrics=/var/lib/pos1/pos1.prom` and rewrites that file whenever a stock or the low mark changes. Alloy's textfile collector reads it as `pos1_stock{sku, name}` and `pos1_low_stock_at`.
- **Shop log as logs**: `{job="pos1-shop"}` with a `kind` label. `staff` lines carry PINs and are dropped before shipping.
- **Caddy**: `caddy_http_*` request metrics. **Journald**: pos1, caddy, alloy, sshd as `{job="systemd-journal", unit=...}`.

- **Probes**: `probe_success{job="pos1-probe", probe="direct"|"public"}`.

## Grafana Cloud

`fprisc/secrets.env` (gitignored) holds `GRAFANA_URL`, `GRAFANA_TOKEN` (a service
account token, for the dashboard and to look up endpoints) and
`GRAFANA_WRITE_TOKEN` (an access policy token with `metrics:write` and
`logs:write`, which Alloy pushes with). Then `./grafana-cloud.sh`.

The dashboard (`grafana/pos1-dashboard.json`, uid `pos1`) takes sales, revenue
and voids from the shop log in **Loki**, e.g.
`sum(count_over_time({job="pos1-shop", kind="sale"} [$__range]))`. Every sale
is one line there, so the sums are exact. The `pos1_*` counters are kept for
alerting, but `increase()` drops a brand-new series' first increment, so the
first sale per cashier and payment would be missing from them.

## A custom domain

Add an `A` record for the Elastic IP, put `EXTRA_HOSTS=<name>` in `state.env`, then `SKIP_BUILD=1 ./deploy.sh`. Currently `pos.aws.cswine.cloud`.

## Tear down

Terminate the instance, release the Elastic IP, delete the security group and key pair (all tagged `app=pos1`).
