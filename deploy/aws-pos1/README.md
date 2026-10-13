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
| `server/set-grafana-cloud.sh` | instance | installed as `sudo set-grafana-cloud`: prompts for Grafana Cloud URLs, users and token |

Redeploy after changing pos1: `./deploy.sh`. SSH: `ssh -i ~/.ssh/pos1-key.pem ec2-user@<PUBLIC_IP>`.

## What Alloy collects

- **Host**: node_exporter metrics as `job="integrations/node_exporter", instance="pos1"`, so Grafana Cloud's Linux integration dashboards work.
- **Shop log as metrics**: `pos1_sales_total`, `pos1_revenue_cents_total`, `pos1_tax_cents_total` (labels `cashier`, `pay`=cash|card), `pos1_voids_total`, `pos1_restocked_units_total`. Derived from the append-only log, so pos1 itself is unchanged.
- **Shop log as logs**: `{job="pos1-shop"}` with a `kind` label. `staff` lines carry PINs and are dropped before shipping.
- **Caddy**: `caddy_http_*` request metrics. **Journald**: pos1, caddy, alloy, sshd as `{job="systemd-journal", unit=...}`.
- **Probes**: `probe_success{job="pos1-probe"}` for loopback and the public HTTPS URL.

Example queries: `sum(increase(pos1_revenue_cents_total[1d])) / 100`, `sum by (pay) (increase(pos1_sales_total[1h]))`.

## A custom domain

Add an `A` record (e.g. `pos.cswine.cloud`) for the Elastic IP, then `EXTRA_HOSTS=pos.cswine.cloud SKIP_BUILD=1 ./deploy.sh`.

## Tear down

Terminate the instance, release the Elastic IP, delete the security group and key pair (all tagged `app=pos1`).
