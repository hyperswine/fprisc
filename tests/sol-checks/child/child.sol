# Child: a process on pipes (sol-bytes check). Write, expect, read, exit status;
# a timeout terminates; end of output is an Err; a missing program is an Err.
>! c = unwrap (Child.open ["sh","-c","read line; echo got:$line; echo second; exit 7"]);
   (w, c2) = Child.write (unwrap (Utf8.encode "hello\n")) c;
   (a, c3) = Child.expect "\n" 3000 c2;
   (b, c4) = Child.read 100 3000 c3;
   _ = print (Utf8.decodeReplace (unwrap a), Utf8.decodeReplace (unwrap b));
   print (Child.wait 2000 c4).
>! c = unwrap (Child.open ["sleep","30"]);
   print (Child.wait 300 c).
>! c = unwrap (Child.open ["true"]);
   (r, c2) = Child.read 10 2000 c;
   _ = print r;
   print (Child.wait 1000 c2).
>! print (Child.open ["no-such-program-xyz"] |> (fn r -> case r of Ok c -> _ = Child.kill c; "ok?" | Err e -> e)).
