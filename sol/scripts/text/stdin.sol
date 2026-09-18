# stdin.sol -- a filter in a pipe: all of stdin, the lines with the needle
#   cat FILE | fpr sol sol/scripts/text/stdin.sol NEEDLE
execute argv = case argv of
    needle :: [] -> u = map (fn l -> print l) (List.filter (Str.contains needle) (Str.lines (input Unit))); Unit
  | _ -> error "usage: ... | stdin.sol NEEDLE".
> execute (args Unit).
