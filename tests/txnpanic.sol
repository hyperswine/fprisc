# a panic AFTER buffering writes and queuing a command must commit NOTHING
> u1 = writePath @/tmp/sol-txn-a.txt "A"; u2 = writePath @/tmp/sol-txn-b.txt "B";
  u3 = shq "printf q >> /tmp/sol-txn-q.log"; u4 = print "buffered";
  x = parseInt "boom"; print "unreachable {x}".
