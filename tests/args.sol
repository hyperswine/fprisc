# Command-line arguments are structured values: the shell has already split
# argv, and Sol receives each trailing argument unchanged and in order.
check xs = case xs of
  a :: b :: c :: [] -> and (a == "a b") (and (b == "c*d") (c == ""))
| _ -> False.

> case check (args Unit) of
    True -> print "args: OK"
  | False -> error "args: wrong values or order".
