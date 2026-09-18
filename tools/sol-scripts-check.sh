#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

work=$(mktemp -d "${TMPDIR:-/tmp}/sol-scripts.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

args_output=$(./fpr sol tests/args.sol 'a b' 'c*d' '' 2>&1)
printf '%s\n' "$args_output" | grep -Fq 'args: OK'

version_output=$(./fpr sol sol/scripts/version-compare.sol 2.10 2.9 2>&1)
printf '%s\n' "$version_output" | grep -Fq '2.10 > 2.9'
version_output=$(./fpr sol sol/scripts/version-compare.sol 1.2 1.2.0 2>&1)
printf '%s\n' "$version_output" | grep -Fq '1.2 == 1.2.0'
if ./fpr sol sol/scripts/version-compare.sol 1.bad 2 >"$work/version-bad.out" 2>&1; then
  echo 'invalid version returned success' >&2
  exit 1
fi
grep -Fq "invalid component 'bad'" "$work/version-bad.out"

printf 'Hello, FP-RISC!\nSECOND LINE\n' >"$work/mixed.txt"
./fpr sol sol/scripts/lowercase.sol "$work/mixed.txt" "$work/lower.txt" >"$work/lower.out" 2>&1
printf 'hello, fp-risc!\nsecond line\n' >"$work/expected.txt"
cmp "$work/expected.txt" "$work/lower.txt"
if ./fpr sol sol/scripts/lowercase.sol "$work/missing.txt" "$work/leaked.txt" >"$work/lower-bad.out" 2>&1; then
  echo 'missing lowercase input returned success' >&2
  exit 1
fi
[ ! -e "$work/leaked.txt" ]

./fpr sol sol/scripts/system-report.sol "$work/report.txt" >"$work/report.out" 2>&1
grep -Fq 'Operating system' "$work/report.txt"
grep -Fq 'Disk usage' "$work/report.txt"
grep -Fq 'Processes' "$work/report.txt"

./fpr sol sol/scripts/archive.sol sol/lib/proc.sol "$work/proc.tar.gz" >"$work/archive.out" 2>&1
tar -tzf "$work/proc.tar.gz" | grep -Fq 'sol/lib/proc.sol'
./fpr sol sol/scripts/archive.sol sol/lib/proc.sol "$work/proc.tar.gz" >"$work/archive-repeat.out" 2>&1
tar -tzf "$work/proc.tar.gz" | grep -Fq 'sol/lib/proc.sol'
if ./fpr sol sol/scripts/archive.sol "$work/missing" "$work/leaked.tar.gz" >"$work/archive-bad.out" 2>&1; then
  echo 'missing archive source returned success' >&2
  exit 1
fi
[ ! -e "$work/leaked.tar.gz" ]

echo 'sol general-purpose scripts: OK'