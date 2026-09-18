#!/bin/sh
# dedup-ratchet.sh -- the frontend un-forking must not regress.
#
# Sol/Infer.hs is a PROFILE SHIM over the one engine (Infer.hs);
# Sol/Lang.hs still carries near-copies of FPRISC.hs's desugar /
# pattern-compile / lift / linearity passes, merged pair by pair.
# The ratchet is a ceiling on each file's size: every merge deletes
# lines, so growth means the fork is widening again.  Raising a
# ceiling is allowed -- as a conscious edit here, with a reason,
# never as drift.
set -e
cd "$(dirname "$0")/.."

ck() { # ck <file> <ceiling>
  n=$(wc -l < "$1")
  if [ "$n" -gt "$2" ]; then
    echo "dedup-ratchet: $1 grew to $n lines (ceiling $2) -- the fork is widening; merge into the shared module or raise the ceiling here with a reason"
    exit 1
  fi
  echo "  $1: $n <= $2"
}

ck compiler/Sol/Infer.hs 120   # the shim: sol's table + flags, nothing else
ck compiler/Sol/Lang.hs  240   # profile-only: tids, decode, splicing

echo "dedup-ratchet: OK"
