# The Sol half of the string parity (see strings.fpr).
s = "aé€😀z".
> _ = print "{strlen s} {charAt s 1} {charAt s 2} {charAt s 3} {charAt s 6}";
  _ = print "[{substr s 1 2}] [{substr s 3 3}] [{substr s 1 1}]";
  _ = print "{strlen (chr 233)} {charAt (chr 233) 0} {strlen (substr s 0 2)}";
  _ = print (chr 233);
  print (substr s 2 1).
