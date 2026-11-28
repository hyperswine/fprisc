# json.sol -- JSON as a VALUE.  parse : String -> Result Json, render /
# pretty : Json -> String, and the accessors that make "read, reshape,
# write back" one railway pipeline:
#
#   J.parse text |>? J.path ["user", "name"] |>? J.text
#
# Numbers use exact Int or inexact Numeric; decimal/exponent precision follows
# Numeric, and nonfinite values are rejected. Duplicate object keys are retained
# in input order; get returns the first occurrence. Parsing is whole-document,
# with configurable admission before tree construction. Unicode escapes combine pairs;
# strings reject raw controls and isolated surrogates. Render escapes controls.

Json = Type (JNull | JBool Bool | JNum Int | JStr String
           | JArr (List Json) | JObj (List (String, Json))).

# ---- parse (recursive descent; i is a 0-based cursor; peek past the end = 0)

Limits = Type (Limits Int Int Int Int).
# UTF-8 source bytes, container depth, items per container, decoded string bytes.
defaultLimits = Limits 16777216 128 100000 1048576.
parse : unsafe String -> Result Json String .
parse s = parseWith defaultLimits s.
parseWith : unsafe Limits -> String -> Result Json String .
parseWith limits s = case limits of Limits input depth items field ->
  Format.json input depth items field s |>? (fn u -> parseRaw s).
# One JSON value per input line; LF/CRLF count toward the source byte budget.
parseLineWith : unsafe Limits -> Bytes -> Result Json String .
parseLineWith limits bytes = Utf8.decode bytes |>? (parseWith limits).

parseRaw : unsafe String -> Result Json String .
parseRaw s = value s (ws s 0) |>? (fn r -> (v, i) = r;
  if ws s i >= Str.len s then Ok v else Err "json: trailing characters at {i}").

peek s i = if i >= Str.len s then 0 else Str.at s i.
ws : unsafe String -> Int -> Int .
ws s i = if Str.isSpace (peek s i) then ws s (i + 1) else i.

value : unsafe String -> Int -> Result (Json, Int) String .
value s i = case peek s i of
    123 -> object s (ws s (i + 1)) []                                      # {
  | 91 -> array s (ws s (i + 1)) []                                        # [
  | 34 -> string s (i + 1) "" |> mapOk (fn r -> (t, j) = r; (JStr t, j))   # "
  | 0 -> Err "json: unexpected end of input"
  | _ -> literal s i.

literal : unsafe String -> Int -> Result (Json, Int) String .
literal s i =
  if Str.sub s i 4 == "true" then Ok (JBool True, i + 4)
  else if Str.sub s i 5 == "false" then Ok (JBool False, i + 5)
  else if Str.sub s i 4 == "null" then Ok (JNull, i + 4)
  else number s i.

# JSON number grammar, independent of the more permissive Numeric reader.
isDigit c = c >= 48 and c <= 57.
digits : unsafe String -> Int -> Int .
digits s i = if isDigit (peek s i) then digits s (i + 1) else i.
number : unsafe String -> Int -> Result (Json, Int) String .
number s i =
  start = if peek s i == 45 then i + 1 else i;
  integerEnd s start |>? (fractionEnd s) |>? (exponentEnd s) |>? (fn j ->
    Try.parseNum (Str.slice s i j) |>? (fn n ->
      if finite n then Ok (JNum n, j) else Err "json: number out of range at {i}")).
integerEnd : unsafe String -> Int -> Result Int String .
integerEnd s i = case peek s i of
    48 -> if isDigit (peek s (i + 1)) then Err "json: leading zero at {i}" else Ok (i + 1)
  | c -> if c >= 49 and c <= 57 then Ok (digits s (i + 1)) else Err "json: expected digit at {i}".
fractionEnd : unsafe String -> Int -> Result Int String .
fractionEnd s i =
  if peek s i != 46 then Ok i
  else if isDigit (peek s (i + 1)) then Ok (digits s (i + 1))
  else Err "json: expected fraction at {i}".
exponentEnd : unsafe String -> Int -> Result Int String .
exponentEnd s i =
  if peek s i != 101 and peek s i != 69 then Ok i
  else
    j = if peek s (i + 1) == 43 or peek s (i + 1) == 45 then i + 2 else i + 1;
    if isDigit (peek s j) then Ok (digits s j) else Err "json: expected exponent at {j}".
finite n = s = Str.lower "{n}"; not (Str.contains "inf" s or Str.contains "nan" s).

# Accumulate pieces in reverse; join once instead of copying a growing prefix.
string : unsafe String -> Int -> String -> Result (String, Int) String .
string s i acc = stringParts s i [acc].
stringParts : unsafe String -> Int -> List String -> Result (String, Int) String .
stringParts s i parts =
  if i >= Str.len s then Err "json: unterminated string"
  else case peek s i of
      34 -> Ok (Str.join "" (List.rev parts), i + 1)
    | 92 -> escapeParts s (i + 1) parts
    | c ->
        if c < 32 or (c >= 55296 and c <= 57343) then Err "json: invalid string character at {i}"
        else stringParts s (i + 1) (Str.fromCode c :: parts).
escapeParts : unsafe String -> Int -> List String -> Result (String, Int) String .
escapeParts s i parts = case peek s i of
    110 -> stringParts s (i + 1) ("\n" :: parts)
  | 116 -> stringParts s (i + 1) ("\t" :: parts)
  | 114 -> stringParts s (i + 1) ("\r" :: parts)
  | 98 -> stringParts s (i + 1) (Str.fromCode 8 :: parts)
  | 102 -> stringParts s (i + 1) (Str.fromCode 12 :: parts)
  | 34 -> stringParts s (i + 1) ("\"" :: parts)
  | 92 -> stringParts s (i + 1) ("\\" :: parts)
  | 47 -> stringParts s (i + 1) ("/" :: parts)
  | 117 -> hex4 s (i + 1) 0 0 |>? (unicodeEscape s i parts)
  | _ -> Err "json: unknown or incomplete escape at {i}".
unicodeEscape : unsafe String -> Int -> List String -> Int -> Result (String, Int) String .
unicodeEscape s i parts cp =
  if cp >= 55296 and cp <= 56319 then
    if not (peek s (i + 5) == 92 and peek s (i + 6) == 117) then Err "json: missing low surrogate at {i}"
    else hex4 s (i + 7) 0 0 |>? (fn low ->
      if not (low >= 56320 and low <= 57343) then Err "json: invalid low surrogate at {i}"
      else stringParts s (i + 11) (Str.fromCode (65536 + (cp - 55296) * 1024 + low - 56320) :: parts))
  else if cp >= 56320 and cp <= 57343 then Err "json: unpaired low surrogate at {i}"
  else stringParts s (i + 5) (Str.fromCode cp :: parts).
hex4 : unsafe String -> Int -> Int -> Int -> Result Int String .
hex4 s i n acc =
  if n == 4 then Ok acc
  else hexDigit (peek s i) |>? (fn d -> hex4 s (i + 1) (n + 1) (acc * 16 + d)).
hexDigit c =
  k = Str.find c "0123456789abcdefABCDEF";
  if k < 0 then Err "json: bad \\u escape"
  else Ok (if k > 15 then k - 6 else k).
array : unsafe String -> Int -> List Json -> Result (Json, Int) String .
array s i acc =
  if acc == [] and peek s i == 93 then Ok (JArr [], i + 1)
  else value s i |>? (fn r -> (v, j) = r; k = ws s j;
      case peek s k of
        44 -> array s (ws s (k + 1)) (v :: acc)
      | 93 -> Ok (JArr (List.rev (v :: acc)), k + 1)
      | _ -> Err "json: expected ',' or ']' at {k}").

object : unsafe String -> Int -> List (String, Json) -> Result (Json, Int) String .
object s i acc =
  if acc == [] and peek s i == 125 then Ok (JObj [], i + 1)
  else if peek s i != 34 then Err "json: expected a key at {i}"
  else string s (i + 1) "" |>? (fn r -> (k, j) = r; j2 = ws s j;
      if peek s j2 != 58 then Err "json: expected ':' at {j2}"
      else value s (ws s (j2 + 1)) |>? (fn r2 -> (v, j3) = r2; j4 = ws s j3;
          case peek s j4 of
            44 -> object s (ws s (j4 + 1)) ((k, v) :: acc)
          | 125 -> Ok (JObj (List.rev ((k, v) :: acc)), j4 + 1)
          | _ -> Err "json: expected ',' or '}' at {j4}")).

# ---- render ------------------------------------------------------------------

render : unsafe Json -> String .
render j = case j of
    JNull -> "null"
  | JBool True -> "true"
  | JBool False -> "false"
  | JNum n -> if finite n then "{n}" else error "json: cannot render nonfinite number"
  | JStr t -> quote t
  | JArr xs -> "[{Str.join "," (List.map render xs)}]"
  | JObj kvs -> "\{{Str.join "," (List.map (fn p -> (k, v) = p; "{quote k}:{render v}") kvs)}\}".

quote t = "\"{Str.join "" (List.map quoteCode (Str.codes t))}\"".
quoteCode c = case c of
    34 -> "\\\""
  | 92 -> "\\\\"
  | _ ->
      if c < 32 then "\\u00{hexCode (c / 16)}{hexCode (c % 16)}"
      else if c >= 55296 and c <= 57343 then error "json: cannot render surrogate code point"
      else Str.fromCode c.
hexCode n = Str.sub "0123456789abcdef" n 1.

# two-space indentation; empty containers and scalars stay inline
pretty : unsafe Json -> String .
pretty j = prettyAt "" j.
prettyAt : unsafe String -> Json -> String .
prettyAt ind j = case j of
    JArr (x :: xs) -> "[\n{lines ind (List.map (prettyAt "{ind}  ") (x :: xs))}\n{ind}]"
  | JObj (p :: ps) -> "\{\n{lines ind (List.map (fn q -> (k, v) = q; "{quote k}: {prettyAt "{ind}  " v}") (p :: ps))}\n{ind}\}"
  | _ -> render j.
lines ind xs = Str.join ",\n" (List.map (fn x -> "{ind}  {x}") xs).

# ---- accessors: every one is a railway step ----------------------------------

get k j = case j of
    JObj kvs -> (case List.filter (fn p -> (k2, _) = p; k2 == k) kvs of
      (_, v) :: _ -> Ok v
    | [] -> Err "json: no key '{k}'")
  | _ -> Err "json: not an object".
path ks j = List.fold (fn r k -> r |>? get k) (Ok j) ks.
at i j = case j of
    JArr xs -> if i >= 0 and i < List.len xs then Ok (xs ! i) else Err "json: index {i} out of range"
  | _ -> Err "json: not an array".
num j = case j of JNum n -> Ok n | _ -> Err "json: not a number".
text j = case j of JStr t -> Ok t | _ -> Err "json: not a string".
bool j = case j of JBool b -> Ok b | _ -> Err "json: not a boolean".
items j = case j of JArr xs -> Ok xs | _ -> Err "json: not an array".
fields j = case j of JObj kvs -> Ok kvs | _ -> Err "json: not an object".

# ---- reshaping: pure, order-preserving --------------------------------------

# upsert a key (a new key goes last)
set k v j = case j of
    JObj kvs -> JObj (
      if List.has k (List.map (fn p -> (k2, _) = p; k2) kvs) then
        List.map (fn p -> (k2, v2) = p; if k2 == k then (k, v) else (k2, v2)) kvs
      else kvs + [(k, v)])
  | _ -> j.
without k j = case j of
    JObj kvs -> JObj (List.filter (fn p -> (k2, _) = p; k2 != k) kvs)
  | _ -> j.
rename old new j = case j of
    JObj kvs -> JObj (List.map (fn p -> (k, v) = p; if k == old then (new, v) else (k, v)) kvs)
  | _ -> j.
mapItems f j = case j of JArr xs -> JArr (List.map f xs) | _ -> j.
filterItems p j = case j of JArr xs -> JArr (List.filter p xs) | _ -> j.

# ---- lifting plain values ----------------------------------------------------

nums xs = JArr (List.map (fn n -> JNum n) xs).
strs xs = JArr (List.map (fn t -> JStr t) xs).
# an association list of strings -> object of strings (the CSV record shape)
ofRecord kvs = JObj (List.map (fn p -> (k, v) = p; (k, JStr v)) kvs).
