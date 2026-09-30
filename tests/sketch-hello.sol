# hello.fpr — the smallest QOSPortable process: pure compute + std,
# result returned as the rendered string through the table.
STD = use "../std/std.fpr".
Std = STD.Std.
main =
  s = Std.fold 1 10 (fn i acc -> acc + i) 0;
  c = Std.clamp 0 100 s;
  print "hello from a .qa: fold(1..10)={s} clamp={c}".
