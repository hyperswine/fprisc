# Queued effects only happen at commit, so an immediate process would run
# BEFORE them. Proc.runNow refuses while any effect is pending and names
# what is still queued; the transaction's own effects are unaffected.
> u = Proc.afterCommit (ProcessSpec ["/bin/sh", "-c", "printf queued >> /tmp/sol-proc-order.log"] "" [] "" 2000);
  r = Proc.runNow (ProcessSpec ["/bin/sh", "-c", "printf ranNow >> /tmp/sol-proc-order.log"] "" [] "" 2000);
  print "runNow: {r}".
