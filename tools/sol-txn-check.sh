#!/bin/sh
# sol-txn-check.sh -- the transactional properties that need a HARNESS:
# panic rolls back everything, forced retries run deferred effects once,
# concurrent writers serialize, a failed deferred command fences the rest.
set -eu

cd "$(dirname "$0")/.."

cleanup() {
  rm -f /tmp/sol-txn-a.txt /tmp/sol-txn-b.txt /tmp/sol-txn-q.log \
    /tmp/sol-txn-ctr.txt /tmp/sol-txn-shq.log /tmp/sol-txn-ac.log /tmp/sol-txn-sh.log \
    /tmp/sol-txn-race.txt /tmp/sol-txn-f1.txt /tmp/sol-txn-f2.log \
    /tmp/sol-txn-*.out
}
trap cleanup EXIT INT TERM
cleanup

# 1. panic after buffered writes + a queued command: NOTHING lands
if ./fpr sol tests/txnpanic.sol >/tmp/sol-txn-panic.out 2>&1; then
  echo "txnpanic: a panicking script exited 0" >&2; exit 1
fi
grep -Fq 'SOL PANIC' /tmp/sol-txn-panic.out
[ ! -e /tmp/sol-txn-a.txt ] && [ ! -e /tmp/sol-txn-b.txt ] && [ ! -e /tmp/sol-txn-q.log ]

# 2. forced retries: file write + shq + afterCommit land ONCE; `sh` runs per attempt
SOL_FORCE_RETRY=2 ./fpr sol tests/txnretry.sol >/tmp/sol-txn-retry.out 2>&1
[ "$(cat /tmp/sol-txn-ctr.txt)" = 1 ]
[ "$(cat /tmp/sol-txn-shq.log)" = q ]
[ "$(cat /tmp/sol-txn-ac.log)" = p ]
[ "$(cat /tmp/sol-txn-sh.log)" = iii ]
[ "$(grep -c '^attempt saw 0$' /tmp/sol-txn-retry.out)" -eq 3 ]

# 3. two concurrent writers on one counter: the loser retries, both land
printf 0 > /tmp/sol-txn-race.txt
./fpr sol tests/txnrace.sol >/tmp/sol-txn-race1.out 2>&1 &
./fpr sol tests/txnrace.sol >/tmp/sol-txn-race2.out 2>&1
wait
[ "$(cat /tmp/sol-txn-race.txt)" = 2 ]
cat /tmp/sol-txn-race1.out /tmp/sol-txn-race2.out | grep -Fq 'conflict on'

# 4. a failed deferred command: files applied, later commands fenced, honest receipt, rc != 0
if ./fpr sol tests/txnshqfail.sol >/tmp/sol-txn-shqfail.out 2>&1; then
  echo "txnshqfail: a failed deferred command exited 0" >&2; exit 1
fi
grep -Fq 'NOT atomic' /tmp/sol-txn-shqfail.out
grep -Fq 'skipping queued command' /tmp/sol-txn-shqfail.out
[ "$(cat /tmp/sol-txn-f1.txt)" = 'file effect' ]
[ ! -e /tmp/sol-txn-f2.log ]

# 5. the single-run executable specs
./fpr sol sol/examples/txn_iso.sol >/tmp/sol-txn-iso.out 2>&1
grep -Fq 'txn_iso: OK' /tmp/sol-txn-iso.out
./fpr sol sol/examples/railway.sol >/tmp/sol-txn-railway.out 2>&1
grep -Fq 'railway: OK' /tmp/sol-txn-railway.out
./fpr sol sol/examples/strings.sol >/tmp/sol-txn-strings.out 2>&1
grep -Fq 'strings: OK' /tmp/sol-txn-strings.out
rm -rf /tmp/sol-procs-repo
./fpr sol sol/examples/procs.sol >/tmp/sol-txn-procs.out 2>&1
grep -Fq 'procs: OK' /tmp/sol-txn-procs.out
grep -Fq 'committed 0 file(s) + 3 deferred command(s) atomically' /tmp/sol-txn-procs.out
rm -rf /tmp/sol-procs-repo /tmp/sol-procs-order.txt

echo "sol transactional properties: panic rollback, retry-once, race serialization, fenced commands: OK"
