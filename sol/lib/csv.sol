# csv.sol -- CSV as ROWS OF FIELDS (List (List String)).  parse : String ->
# Result rows, render : rows -> String; quoted fields may hold commas,
# newlines and doubled quotes, so parse |> render |> parse is the identity.
# CR is ignored, a trailing newline is optional, a blank last line is not
# a row.  With a header row, `records` gives each row as (column, value)
# pairs -- the shape that lifts straight into a JSON object (J.ofRecord).

parse s = rows s 1 "" [] [].

# i = cursor, field = text so far, row = fields so far (reversed), acc = rows (reversed)
rows s i field row acc = case peek s i of
    0 -> Ok (List.rev (close field row acc))
  | 34 -> quoted s (i + 1) field row acc
  | 44 -> rows s (i + 1) "" (field :: row) acc
  | 10 -> rows s (i + 1) "" [] (close field row acc)
  | 13 -> rows s (i + 1) field row acc
  | c -> rows s (i + 1) "{field}{Str.fromCode c}" row acc.
quoted s i field row acc = case peek s i of
    0 -> Err "csv: unterminated quote"
  | 34 -> (case peek s (i + 1) == 34 of
      True -> quoted s (i + 2) "{field}\"" row acc
    | False -> rows s (i + 1) field row acc)
  | c -> quoted s (i + 1) "{field}{Str.fromCode c}" row acc.
close field row acc = case and (field == "") (row == []) of
    True -> acc
  | False -> List.rev (field :: row) :: acc.
peek s i = case i > Str.len s of True -> 0 | False -> Str.at s i.

render rs = Str.join "" (List.map (fn r -> "{Str.join "," (List.map field r)}\n") rs).
field f = case or (Str.contains "," f) (or (Str.contains "\"" f) (Str.contains "\n" f)) of
    True -> "\"{Str.replace "\"" "\"\"" f}\""
  | False -> f.

# ---- header-aware views -------------------------------------------------------

# rows -> one (column, value) association list per data row
records rs = case rs of
    hdr :: body -> List.map (fn r -> List.zip hdr r) body
  | [] -> [].
# the inverse: a column order + records -> rows (missing columns render empty)
table hdr recs = hdr :: List.map (fn rec -> List.map (fn h -> okOr "" (col h rec)) hdr) recs.
col k rec = case List.filter (fn p -> (k2, _) = p; k2 == k) rec of
    (_, v) :: _ -> Ok v
  | [] -> Err "csv: no column '{k}'".
