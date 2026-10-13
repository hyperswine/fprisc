AC = use "std/actor".
waiter self = _ = receive self; _ = receive self; Unit.
main =
  me = myself 0;
  target = spawn waiter;
  _ = print (receiveFromNow me target);
  _ = print (AC.callWithin 10 me target 7);
  _ = kill target;
  print (receiveFromNow me target).
