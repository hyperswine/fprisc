# CSV dialect: comma, doubled quotes, LF or CRLF records, strict quote placement.
# Empty input is []; a blank line is one empty field. A final newline adds no
# extra row. Quoted CR/LF and empty fields round-trip. Bare CR outside quotes,
# quotes inside unquoted fields and text after a closing quote are errors.
# One hosted parser supplies whole-document and record stream semantics.
# Limits: source UTF-8 bytes, records, fields/record, decoded bytes/field,
# source bytes/record (including delimiters and embedded newlines).
Limits = Type (Limits Int Int Int Int Int).
defaultLimits = Limits 16777216 1000000 1024 1048576 1048576.
parse s = parseWith defaultLimits s.
parseWith limits s = case limits of Limits input records fields field record ->
  Format.csv input records fields field record s.
# Stream.readCsv and Stream.foldCsv read a record at a time with explicit
# field-count/decoded-field-byte/source-record-byte limits. They preserve the
# linear ByteReader owner; this module's render/header views work on each row.

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
