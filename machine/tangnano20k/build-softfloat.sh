#!/bin/sh
set -eu
case "${FPR_SOFTFLOAT_ROOT:-}" in ""|/*) ;; *) export FPR_SOFTFLOAT_ROOT="$PWD/$FPR_SOFTFLOAT_ROOT";; esac
cd "$(dirname "$0")/../.."
exec "${SOL:-sol}" machine/tangnano20k/build-softfloat.sol "$@"
