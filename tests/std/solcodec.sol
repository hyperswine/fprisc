J = use "../../std/json".
Msg = Type (Bump Int | Move (Int, String) (List Int) | Clear).
codec = @Msg.
> print (J.encode codec (Move (3, "x") (1 :: 2 :: Nil))).
> print (J.decode codec "[\"Bump\", \"41\"]").
> print (J.decode codec "[\"Nope\"]").
