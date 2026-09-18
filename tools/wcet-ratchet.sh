#!/bin/sh

# wcet-ratchet.sh <prog.fpr> <ceiling> [target] -- the WCET regression gate.
#
# Layer-2 WCET (Codegen.wcetAnnotate) stamps every emitted function with
# `# wcet: <fn> segmax=<N> ...` -- the max IR-instruction distance between
# safepoints, deterministic per target. This gate computes
# the PROGRAM max over the root emission plus every linked unit (read from
# the <out>.units list, so cache state does not matter) and fails when it
# exceeds the recorded ceiling -- the same shape as the heap-delta
# witnesses: a number the tree must consciously bump, never drift past.
#
#   exit 0  max <= ceiling          (prints "wcet ratchet holds: N <= C")
#   exit 1  max >  ceiling, or any function reports UNBOUNDED, or the
#           compile itself failed


set -e
PROG="$1"
CEIL="$2"
TARGET="${3:-rv64}"
[ -n "$PROG" ] && [ -n "$CEIL" ] || { echo "usage: wcet-ratchet.sh <prog.fpr> <ceiling> [target]"; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUTD="$(mktemp -d)"
trap 'rm -rf "$OUTD"' EXIT
OUT="$OUTD/prog.s"

if ! LC_ALL=C.UTF-8 "$HERE/fprc" --target="$TARGET" --prelude="$HERE/core/prelude.fpr" "$PROG" "$OUT" >"$OUTD/log" 2>&1; then
  echo "wcet ratchet: compile FAILED for $PROG"; tail -5 "$OUTD/log"; exit 1
fi

# root + every unit the link would include
FILES="$OUT"
[ -f "$OUT.units" ] && FILES="$FILES $(cat "$OUT.units")"

if grep -h "^# wcet: " $FILES | grep -q "UNBOUNDED"; then
  echo "wcet ratchet: UNBOUNDED segment reported:"
  grep -h "^# wcet: " $FILES | grep "UNBOUNDED"
  exit 1
fi

MAX=$(grep -h "^# wcet: " $FILES \
  | sed -n 's/.*segmax=\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1)
[ -n "$MAX" ] || { echo "wcet ratchet: no wcet annotations found"; exit 1; }

if [ "$MAX" -gt "$CEIL" ]; then
  echo "wcet ratchet: REGRESSION -- program max $MAX > ceiling $CEIL ($TARGET)"
  echo "  worst functions:"
  grep -h "^# wcet: " $FILES | sed 's/^# wcet: //' \
    | sort -t= -k2 -rn | head -5 | sed 's/^/    /'
  echo "  (a deliberate latency change bumps the ceiling in check-all.sh)"
  exit 1
fi
echo "wcet ratchet holds: program max $MAX <= ceiling $CEIL IR insns between safepoints ($TARGET, $(basename "$PROG"))"
