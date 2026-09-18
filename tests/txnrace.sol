# two of these run concurrently on one counter: the loser must retry
> n = parseInt (readPath @/tmp/sol-txn-race.txt); u = sleepMs 300;
  u2 = writePath @/tmp/sol-txn-race.txt "{n + 1}"; print "wrote {n + 1}".
