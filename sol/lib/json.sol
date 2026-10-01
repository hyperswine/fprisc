# json.sol -- JSON as a VALUE.  parse : String -> Result Json, render /
# pretty : Json -> String, and the accessors that make "read, reshape,
# write back" one railway pipeline:
#
#   J.parse text |>? J.path ["user", "name"] |>? J.text
#
# Numbers use exact Int or inexact Numeric; decimal/exponent precision follows
# Numeric, and nonfinite values are rejected. Duplicate object keys are retained
# in input order; get returns the first occurrence. Parsing is whole-document,
# without a configurable nesting/size limit yet. Unicode escapes combine pairs;
# strings reject raw controls and isolated surrogates. Render escapes controls.

Json = Type (JNull | JBool Bool | JNum Int | JStr String
           | JArr (List Json) | JObj (List (String, Json))).

# ---- parse (recursive descent; i is a 0-based cursor; peek past the end = 0)

parse s = value s (ws s 0) |>? (fn r -> (v, i) = r;
  case ws s i >= Str.len s of
    True -> Ok v
  | False -> Err "json: trailing characters at {i}").

peek s i = case i >= Str.len s of True -> 0 | False -> Str.at s i.
ws s i = case Str.isSpace (peek s i) of True -> ws s (i + 1) | False -> i.

value s i = case peek s i of
    123 -> object s (ws s (i + 1)) []                                      # {
  | 91 -> array s (ws s (i + 1)) []                                        # [
  | 34 -> string s (i + 1) "" |> mapOk (fn r -> (t, j) = r; (JStr t, j))   # "
  | 0 -> Err "json: unexpected end of input"
  | _ -> literal s i.

literal s i = case Str.sub s i 4 == "true" of
    True -> Ok (JBool True, i + 4)
  | False -> (case Str.sub s i 5 == "false" of
      True -> Ok (JBool False, i + 5)
    | False -> (case Str.sub s i 4 == "null" of
        True -> Ok (JNull, i + 4)
      | False -> number s i)).

# JSON number grammar, independent of the more permissive Numeric reader.
isDigit c = and (c >= 48) (c <= 57).
digits s i = case isDigit (peek s i) of True -> digits s (i + 1) | False -> i.
number s i =
  start = case peek s i == 45 of True -> i + 1 | False -> i;
  integerEnd s start |>? (fractionEnd s) |>? (exponentEnd s) |>? (fn j ->
    Try.parseNum (Str.slice s i j) |>? (fn n ->
      case finite n of True -> Ok (JNum n, j) | False -> Err "json: number out of range at {i}")).
integerEnd s i = case peek s i of
    48 -> (case isDigit (peek s (i + 1)) of True -> Err "json: leading zero at {i}" | False -> Ok (i + 1))
  | c -> (case and (c >= 49) (c <= 57) of True -> Ok (digits s (i + 1)) | False -> Err "json: expected digit at {i}").
fractionEnd s i = case peek s i == 46 of
    False -> Ok i
  | True -> (case isDigit (peek s (i + 1)) of True -> Ok (digits s (i + 1)) | False -> Err "json: expected fraction at {i}").
exponentEnd s i = case or (peek s i == 101) (peek s i == 69) of
    False -> Ok i
  | True -> j = case or (peek s (i + 1) == 43) (peek s (i + 1) == 45) of True -> i + 2 | False -> i + 1;
            case isDigit (peek s j) of True -> Ok (digits s j) | False -> Err "json: expected exponent at {j}".
finite n = s = Str.lower "{n}"; not (or (Str.contains "inf" s) (Str.contains "nan" s)).

# Accumulate pieces in reverse; join once instead of copying a growing prefix.
string s i acc = stringParts s i [acc].
stringParts s i parts = case i >= Str.len s of
    True -> Err "json: unterminated string"
  | False -> (case peek s i of
      34 -> Ok (Str.join "" (List.rev parts), i + 1)
    | 92 -> escapeParts s (i + 1) parts
    | c -> (case or (c < 32) (and (c >= 55296) (c <= 57343)) of
        True -> Err "json: invalid string character at {i}"
      | False -> stringParts s (i + 1) (Str.fromCode c :: parts))).
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
unicodeEscape s i parts cp = case and (cp >= 55296) (cp <= 56319) of
    True -> (case and (peek s (i + 5) == 92) (peek s (i + 6) == 117) of
      False -> Err "json: missing low surrogate at {i}"
    | True -> hex4 s (i + 7) 0 0 |>? (fn low ->
        case and (low >= 56320) (low <= 57343) of
          False -> Err "json: invalid low surrogate at {i}"
        | True -> stringParts s (i + 11) (Str.fromCode (65536 + (cp - 55296) * 1024 + low - 56320) :: parts)))
  | False -> (case and (cp >= 56320) (cp <= 57343) of
      True -> Err "json: unpaired low surrogate at {i}"
    | False -> stringParts s (i + 5) (Str.fromCode cp :: parts)).
hex4 s i n acc = case n == 4 of
    True -> Ok acc
  | False -> hexDigit (peek s i) |>? (fn d -> hex4 s (i + 1) (n + 1) (acc * 16 + d)).
hexDigit c = k = Str.find c "0123456789abcdefABCDEF";
  case k < 0 of
    True -> Err "json: bad \\u escape"
  | False -> Ok (case k > 15 of True -> k - 6 | False -> k).
array s i acc = case and (acc == []) (peek s i == 93) of
    True -> Ok (JArr [], i + 1)
  | False -> value s i |>? (fn r -> (v, j) = r; k = ws s j;
      case peek s k of
        44 -> array s (ws s (k + 1)) (v :: acc)
      | 93 -> Ok (JArr (List.rev (v :: acc)), k + 1)
      | _ -> Err "json: expected ',' or ']' at {k}").

object s i acc = case and (acc == []) (peek s i == 125) of
    True -> Ok (JObj [], i + 1)
  | False -> (case peek s i == 34 of
      False -> Err "json: expected a key at {i}"
    | True -> string s (i + 1) "" |>? (fn r -> (k, j) = r; j2 = ws s j;
        case peek s j2 == 58 of
          False -> Err "json: expected ':' at {j2}"
        | True -> value s (ws s (j2 + 1)) |>? (fn r2 -> (v, j3) = r2; j4 = ws s j3;
            case peek s j4 of
              44 -> object s (ws s (j4 + 1)) ((k, v) :: acc)
            | 125 -> Ok (JObj (List.rev ((k, v) :: acc)), j4 + 1)
            | _ -> Err "json: expected ',' or '}' at {j4}"))).

# ---- render ------------------------------------------------------------------

render j = case j of
    JNull -> "null"
  | JBool True -> "true"
  | JBool False -> "false"
  | JNum n -> (case finite n of True -> "{n}" | False -> error "json: cannot render nonfinite number")
  | JStr t -> quote t
  | JArr xs -> "[{Str.join "," (List.map render xs)}]"
  | JObj kvs -> "\{{Str.join "," (List.map (fn p -> (k, v) = p; "{quote k}:{render v}") kvs)}\}".

quote t = "\"{Str.join "" (List.map quoteCode (Str.codes t))}\"".
quoteCode c = case c of
    34 -> "\\\""
  | 92 -> "\\\\"
  | _ -> (case c < 32 of
      True -> "\\u00{hexCode (c / 16)}{hexCode (c % 16)}"
    | False -> (case and (c >= 55296) (c <= 57343) of
        True -> error "json: cannot render surrogate code point"
      | False -> Str.fromCode c)).
hexCode n = Str.sub "0123456789abcdef" n 1.

# two-space indentation; empty containers and scalars stay inline
pretty j = prettyAt "" j.
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
    JArr xs -> (case and (i >= 0) (i < List.len xs) of True -> Ok (xs ! i) | False -> Err "json: index {i} out of range")
  | _ -> Err "json: not an array".
num j = case j of JNum n -> Ok n | _ -> Err "json: not a number".
text j = case j of JStr t -> Ok t | _ -> Err "json: not a string".
bool j = case j of JBool b -> Ok b | _ -> Err "json: not a boolean".
items j = case j of JArr xs -> Ok xs | _ -> Err "json: not an array".
fields j = case j of JObj kvs -> Ok kvs | _ -> Err "json: not an object".

# ---- reshaping: pure, order-preserving --------------------------------------

# upsert a key (a new key goes last)
set k v j = case j of
    JObj kvs -> JObj (case List.has k (List.map (fn p -> (k2, _) = p; k2) kvs) of
      True -> List.map (fn p -> (k2, v2) = p; case k2 == k of True -> (k, v) | False -> (k2, v2)) kvs
    | False -> kvs + [(k, v)])
  | _ -> j.
without k j = case j of
    JObj kvs -> JObj (List.filter (fn p -> (k2, _) = p; k2 != k) kvs)
  | _ -> j.
rename old new j = case j of
    JObj kvs -> JObj (List.map (fn p -> (k, v) = p; case k == old of True -> (new, v) | False -> (k, v)) kvs)
  | _ -> j.
mapItems f j = case j of JArr xs -> JArr (List.map f xs) | _ -> j.
filterItems p j = case j of JArr xs -> JArr (List.filter p xs) | _ -> j.

# ---- lifting plain values ----------------------------------------------------

nums xs = JArr (List.map (fn n -> JNum n) xs).
strs xs = JArr (List.map (fn t -> JStr t) xs).
# an association list of strings -> object of strings (the CSV record shape)
ofRecord kvs = JObj (List.map (fn p -> (k, v) = p; (k, JStr v)) kvs).
