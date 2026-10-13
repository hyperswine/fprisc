#!/bin/sh
# Build, copy and install POS v1 + Caddy + Alloy on the instance.
#   ./deploy.sh            build and deploy
#   SKIP_BUILD=1 ./deploy.sh
# Extra public names (e.g. once pos.cswine.cloud points at the Elastic IP):
#   EXTRA_HOSTS=pos.cswine.cloud ./deploy.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/state.env"
[ -n "${SKIP_BUILD:-}" ] || "$here/build.sh"
hosts="$POS1_HOSTS${EXTRA_HOSTS:+, $EXTRA_HOSTS}"
ssh_="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new ec2-user@$PUBLIC_IP"
$ssh_ 'rm -rf /tmp/pos1-deploy && mkdir -p /tmp/pos1-deploy'
scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$here/out/pos1" "$here"/server/* "ec2-user@$PUBLIC_IP:/tmp/pos1-deploy/"
$ssh_ "sudo POS1_HOSTS='$hosts' sh /tmp/pos1-deploy/install.sh"
echo "https://$POS1_HOSTS/"
