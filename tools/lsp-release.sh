#!/bin/sh
# Run from any directory. Publishing is explicit; package never uploads.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "${1:-}" in
  package|publish) ;;
  --help|-h) exec node "$root/lsp/tools/release.js" --help ;;
  *) echo 'Usage: tools/lsp-release.sh package|publish [--dry-run]' >&2; exit 2 ;;
esac
if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != --dry-run ]; }; then
  echo 'Unexpected release arguments (use --help)' >&2; exit 2
fi
cd "$root/lsp"
npm ci --ignore-scripts --no-audit --no-fund
exec node tools/release.js "$@"
