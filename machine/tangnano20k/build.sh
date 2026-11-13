#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
exec "${SOL:-sol}" machine/tangnano20k/build.sol "$@"
