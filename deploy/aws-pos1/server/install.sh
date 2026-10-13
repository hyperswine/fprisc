#!/bin/sh
# Runs ON the instance as root (deploy.sh calls it).  Idempotent.
#   POS1_HOSTS="1-2-3-4.sslip.io[, pos.example.com]"
set -eu
src=$(cd "$(dirname "$0")" && pwd)
: "${POS1_HOSTS:?POS1_HOSTS is required}"
CADDY_VERSION=${CADDY_VERSION:-2.11.7}

id pos1  >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pos1  --shell /sbin/nologin pos1
id caddy >/dev/null 2>&1 || useradd --system --home-dir /var/lib/caddy --shell /sbin/nologin caddy

# ---- pos1
install -d -m 0755 /opt/pos1
install -m 0755 "$src/pos1" /opt/pos1/pos1.new && mv -f /opt/pos1/pos1.new /opt/pos1/pos1
install -m 0644 "$src/pos1.service" /etc/systemd/system/pos1.service

# ---- caddy: the release binary, checked against its published SHA-512
if ! /usr/local/bin/caddy version 2>/dev/null | grep -q "^v$CADDY_VERSION "; then
  t=$(mktemp -d)
  base=https://github.com/caddyserver/caddy/releases/download/v$CADDY_VERSION
  f=caddy_${CADDY_VERSION}_linux_arm64.tar.gz
  curl -fsSL -o "$t/$f" "$base/$f"
  curl -fsSL -o "$t/sums" "$base/caddy_${CADDY_VERSION}_checksums.txt"
  (cd "$t" && grep " $f\$" sums | sha512sum -c -)
  tar -xzf "$t/$f" -C "$t" caddy
  install -m 0755 "$t/caddy" /usr/local/bin/caddy
  rm -rf "$t"
fi
install -d -o caddy -g caddy -m 0750 /var/lib/caddy
install -d -m 0755 /etc/caddy
install -m 0644 "$src/Caddyfile" /etc/caddy/Caddyfile
printf 'POS1_HOSTS=%s\n' "$POS1_HOSTS" > /etc/caddy/caddy.env
install -m 0644 "$src/caddy.service" /etc/systemd/system/caddy.service
POS1_HOSTS="$POS1_HOSTS" /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

# ---- alloy, from Grafana's signed RPM repository
if ! rpm -q alloy >/dev/null 2>&1; then
  cat > /etc/yum.repos.d/grafana.repo <<REPO
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPO
  dnf -y -q install alloy
fi
usermod -aG pos1,systemd-journal alloy
install -m 0644 "$src/config.alloy" /etc/alloy/config.alloy
install -d /etc/systemd/system/alloy.service.d
install -m 0644 "$src/alloy-override.conf" /etc/systemd/system/alloy.service.d/override.conf
first=$(echo "$POS1_HOSTS" | cut -d, -f1 | tr -d ' ')
printf 'POS1_PUBLIC_URL=https://%s/\n' "$first" > /etc/alloy/pos1.env
[ -f /etc/alloy/grafana-cloud.env ] || install -m 0600 /dev/null /etc/alloy/grafana-cloud.env
install -m 0755 "$src/set-grafana-cloud.sh" /usr/local/sbin/set-grafana-cloud
/usr/bin/alloy fmt /etc/alloy/config.alloy >/dev/null

# ---- start
systemctl daemon-reload
systemctl enable -q pos1 caddy alloy
systemctl restart pos1
systemctl restart caddy
systemctl restart alloy
sleep 3
for u in pos1 caddy alloy; do printf '%-6s %s\n' "$u" "$(systemctl is-active $u)"; done
curl -fsS -o /dev/null -w 'pos1 loopback: HTTP %{http_code}\n' http://127.0.0.1:6710/
