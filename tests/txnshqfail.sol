# a failed deferred command: file effects still apply, later commands are
# fenced, the receipt refuses the word "atomic", the exit code is nonzero
> u1 = writePath @/tmp/sol-txn-f1.txt "file effect"; u2 = shq "exit 7";
  u3 = shq "printf later >> /tmp/sol-txn-f2.log"; print "queued".
