#!/usr/bin/env bash
# Put inv.cswine.cloud on the Linode's nginx: an HTTP-only site first, so
# Let's Encrypt can answer its challenge from /var/www/inv-acme, then the TLS
# site from nginx/.  Renewal is certbot's own timer (webroot, as logbook's).
# Idempotent: a certificate that exists is not asked for again.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/state.env"

scp -q "$here/nginx/$DOMAIN" "$LINODE:/tmp/$DOMAIN.site"
ssh "$LINODE" DOMAIN="$DOMAIN" bash -s <<'EOF'
set -euo pipefail
site=/etc/nginx/sites-available/$DOMAIN
mkdir -p /var/www/inv-acme
if [ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
  cat > "$site" <<HTTP
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/inv-acme; }
    location / { return 404; }
}
HTTP
  ln -sf "$site" /etc/nginx/sites-enabled/$DOMAIN
  nginx -t && systemctl reload nginx
  certbot certonly --webroot -w /var/www/inv-acme -d "$DOMAIN" --non-interactive --keep-until-expiring
fi
mv /tmp/$DOMAIN.site "$site"
ln -sf "$site" /etc/nginx/sites-enabled/$DOMAIN
nginx -t && systemctl reload nginx
echo "nginx: $DOMAIN -> $(grep -m1 proxy_pass "$site")"
EOF
