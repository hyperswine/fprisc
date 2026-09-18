# grep.sol -- lines containing a needle, with their numbers (grep -n)
#   fpr sol sol/scripts/text/grep.sol ERROR sol/scripts/text/sample.log
show needle (i, line) = case Str.contains needle line of
    True -> print "{i}: {line}"
  | False -> Unit.
numbered ls = List.zip (List.range 1 (List.len ls)) ls.
execute argv = case argv of
    needle :: path :: [] -> u = map (show needle) (numbered (Str.lines (readPath path))); Unit
  | _ -> error "usage: grep.sol NEEDLE FILE".
> execute (args Unit).
