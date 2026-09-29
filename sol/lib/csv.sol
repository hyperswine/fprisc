# CSV dialect: comma, doubled quotes, LF or CRLF records, strict quote placement.
# Empty input is []; a blank line is one empty field. A final newline adds no
# extra row. Quoted CR/LF and empty fields round-trip. Bare CR outside quotes,
# quotes inside unquoted fields and text after a closing quote are errors.
# Whole-document parser. Accumulate field fragments then join once.
parse s = rows s 1 [] [] [] False.
finish parts = Str.join "" (List.rev parts).
close parts row acc = List.rev (finish parts :: row) :: acc.
rows s i parts row acc active = case i > Str.len s of
    True -> Ok (List.rev (case active of True -> close parts row acc | False -> acc))
  | False -> (case Str.at s i of
      34 -> (case parts == [] of True -> quoted s (i + 1) parts row acc | False -> Err "csv: quote inside unquoted field at {i}")
    | 44 -> rows s (i + 1) [] (finish parts :: row) acc True
    | 10 -> rows s (i + 1) [] [] (close parts row acc) False
    | 13 -> crlf s i parts row acc
    | c -> rows s (i + 1) (Str.fromCode c :: parts) row acc True).
crlf s i parts row acc = case peek s (i + 1) == 10 of
    True -> rows s (i + 2) [] [] (close parts row acc) False
  | False -> Err "csv: bare CR outside quoted field at {i}".
quoted s i parts row acc = case i > Str.len s of
    True -> Err "csv: unterminated quote"
  | False -> (case Str.at s i == 34 of
      True -> (case peek s (i + 1) == 34 of
        True -> quoted s (i + 2) ("\"" :: parts) row acc
      | False -> afterQuote s (i + 1) parts row acc)
    | False -> quoted s (i + 1) (Str.fromCode (Str.at s i) :: parts) row acc).
afterQuote s i parts row acc = case i > Str.len s of
    True -> Ok (List.rev (close parts row acc))
  | False -> (case Str.at s i of
      44 -> rows s (i + 1) [] (finish parts :: row) acc True
    | 10 -> rows s (i + 1) [] [] (close parts row acc) False
    | 13 -> crlf s i parts row acc
    | _ -> Err "csv: expected separator after quote at {i}").
peek s i = case i > Str.len s of True -> 0 | False -> Str.at s i.

render rs = Str.join "" (List.map renderRow rs).
renderRow r = case r of
    [] -> error "csv: cannot represent a zero-field row"
  | _ -> "{Str.join "," (List.map field r)}\n".
field f = case or (f == "") (or (Str.contains "," f) (or (Str.contains "\"" f) (or (Str.contains "\r" f) (Str.contains "\n" f)))) of
    True -> "\"{Str.replace "\"" "\"\"" f}\""
  | False -> f.

# Header views reject duplicate names and ragged rows rather than truncating.
records rs = unwrap (recordsChecked rs).
recordsChecked rs = case rs of
    [] -> Ok []
  | hdr :: body -> (case duplicate hdr [] of
      True -> Err "csv: duplicate header"
    | False -> recordRows hdr body 2 []).
duplicate xs seen = case xs of
    [] -> False
  | x :: rest -> (case List.has x seen of True -> True | False -> duplicate rest (x :: seen)).
recordRows hdr rows n acc = case rows of
    [] -> Ok (List.rev acc)
  | r :: rest -> (case List.len hdr == List.len r of
      False -> Err "csv: row {n} has {List.len r} fields; expected {List.len hdr}"
    | True -> recordRows hdr rest (n + 1) (List.zip hdr r :: acc)).
# Missing columns render empty, with the caller's explicit column order.
table hdr recs = hdr :: List.map (fn rec -> List.map (fn h -> okOr "" (col h rec)) hdr) recs.
col k rec = case List.filter (fn p -> (k2, _) = p; k2 == k) rec of
    (_, v) :: _ -> Ok v
  | [] -> Err "csv: no column '{k}'".
