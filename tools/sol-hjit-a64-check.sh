#!/bin/sh
# sol-hjit-a64-check.sh -- prove the A64 backend of the hand-rolled JIT
# from an x86-64 host: run the tier's test programs with the cross-check
# dump on, build tools/hjrun.c for aarch64, and replay every dumped case
# through the A64 blob under qemu-user.  Also replays the host blobs
# through the natively built harness (the harness's own sanity check).
# Skips (exit 0, says so) when the cross tools are absent.
set -eu

cd "$(dirname "$0")/.."

if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || ! command -v qemu-aarch64 >/dev/null 2>&1; then
  echo "hjit a64 check: skipped (needs aarch64-linux-gnu-gcc + qemu-aarch64)"
  exit 0
fi
if [ "$(uname -m)" != x86_64 ]; then
  echo "hjit a64 check: skipped (cross-check is written for an x86-64 host)"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/sol-hjx.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

gcc -O1 -o "$work/hjrun-host" tools/hjrun.c
aarch64-linux-gnu-gcc -O1 -static -o "$work/hjrun-a64" tools/hjrun.c

cat >"$work/mixed.sol" <<'SOL'
sq x = x * x.
half x = x / 2.
big x = x > 5000.
plus a b = a + b.
mixf acc x = acc * 0.5 + x.
rnd x = Num.round (x * 3.7) + Num.floor (x / 3).
step x | x > 500 = x * 3 - 7 .
step x = x / 2 + 1 .
fill : unsafe Vector -> Int -> Int -> Vector .
fill v i lim | i > lim = v.
fill v i lim = fill (Vec.push (i * 13) v) (i + 1) lim.
> xs = List.range 1 3000;
  u1 = print "map: {List.sum (List.map sq xs)}";
  u2 = print "filter: {List.len (List.filter big xs)}";
  u3 = print "foldf: {List.fold mixf 0.25 (List.map half xs)}";
  u4 = print "rnd: {List.sum (List.map rnd xs)}";
  v = fill (Vec.new Unit) 1 3000;
  w = Vec.map step v;
  (s, w2) = Vec.fold plus 0 w;
  u5 = print "vec: {s}";
  Vec.free w2 .
# LAST: integer division by zero inside a kernel poisons the fuel cell and
# the VM panics on return -- the case is dumped first, so both ISAs must
# agree on the poisoned outputs too (the run's exit is nonzero: expected)
divz x = 100 / (x - 130).   # 13 * 10 = 130: exactly one zero divisor
> zs = fill (Vec.new Unit) 1 100; ws = Vec.map divz zs; (t, ws2) = Vec.fold plus 0 ws; u = print "never {t}"; Vec.free ws2 .
SOL

export SOL_HJIT_XCHECK="$work" SOL_GPU=0
(cd sol/examples && ../../fpr sol dispatch.sol >/dev/null 2>&1 && ../../fpr sol handint.sol >/dev/null 2>&1 && ../../fpr sol mlpipe.sol >/dev/null 2>&1)
./fpr sol "$work/mixed.sol" >"$work/mixed.out" 2>&1 || true
grep -q "SOL PANIC: division by zero" "$work/mixed.out"
unset SOL_HJIT_XCHECK

cases=0; okA=0; okH=0
for c in "$work"/*.case; do
  sym=$(basename "$c" | cut -d. -f1)
  cases=$((cases + 1))
  if "$work/hjrun-host" "$work/$sym.x86-64.bin" "$c" >/dev/null; then okH=$((okH + 1)); else echo "host replay FAILED: $c"; fi
  if qemu-aarch64 "$work/hjrun-a64" "$work/$sym.a64.bin" "$c" >"$work/a64.out" 2>&1; then okA=$((okA + 1)); else cat "$work/a64.out"; fi
done
kinds=$(for c in "$work"/*.case; do od -An -j8 -N8 -td8 "$c"; done | tr -d ' ' | sort | uniq -c | awk '{printf "%s x%s ", ($2==0?"list-map/filter":$2==1?"list-fold":$2==2?"vec-map/filter":$2==3?"vec-fold":"vecmapr"), $1}')
echo "hjit a64 check: $cases case(s) [$kinds] host replay $okH/$cases, A64 under qemu $okA/$cases"
[ "$okA" -eq "$cases" ] && [ "$okH" -eq "$cases" ] && [ "$cases" -ge 10 ]
