# sed.sol -- a line range, a global substitution, delete-matching (sed -n p / s / d)
#   fpr sol sol/scripts/text/sed.sol p 3 5 FILE | s OLD NEW FILE | d PAT FILE
sliceLines from to ls = List.take (to - from + 1) (List.drop (from - 1) ls).
dropMatch pat line = not (Str.contains pat line).
execute argv = case argv of
    "p" :: a :: b :: path :: [] -> u = map print (sliceLines (Str.parse a) (Str.parse b) (Str.lines (readPath path))); Unit
  | "s" :: old :: new :: path :: [] -> u = map print (List.map (Str.replace old new) (Str.lines (readPath path))); Unit
  | "d" :: pat :: path :: [] -> u = map print (List.filter (dropMatch pat) (Str.lines (readPath path))); Unit
  | _ -> error "usage: sed.sol p FROM TO FILE | s OLD NEW FILE | d PAT FILE".
> execute (args Unit).
