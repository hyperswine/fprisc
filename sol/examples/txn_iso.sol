# txn_iso.sol -- what a transaction SEES, as an executable spec. Each `>`
# statement is one transaction: inside it, every read composes over its own
# buffered writes, and the disk is untouched until the statement commits.
# A later statement sees what earlier ones committed. The script cleans up
# after itself, so its last statement leaves the directory empty.
#
#   ./fpr sol sol/examples/txn_iso.sol
#   (docs/2026-11-26-SOL-PROGRESSIVE-COMMITS.md)

expect what got want = case got == want of
    True -> print "ok  {what}"
  | False -> error "FAIL {what}: got {got}, wanted {want}".

d = "/tmp/sol-txn-iso".

> u0 = shq "rm -rf {d}"; u = mkdirp d;
  expect "fresh dir is empty" (ls d) [].
> u = writePath "{d}/a.txt" "one";
  _ = expect "read-after-write" (readPath "{d}/a.txt") "one";
  u1 = writePath "{d}/a.txt" "two"; u2 = writePath "{d}/a.txt" "three";
  expect "newest write wins" (readPath "{d}/a.txt") "three".
>! u = writePath "{d}/c.txt" "pending";
  expect "disk untouched before the statement commits" (readNow "{d}/c.txt") "".
> expect "a later statement sees what earlier ones committed" (readPath "{d}/a.txt", readPath "{d}/c.txt") ("three", "pending").
> u = writePath "{d}/b.txt" "b";
  _ = expect "ls composes pending writes" (ls d) ["a.txt", "b.txt", "c.txt"];
  expect "exists sees pending" (exists "{d}/b.txt", exists "{d}/zz.txt") (True, False).
> u = rm "{d}/a.txt";
  _ = expect "rm is visible" (ls d) ["b.txt", "c.txt"];
  expect "Try.readPath after rm" (isOk (Try.readPath "{d}/a.txt")) False.
> u = rm "{d}/b.txt"; u2 = rm "{d}/c.txt"; expect "net no-op" (ls d) [].
> print "txn_iso: OK".
