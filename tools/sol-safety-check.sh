#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

cleanup() {
  rm -rf "${lock_dir:-}" /tmp/sol-fs-loop /tmp/sol-fs-loop-test.sol \
    /tmp/sol-table-purity.sol /tmp/sol-actor-retry.sol /tmp/sol-actor-cancel.sol \
    /tmp/sol-lock-target /tmp/sol-lock-target.sol-lock /tmp/sol-old-actor-leak
}
trap cleanup EXIT INT TERM

cat >/tmp/sol-table-purity.sol <<'EOF'
emit x = print "effect-{x}".
> a = emit 7; b = emit 7; print "done".
EOF
SOL_TABLE_MIN=0 ./fpr sol /tmp/sol-table-purity.sol >/tmp/sol-table-purity.out 2>&1
[ "$(grep -c '^effect-7$' /tmp/sol-table-purity.out)" -eq 2 ]
SOL_TABLE_STATS=1 ./fpr sol sol/examples/tabling.sol >/tmp/sol-table-valid.out 2>&1
grep -Fq 'tabling: fib 27 = 196418 / again = 196418' /tmp/sol-table-valid.out
grep -Fq '[table] fib:' /tmp/sol-table-valid.out

rm -f /tmp/sol-fs-loop
ln -s /tmp/sol-fs-loop /tmp/sol-fs-loop
cat >/tmp/sol-fs-loop-test.sol <<'EOF'
> r = Try.readPath @/tmp/sol-fs-loop; print "{r}".
EOF
./fpr sol /tmp/sol-fs-loop-test.sol >/tmp/sol-fs-loop.out 2>&1
grep -Fq 'Err readPath:' /tmp/sol-fs-loop.out
grep -Eqi 'too many levels|symbolic link' /tmp/sol-fs-loop.out
! grep -Fq 'no such file' /tmp/sol-fs-loop.out

lock_dir=$(mktemp -d /tmp/sol-lock-test.XXXXXX)
cat >"$lock_dir/fail.sol" <<'EOF'
> u = writePath @/tmp/sol-lock-target "x"; print "queued".
EOF
mkdir "$lock_dir/fail.soljournal"
if ./fpr sol "$lock_dir/fail.sol" >/tmp/sol-lock-fail.out 2>&1; then
  echo "journal failure unexpectedly succeeded" >&2
  exit 1
fi
[ ! -e /tmp/sol-lock-target.sol-lock ]
[ ! -e /tmp/sol-lock-target ]

cat >/tmp/sol-actor-retry.sol <<'EOF'
worker parent self =
  u1 = send parent self;
  u2 = send parent self;
  Unit.
> me = myself 0;
  child = spawn (worker me);
  got = receive me;
  print "actor retry: child={child} got={got}".
EOF
SOL_FORCE_RETRY=1 SOL_TABLE=0 ./fpr sol /tmp/sol-actor-retry.sol >/tmp/sol-actor-retry.out 2>&1
[ "$(grep -c '^actor retry: child=2 got=2$' /tmp/sol-actor-retry.out)" -eq 2 ]
! grep -Fq 'child=3' /tmp/sol-actor-retry.out

cat >/tmp/sol-actor-cancel.sol <<'EOF'
slow self = u = sleepMs 500; writePath @/tmp/sol-old-actor-leak "bad".
> child = spawn slow; print "spawned {child}".
EOF
rm -f /tmp/sol-old-actor-leak
./fpr sol /tmp/sol-actor-cancel.sol >/tmp/sol-actor-cancel.out 2>&1
grep -Fq 'cancelling them before the transaction boundary' /tmp/sol-actor-cancel.out
[ ! -e /tmp/sol-old-actor-leak ]

echo "sol purity + filesystem + locks + retry actors: OK"
