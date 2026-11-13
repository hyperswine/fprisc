#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
exec "${SOL:-sol}" deploy/aws-pos1/build.sol "$@"
