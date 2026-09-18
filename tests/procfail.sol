# A failed deferred process makes the run fail and fences dependent commands.
> u1 = Proc.afterCommit (ProcessSpec ["/usr/bin/false"] "" [] "" 2000);
  u2 = Proc.afterCommit (ProcessSpec ["/usr/bin/touch", "/tmp/sol-proc-should-not-exist"] "" [] "" 2000);
  print "queued failure".
