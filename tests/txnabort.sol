# txnabort.sol — pins the script-as-transaction contract: phase one
# writes, phase two panics, NOTHING may land.  See docs/TRANSACTION.md.
boom x | x > 0 = x / 0 .
boom x = x .
> h = open @/tmp/sol-txnabort.txt;
  h2 = writeAll h "must never exist";
  close h2 .
> boom 1 .
