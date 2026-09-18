# SOL_FORCE_RETRY=1 discards the first plan. This append must occur once,
# after validation succeeds, rather than once per script attempt.
> u = Proc.afterCommit (ProcessSpec ["/bin/sh", "-c", "printf x >> /tmp/sol-proc-defer.count"] "" [] "" 2000);
  print "deferred".
