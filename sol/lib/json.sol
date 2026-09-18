# json.sol -- JSON as a VALUE.  parse : String -> Result Json, render /
# pretty : Json -> String, and the accessors that make "read, reshape,
# write back" one railway pipeline:
#
#   J.parse text |>? J.path ["user", "name"] |>? J.text
#
# Numbers ride the Numeric surface (Try.parseNum: ints exact, decimals
# inexact); object keys keep document order, so parse |> render is the
# identity up to whitespace.  Sol strings are code points, so a \uXXXX
# escape is just `Str.fromCode` (no surrogate pairs) and render emits UTF-8;
# control characters other than \n \t \r \b \f are not re-escaped.

Json = Type (JNull | JBool Bool | JNum Int | JStr String
           | JArr (List Json) | JObj (List (String, Json))).

# ---- parse (recursive descent; i is a 1-based cursor, 0 = end) --------------

parse s = value s (ws s 1) |>? (fn r -> (v, i) = r;
  case ws s i > Str.len s of
    True -> Ok v
  | False -> Err "json: trailing characters at {i}").

peek s i = case i > Str.len s of True -> 0 | False -> Str.at s i.
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

number s i =
  j = numEnd s i;
  case j == i of
    True -> Err "json: unexpected '{Str.fromCode (peek s i)}' at {i}"
  | False -> Try.parseNum (Str.slice s i (j - 1)) |> mapOk (fn n -> (JNum n, j)).
numEnd s i = case Str.contains (Str.fromCode (peek s i)) "-+0123456789.eE" of
    True -> numEnd s (i + 1)
  | False -> i.

string s i acc = case peek s i of
    0 -> Err "json: unterminated string"
  | 34 -> Ok (acc, i + 1)
  | 92 -> escape s (i + 1) acc
  | c -> string s (i + 1) "{acc}{Str.fromCode c}".
escape s i acc = case peek s i of
    110 -> string s (i + 1) "{acc}\n"
  | 116 -> string s (i + 1) "{acc}\t"
  | 114 -> string s (i + 1) "{acc}\r"
  | 98 -> string s (i + 1) "{acc}\x08"
  | 102 -> string s (i + 1) "{acc}\x0c"
  | 117 -> hex4 s (i + 1) 0 0 |>? (fn cp -> string s (i + 5) "{acc}{Str.fromCode cp}")
  | 0 -> Err "json: unterminated escape"
  | c -> string s (i + 1) "{acc}{Str.fromCode c}".                                   # \" \\ \/
hex4 s i n acc = case n == 4 of
    True -> Ok acc
  | False -> hexDigit (peek s i) |>? (fn d -> hex4 s (i + 1) (n + 1) (acc * 16 + d)).
hexDigit c = case Str.find c "0123456789abcdefABCDEF" of
    0 -> Err "json: bad \\u escape"
  | k -> Ok (case k > 16 of True -> k - 7 | False -> k - 1).
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
  | JNum n -> "{n}"
  | JStr t -> quote t
  | JArr xs -> "[{Str.join "," (List.map render xs)}]"
  | JObj kvs -> "\{{Str.join "," (List.map (fn p -> (k, v) = p; "{quote k}:{render v}") kvs)}\}".

quote t = "\"{t |> Str.replace "\\" "\\\\" |> Str.replace "\"" "\\\"" |> Str.replace "\n" "\\n" |> Str.replace "\t" "\\t" |> Str.replace "\r" "\\r"}\"".

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
    JArr xs -> (case and (i >= 1) (i <= List.len xs) of True -> Ok (xs ! i) | False -> Err "json: index {i} out of range")
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
