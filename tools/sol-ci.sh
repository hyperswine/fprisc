#!/bin/sh
# Run every Sol check suite against ./fpr (CI entry point).
# Skipped: sol-hjit-a64-check.sh (needs aarch64 cross tools + qemu-aarch64),
# sol-daily-check.py (needs explicit daily-script inputs; see SOL-INSTALLATION).
set -u
cd "$(dirname "$0")/.."
out=${SOL_CI_LOGS:-build/sol-ci}
mkdir -p "$out"
fail=0
for t in tools/sol-*-check.py tools/sol-*-check.sh; do
  n=$(basename "$t")
  case "$n" in
    sol-hjit-a64-check.sh|sol-daily-check.py) echo "SKIP $n"; continue ;;
  esac
  case "$n" in *.py) cmd="python3 -u $t" ;; *) cmd="sh $t" ;; esac
  start=$(date +%s)
  if $cmd >"$out/$n.log" 2>&1; then r=PASS; else r=FAIL; fail=1; fi
  echo "$r $n ($(( $(date +%s) - start ))s)"
  [ "$r" = FAIL ] && { echo "::group::$n log"; tail -n 80 "$out/$n.log"; echo "::endgroup::"; }
done
exit $fail
