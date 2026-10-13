#!/usr/bin/env bash
# Add a household member (or give one a new password) on the Mac mini, then
# restart the server so it reads the new line.  The password is read without
# echo and goes over ssh's stdin, so it is in no shell history and no argv.
#
#   ./add-member.sh NAME
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/state.env"
name="${1:?usage: add-member.sh NAME}"

read -rsp "password for $name (8 or more characters): " pw; echo
read -rsp "again: " pw2; echo
[ "$pw" = "$pw2" ] || { echo "the two did not match" >&2; exit 1; }

printf '%s\n' "$pw" | ssh "$MINI" bash -c "'
  set -euo pipefail
  IFS= read -r INV_PASSWORD; export INV_PASSWORD
  cd ~/inventory
  ./inventory --store=inventory.log --member=$name
  launchctl kickstart -k gui/\$(id -u)/cloud.cswine.inventory
'"
