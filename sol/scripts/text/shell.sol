# Directory listing without shell interpolation or parsing ls display columns.
#   fpr sol sol/scripts/text/shell.sol DIR
p = use "../../../std/path.fpr".
showEntry dir name =
  full = p.join dir name;
  case isDir full of
    True -> print "dir {name}"
  | False -> (present, size, modified) = stat full; print "{size} {name}".
execute argv = case argv of
    dir :: [] -> (case isDir dir of
      False -> error "not a directory: {dir}"
    | True -> names = ls dir;
              u = map (showEntry dir) names;
              print "{List.len names} entries")
  | _ -> error "usage: shell.sol DIR".
> execute (args Unit).
