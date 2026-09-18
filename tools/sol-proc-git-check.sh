#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

rm -f /tmp/sol-proc-defer.count /tmp/sol-proc-should-not-exist
query_output=$(./fpr sol tests/procquery.sol 2>&1)
printf '%s\n' "$query_output" | grep -Fq 'code=0 out=[space arg:stdin] err=[err]'
printf '%s\n' "$query_output" | grep -Fq 'timed out after 10ms'

SOL_FORCE_RETRY=1 ./fpr sol tests/procdefer.sol >/tmp/sol-proc-defer.out 2>&1
[ "$(cat /tmp/sol-proc-defer.count)" = x ]

if ./fpr sol tests/procfail.sol >/tmp/sol-proc-fail.out 2>&1; then
  echo "deferred process failure returned success" >&2
  exit 1
fi
[ ! -e /tmp/sol-proc-should-not-exist ]
grep -Fq 'deferred process FAILED (exit 1)' /tmp/sol-proc-fail.out
grep -Fq 'skipping queued process' /tmp/sol-proc-fail.out

rm -f /tmp/sol-proc-order.log
order_output=$(./fpr sol tests/procorder.sol 2>&1)
printf '%s\n' "$order_output" | grep -Fq 'runNow: Err'
printf '%s\n' "$order_output" | grep -Fq 'queued effect(s) that only happen at commit'
# the immediate process was refused; the queued one still committed
[ "$(cat /tmp/sol-proc-order.log)" = queued ]

rm -rf /tmp/sol-git-wrap /tmp/sol-git-remote.git
mkdir -p /tmp/sol-git-wrap
printf '%s\n' 'hello from sol' > /tmp/sol-git-wrap/hello.txt
./fpr sol tests/gitwrap.sol >/tmp/sol-git-wrap.out 2>&1
[ "$(git -C /tmp/sol-git-wrap log -1 --format=%s)" = 'first commit' ]
git -C /tmp/sol-git-wrap show-ref --verify --quiet refs/heads/feature
git -C /tmp/sol-git-wrap show-ref --verify --quiet refs/tags/v1

query_output=$(./fpr sol tests/gitquery.sol 2>&1)
printf '%s\n' "$query_output" | grep -Fq 'status: Ok [# branch.oid'
printf '%s\n' "$query_output" | grep -Fq 'first commit'

printf '%s\n' second > /tmp/sol-git-wrap/second.txt
./fpr sol tests/gitsecond.sol >/tmp/sol-git-second.out 2>&1
[ "$(git -C /tmp/sol-git-wrap rev-list --count HEAD)" = 2 ]
./fpr sol tests/gitundo.sol >/tmp/sol-git-undo.out 2>&1
[ "$(git -C /tmp/sol-git-wrap rev-list --count HEAD)" = 1 ]
! git -C /tmp/sol-git-wrap show-ref --verify --quiet refs/heads/feature
! git -C /tmp/sol-git-wrap show-ref --verify --quiet refs/tags/v1
[ "$(git -C /tmp/sol-git-wrap status --porcelain -- second.txt)" = '?? second.txt' ]

git init --bare -q /tmp/sol-git-remote.git
git -C /tmp/sol-git-wrap remote add origin /tmp/sol-git-remote.git
push_output=$(./fpr sol tests/gitpush.sol 2>&1)
printf '%s\n' "$push_output" | grep -Fq '[sol] REALTIME: Proc.runNow'
printf '%s\n' "$push_output" | grep -Fq 'push: Ok <'
[ "$(git -C /tmp/sol-git-wrap rev-parse main)" = "$(git --git-dir=/tmp/sol-git-remote.git rev-parse refs/heads/main)" ]

printf '%s\n' fourth > /tmp/sol-git-wrap/fourth.txt
remote_before=$(git --git-dir=/tmp/sol-git-remote.git rev-parse refs/heads/main)
order_push=$(./fpr sol tests/gitorder.sol 2>&1)
printf '%s\n' "$order_push" | grep -Fq 'push: Err'
# the queued commit landed locally; the stale push never reached the remote
[ "$(git -C /tmp/sol-git-wrap log -1 --format=%s)" = 'fourth commit' ]
[ "$(git --git-dir=/tmp/sol-git-remote.git rev-parse refs/heads/main)" = "$remote_before" ]

echo "sol structured process + git wrappers: OK"
