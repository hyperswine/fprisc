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
SOL_VERBOSE=1 ./fpr sol sol/examples/procs.sol >/tmp/sol-txn-procs.out 2>&1
grep -Fq 'procs: OK' /tmp/sol-txn-procs.out
grep -Fq 'committed 0 file(s) + 3 deferred command(s) (file transaction committed; external commands are not atomic)' /tmp/sol-txn-procs.out
rm -rf /tmp/sol-procs-repo /tmp/sol-procs-order.txt

# 6. G2: a removal that cannot reach its goal state fails the run
W=$(mktemp -d /tmp/sol-txn-g.XXXXXX)
mkdir "$W/full"; echo x >"$W/full/f"
printf '> u = rmdir @%s/full; print "queued".\n' "$W" >"$W/g2.sol"
if ./fpr sol "$W/g2.sol" >"$W/g2.out" 2>&1; then
  echo "G2: an rmdir of a non-empty directory exited 0" >&2; exit 1
fi
grep -Fq 'effect FAILED' "$W/g2.out"
[ -e "$W/full/f" ]

# 7. G1: a replay that fails after the journal keeps the locks; the next
# contender redoes it, so no committed result mixes old and new files
echo A1 >"$W/a"; echo B1 >"$W/b"
printf '> u1 = writePath @%s/a "A2"; u2 = writePath @%s/b "B2"; print "queued".\n' "$W" "$W" >"$W/w.sol"
printf '> x = readPath @%s/a; y = readPath @%s/b; u = writePath @%s/c "{x}{y}"; print "read {x}{y}".\n' "$W" "$W" "$W" >"$W/r.sol"
mkdir "$W/b.sol-tmp" # the second write of the replay fails
if ./fpr sol "$W/w.sol" >"$W/g1w.out" 2>&1; then
  echo "G1: a failed replay exited 0" >&2; exit 1
fi
grep -Fq 'keeping the locks' "$W/g1w.out"
[ -d "$W/a.sol-lock" ] && [ -d "$W/b.sol-lock" ]
rmdir "$W/b.sol-tmp"
./fpr sol "$W/r.sol" >"$W/g1r.out" 2>&1
grep -Fq 'recovering interrupted commit' "$W/g1r.out"
[ "$(cat "$W/c")" = A2B2 ] && [ "$(cat "$W/b")" = B2 ]

# 8. G3: one journal per run. Run one is alive mid-commit (inside a
# deferred sleep) while run two of the same script commits; run one is
# then killed, and the next start redoes run one's journal
printf 'pick as = case as of [x] -> x | _ -> "none".\nhold n = if n == "one" then "sleep 3" else ":".\n> n = pick (args Unit); u0 = shq (hold n); u = writePath "%s/{n}.txt" "done {n}"; print "run {n}".\n' "$W" >"$W/s.sol"
./fpr sol "$W/s.sol" one >"$W/g3one.out" 2>&1 &
one=$!
sleep 1.5
./fpr sol "$W/s.sol" two >"$W/g3two.out" 2>&1
[ "$(cat "$W/two.txt")" = 'done two' ]
kill -9 "$one"; wait "$one" 2>/dev/null || true
[ ! -e "$W/one.txt" ]
./fpr sol "$W/s.sol" three >"$W/g3three.out" 2>&1
grep -Fq 'recovering interrupted commit' "$W/g3three.out"
[ "$(cat "$W/one.txt")" = 'done one' ]
# 9. G4: print is direct (once per attempt), log is transactional (once
# per committed run, never for a run that panics or fails its commit)
printf '> u = writePath @%s/f "x"; u1 = print "progress"; u2 = log "wrote f"; print "end".\n' "$W" >"$W/g4.sol"
SOL_FORCE_RETRY=2 ./fpr sol "$W/g4.sol" >"$W/g4.out" 2>/dev/null
[ "$(grep -c '^progress$' "$W/g4.out")" -eq 3 ] && [ "$(grep -c '^wrote f$' "$W/g4.out")" -eq 1 ]
[ "$(tail -1 "$W/g4.out")" = 'wrote f' ]
printf '> u1 = log "about to fail"; u = writePath @%s/g "x"; x = 1 / 0; print "no".\n' "$W" >"$W/g4p.sol"
if ./fpr sol "$W/g4p.sol" >"$W/g4p.out" 2>&1; then
  echo "G4: a panicking script exited 0" >&2; exit 1
fi
! grep -Fq 'about to fail' "$W/g4p.out"
rm -rf "$W"

echo "sol transactional properties: panic rollback, retry-once, race serialization, fenced commands, failed removals, torn-replay fencing, per-run journals, transactional log: OK"
