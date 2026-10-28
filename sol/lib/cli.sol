# Long options, one-letter aliases, explicit repeated values, and -- operands.
# No shell splitting, abbreviation or bundled short options. Tokens stay exact.
M = use "../../std/map".
Kind = Type (Switch | One | Many).
Option = Type (Option String String Kind).
Parsed = Type (Parsed (List (String, List String)) (List String)).

parse specs argv = validate specs [] [] |>? (fn u -> walk specs argv M.strings []).
# The recursive traversals carry explicit structural termination measures.
validate : (specs : List Option | measure specs) -> List String -> List String -> Result Unit String.
validate specs names aliases = case specs of
  [] -> Ok Unit
| Option name short kind :: rest ->
    if not (validName name) then Err "cli: invalid option name '{name}'"
    else if not (validShort short) then Err "cli: invalid short alias '{short}'"
    else if List.has name names then Err "cli: duplicate option --{name}"
    else if and (short != "") (List.has short aliases) then Err "cli: duplicate alias -{short}"
    else validate rest (name :: names) (short :: aliases).
letter c = or (and (c >= 65) (c <= 90)) (and (c >= 97) (c <= 122)).
validShort s = if s == "" then True else if Str.len s == 1 then letter (Str.at s 0) else False.
validName s = if Str.len s == 0 then False
  else and (letter (Str.at s 0)) (List.all (fn c -> or (letter c) (or (and (c >= 48) (c <= 57)) (c == 45))) (Str.codes s)).
findLong : String -> (specs : List Option | measure specs) -> Result Option String.
findLong name specs = case specs of
  [] -> Err "cli: unknown option --{name}"
| option :: rest -> (case option of Option key short kind -> if key == name then Ok option else findLong name rest).
findShort : String -> (specs : List Option | measure specs) -> Result Option String.
findShort alias specs = case specs of
  [] -> Err "cli: unknown option -{alias}"
| option :: rest -> (case option of Option key short kind -> if short == alias then Ok option else findShort alias rest).
decode specs token =
  if Str.startsWith "--" token then
    text = Str.sub token 2 (Str.len token - 2);
    equal = Str.find 61 text;
    name = if equal < 0 then text else Str.sub text 0 equal;
    findLong name specs |> mapOk (fn option -> (option,equal >= 0,if equal < 0 then "" else Str.sub text (equal + 1) (Str.len text - equal - 1)))
  else if Str.len token != 2 then Err "cli: short options cannot be bundled: {token}"
  else findShort (Str.sub token 1 1) specs |> mapOk (fn option -> (option,False,"")).
walk : List Option -> (argv : List String | measure argv) -> M.Map String (List String) -> List String -> Result Parsed String.
walk specs argv values operands = case argv of
  [] -> Ok (Parsed (ordered values) (List.rev operands))
| "--" :: rest -> Ok (Parsed (ordered values) (List.append (List.rev operands) rest))
| token :: rest ->
    if and (Str.startsWith "-" token) (token != "-") then
      decode specs token |>? (fn decoded -> (option,inline,value) = decoded;
        case option of Option name short kind ->
          if inline then inlineValue option value values |>? (fn next -> walk specs rest next operands)
          else (case kind of
            Switch -> putValue option "true" values |>? (fn next -> walk specs rest next operands)
          | _ -> (case rest of
              [] -> Err "cli: missing value for --{name}"
            | value :: tail -> putValue option value values |>? (fn next -> walk specs tail next operands))))
    else walk specs rest values (token :: operands).
ordered values = List.map (fn pair -> (key,items) = pair; (key,List.rev items)) (M.entries values).
putValue option value values = case option of Option name short kind ->
  case kind of
    Switch -> if value != "true" then Err "cli: --{name} takes no value"
              else if M.member name values then Err "cli: duplicate --{name}"
              else Ok (M.insert name ["true"] values)
  | One -> if M.member name values then Err "cli: duplicate --{name}" else Ok (M.insert name [value] values)
  | Many -> Ok (M.insert name (value :: M.getOr [] name values) values).
inlineValue option value values = case option of
  Option name short Switch -> Err "cli: --{name} takes no value"
| _ -> putValue option value values.
values key parsed = case parsed of Parsed entries operands ->
  case List.filter (fn p -> (k,v) = p; k == key) entries of [] -> [] | (_,v) :: rest -> v.
flag key parsed = values key parsed == ["true"].
valueOr fallback key parsed = case values key parsed of [] -> fallback | v :: rest -> v.
operands parsed = case parsed of Parsed entries rest -> rest.
