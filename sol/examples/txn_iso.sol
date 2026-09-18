# txn_iso.sol -- what a transaction SEES, as an executable spec.  Every
# read composes over the buffered writes (your own effects are visible to
# you); the disk is untouched until commit (readNow proves it).  The
# script cleans up after itself so the commit is a net no-op.
#
#   ./fpr sol sol/examples/txn_iso.sol
#   (the panic/retry/race/failed-command properties live in
#    tools/sol-txn-check.sh: they need a harness, not a single run)

expect what got want = case got == want of
    True -> print "ok  {what}"
  | False -> error "FAIL {what}: got {got}, wanted {want}".

d = "/tmp/sol-txn-iso".

> u0 = shq "rm -rf {d}"; u = mkdirp d;
  expect "fresh dir is empty" (ls d) [].
> u = writePath "{d}/a.txt" "one";
  expect "read-after-write" (readPath "{d}/a.txt") "one".
> u1 = writePath "{d}/a.txt" "two"; u2 = writePath "{d}/a.txt" "three";
  expect "newest write wins" (readPath "{d}/a.txt") "three".
> expect "disk untouched before commit" (readNow "{d}/a.txt") "".
> u = writePath "{d}/b.txt" "b";
  expect "ls composes pending writes" (ls d) ["a.txt", "b.txt"].
> expect "exists sees pending" (exists "{d}/b.txt", exists "{d}/zz.txt") (True, False).
> u = rm "{d}/a.txt";
  expect "rm is visible" (ls d) ["b.txt"].
> expect "Try.readPath after rm" (isOk (Try.readPath "{d}/a.txt")) False.
> u = rm "{d}/b.txt"; expect "net no-op" (ls d) [].
> print "txn_iso: OK".
