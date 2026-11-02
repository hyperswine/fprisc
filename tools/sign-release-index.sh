#!/bin/sh
# Sign exact index bytes; the private key path is explicit and never printed.
set -eu
if [ "$#" -lt 2 ]; then
  echo 'usage: sign-release-index.sh PRIVATE_KEY INDEX.json [...]' >&2
  exit 2
fi
release_key=$1
shift
for index in "$@"; do
  test -f "$index"
  signature_tmp=$(mktemp "${index}.sig.XXXXXX")
  trap 'rm -f "$signature_tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  /usr/bin/ssh-keygen -Y sign -f "$release_key" -n fprmeta-index < "$index" > "$signature_tmp"
  test -s "$signature_tmp"
  mv "$signature_tmp" "${index}.sig"
  trap - EXIT HUP INT TERM
done
