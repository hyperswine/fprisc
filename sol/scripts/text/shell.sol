# shell.sol -- a tool's output as data: sizes and names out of ls -l (via sh)
#   fpr sol sol/scripts/text/shell.sol DIR
sizeOf line = Str.parse (Str.words line ! 5).
nameOf line = Str.words line ! 9.
big line = List.len (Str.words line) >= 9.
execute argv = case argv of
    dir :: [] -> (code, out) = sh "ls -l {dir}";
                 ls = List.filter big (Str.lines out);
                 u = map (fn l -> print "{sizeOf l} {nameOf l}") ls;
                 print "{List.len ls} entries, exit {code}"
  | _ -> error "usage: shell.sol DIR".
> execute (args Unit).
