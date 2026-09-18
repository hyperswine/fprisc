# under forced retries: deferred effects land exactly once, the immediate
# `sh` door runs once PER ATTEMPT (the documented hazard)
> n = parseInt (readPathOr "0" @/tmp/sol-txn-ctr.txt);
  u1 = writePath @/tmp/sol-txn-ctr.txt "{n + 1}";
  u2 = shq "printf q >> /tmp/sol-txn-shq.log";
  u3 = Proc.afterCommit (ProcessSpec ["/bin/sh", "-c", "printf p >> /tmp/sol-txn-ac.log"] "" [] "" 2000);
  (c, o) = sh "printf i >> /tmp/sol-txn-sh.log";
  print "attempt saw {n}".
