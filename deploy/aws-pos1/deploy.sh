#!/bin/sh
# Build, copy and install POS v1 + Caddy + Alloy on the instance.
#   ./deploy.sh            build and deploy
#   SKIP_BUILD=1 ./deploy.sh
# Extra public names (a domain pointed at the Elastic IP) come from EXTRA_HOSTS,
# in state.env or the environment; they go first, so the public probe uses them:
#   echo EXTRA_HOSTS=pos.example.com >> state.env
set -eu
here=$(cd "$(dirname "$0")" && pwd)
extra=${EXTRA_HOSTS:-}
. "$here/state.env"
EXTRA_HOSTS=${extra:-${EXTRA_HOSTS:-}}
[ -n "${SKIP_BUILD:-}" ] || "$here/build.sh"
hosts="${EXTRA_HOSTS:+$EXTRA_HOSTS, }$POS1_HOSTS"
ssh_="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new ec2-user@$PUBLIC_IP"
$ssh_ 'rm -rf /tmp/pos1-deploy && mkdir -p /tmp/pos1-deploy'
scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$here/out/pos1" "$here"/server/* "ec2-user@$PUBLIC_IP:/tmp/pos1-deploy/"
$ssh_ "sudo POS1_HOSTS='$hosts' sh /tmp/pos1-deploy/install.sh"
echo "https://${EXTRA_HOSTS:-$POS1_HOSTS}/" | cut -d, -f1
