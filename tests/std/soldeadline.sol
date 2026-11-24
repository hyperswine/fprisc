# Sol profile: the deadline receives and std/actor deadline calls (manual: fpr sol tests/std/soldeadline.sol).
AC = use "std/actor".
waiter self = _ = receive self; _ = receive self; Unit.
later self = (to, ms, v) = receive self; _ = Sys.sleepUs (ms * 1000); _ = send to v; Unit.
main =
  me = myself 0;
  target = spawn waiter;
  t0 = Sys.uptimeMs Unit;
  _ = print (receiveFromUntil me target (t0 + 30));
  _ = print (Sys.uptimeMs Unit - t0 >= 29);
  _ = print (receiveUntil me 0);
  _ = send me 9;
  _ = print (receiveUntil me 0);
  l = spawn later;
  _ = send l (me, 10, 7);
  _ = print (receiveFromUntil me l (Sys.uptimeMs Unit + 5000));
  _ = print (AC.callWithin 10 me target 7);
  _ = kill target;
  print (receiveFromUntil me target (Sys.uptimeMs Unit + 5000)).
