# awk.sol -- fields, a column sum, a group count (awk -F: over staff.txt)
#   fpr sol sol/scripts/text/awk.sol cols FILE | sum N FILE | count N FILE
fields line = Str.split 58 line.           # ':' is 58
# n is an awk field number ($1 is the first field), so 1-based by awk's
# convention; `!` is 0-based
field n line = fields line ! (n - 1).
sumCol n ls = List.sum (List.map (fn l -> Str.parse (field n l)) ls).
countLine (k, g) = "{k} {List.len g}".
counts n ls = List.map countLine (List.groupby (field n) ls).
execute argv = case argv of
    "cols" :: path :: [] -> u = map (fn l -> print "{field 1 l} {field 3 l}") (Str.lines (readPath path)); Unit
  | "sum" :: n :: path :: [] -> print (sumCol (Str.parse n) (Str.lines (readPath path)))
  | "count" :: n :: path :: [] -> u = map print (counts (Str.parse n) (Str.lines (readPath path))); Unit
  | _ -> error "usage: awk.sol cols FILE | sum N FILE | count N FILE".
> execute (args Unit).
