# jsoncsv.sol -- JSON and CSV as values, both directions, as an executable
# spec.  Parse a document, reshape it with the railway accessors, render
# it back; clean a messy CSV, aggregate it, emit JSON AND CSV; then cross
# the formats (records -> JSON objects -> records) and prove every round
# trip is the identity.  All file writes land in one transaction.
#
#   ./fpr sol sol/examples/jsoncsv.sol
#
# The vocabulary is the prelude plus lib/json + lib/csv: Str.*, List.*,
# Try.parseNum, |>? and mapOk -- no per-script helpers beyond `expect`.

J = use "../lib/json".
C = use "../lib/csv".
JNull = J.JNull.  JBool = J.JBool.  JNum = J.JNum.  JStr = J.JStr.  JArr = J.JArr.  JObj = J.JObj.

expect what got want = case got == want of
    True -> print "ok  {what}"
  | False -> error "FAIL {what}: got {got}, wanted {want}".

dir = "/tmp/sol-jsoncsv".

# ---- 1. JSON in: a document with every value kind ----------------------------

customers = "\{
  \"generated\": \"2026-09-02\",
  \"customers\": [
    \{\"id\": 1, \"name\": \"Ada\",  \"active\": true,  \"credit\": 120.5, \"tags\": [\"vip\", \"early\"], \"address\": \{\"city\": \"Turin\", \"zip\": null\}\},
    \{\"id\": 2, \"name\": \"Bo \\\"the\\\" Bold\", \"active\": false, \"credit\": 0,     \"tags\": [],               \"address\": \{\"city\": \"Oslo\",  \"zip\": \"0150\"\}\},
    \{\"id\": 3, \"name\": \"Cy\",   \"active\": true,  \"credit\": -15,   \"tags\": [\"late\"],          \"address\": \{\"city\": \"Kyoto\", \"zip\": \"600\"\}\}
  ]
\}".

> doc = unwrap (J.parse customers);
  _ = expect "path into nested objects" (J.path ["customers"] doc |>? J.at 2 |>? J.get "name" |>? J.text) (Ok "Bo \"the\" Bold");
  _ = expect "numbers ride Numeric"     (J.path ["customers"] doc |>? J.at 1 |>? J.get "credit" |>? J.num) (Ok 120.5);
  _ = expect "null is a value"          (J.path ["customers"] doc |>? J.at 1 |>? J.path ["address", "zip"]) (Ok JNull);
  _ = expect "a missing key derails"    (J.path ["customers", "nope"] doc) (Err "json: not an object");
  expect "index out of range"       (J.path ["customers"] doc |>? J.at 9) (Err "json: index 9 out of range").

# ---- 2. reshape: filter, compute, rename, drop -- then JSON out ---------------

# active customers only, a tier computed from credit, address flattened to city
tier c = case c >= 100 of True -> "gold" | False -> "basic".
reshape cust =
  credit = unwrap (J.get "credit" cust |>? J.num);
  city = unwrap (J.path ["address", "city"] cust |>? J.text);
  cust |> J.set "tier" (JStr (tier credit)) |> J.set "city" (JStr city)
       |> J.without "address" |> J.without "tags" |> J.rename "name" "who".

> doc = unwrap (J.parse customers);
  active = J.path ["customers"] doc |>? J.items |> mapOk (List.filter (fn c -> (J.get "active" c |>? J.bool) == Ok True));
  out = active |> mapOk (fn cs -> JObj [("count", JNum (List.len cs)), ("customers", JArr (List.map reshape cs))]);
  u = writePath "{dir}/customers-out.json" (J.pretty (unwrap out));
  _ = expect "render is compact JSON" (mapOk J.render out)
    (Ok "\{\"count\":2,\"customers\":[\{\"id\":1,\"who\":\"Ada\",\"active\":true,\"credit\":120.5,\"tier\":\"gold\",\"city\":\"Turin\"\},\{\"id\":3,\"who\":\"Cy\",\"active\":true,\"credit\":-15,\"tier\":\"basic\",\"city\":\"Kyoto\"\}]\}");
  expect "the written file parses back to the same value" (J.parse (readPath "{dir}/customers-out.json")) out.

# ---- 3. round trips and refusals ---------------------------------------------

tricky = JObj [("s", JStr "quote \" backslash \\ tab \t nl \n é €"), ("e", JArr []), ("o", JObj []),
               ("n", JArr [JNum 0, JNum -1, JNum 2.25, JNum 1000]), ("b", JArr [JBool True, JBool False, JNull])].
> expect "parse (render x) == x"     (J.parse (J.render tricky)) (Ok tricky).
> expect "parse (pretty x) == x"     (J.parse (J.pretty tricky)) (Ok tricky).
> expect "\\u escapes decode"        (J.parse "\"\\u00e9\\u20ac\"") (Ok (JStr "é€")).
> expect "trailing garbage refused"  (isOk (J.parse "[1] x")) False.
> expect "unterminated refused"      (isOk (J.parse "\{\"a\": [1, 2")) False.
> expect "bad literal refused"       (isOk (J.parse "[tru]")) False.

# ---- 4. CSV in: messy, cleaned, aggregated -----------------------------------

orders = "order,customer,amount,note
1001, 1 ,19.99,\"first, with comma\"
1002, 2 ,5,
1003, 1 ,oops,bad amount
1004, 3 ,100.01,\"say \"\"hi\"\"\"

1005, 1 ,0.01,".

trim rec = List.map (fn p -> (k, v) = p; (k, Str.trim v)) rec.
amount rec = C.col "amount" rec |>? Try.parseNum.

> rows = unwrap (C.parse orders);
  recs = List.map trim (C.records rows);
  _ = expect "rows parsed (blank line is not a row)" (List.len recs) 5;
  _ = expect "quoted comma and doubled quotes"
    (List.map (fn r -> okOr "" (C.col "note" r)) recs) ["first, with comma", "", "bad amount", "say \"hi\"", ""];
  good = List.filter (fn r -> isOk (amount r)) recs;
  bad = List.filter (fn r -> not (isOk (amount r))) recs;
  _ = expect "one row fails to clean" (List.map (fn r -> okOr "" (C.col "order" r)) bad) ["1003"];
  totals = List.groupby (fn r -> unwrap (C.col "customer" r)) good
    |> List.map (fn g -> (cust, rs) = g; (cust, List.sum (List.map (fn r -> unwrap (amount r)) rs)));
  _ = expect "totals per customer, in first-seen order" totals [("1", 20), ("2", 5), ("3", 100.01)];

  # JSON out: one object per customer, average computed with plain arithmetic
  summary = JArr (List.map (fn t -> (cust, total) = t;
      n = List.len (List.filter (fn r -> C.col "customer" r == Ok cust) good);
      JObj [("customer", JStr cust), ("orders", JNum n), ("total", JNum total), ("avg", JNum (Numeric.div total n))]) totals);
  u1 = writePath "{dir}/totals.json" (J.pretty summary);
  _ = expect "summary JSON" (J.render summary)
    "[\{\"customer\":\"1\",\"orders\":2,\"total\":20,\"avg\":10\},\{\"customer\":\"2\",\"orders\":1,\"total\":5,\"avg\":5\},\{\"customer\":\"3\",\"orders\":1,\"total\":100.01,\"avg\":100.01\}]";

  # CSV out: the cleaned rows, same columns, and the rejects with a reason
  u2 = writePath "{dir}/orders-clean.csv" (C.render (C.table ["order", "customer", "amount", "note"] good));
  u3 = writePath "{dir}/orders-rejected.csv" (C.render (C.table ["order", "reason"] (List.map (fn r -> [("order", unwrap (C.col "order" r)), ("reason", case amount r of Err e -> e | Ok _ -> "")]) bad)));
  expect "cleaned CSV parses back to the cleaned records" (mapOk C.records (C.parse (readPath "{dir}/orders-clean.csv"))) (Ok good).

# ---- 5. across the formats: records <-> JSON objects -------------------------

> rows = unwrap (C.parse orders);
  recs = List.map trim (C.records rows);
  asJson = JArr (List.map J.ofRecord recs);
  hdr :: body = rows;
  back = J.parse (J.render asJson) |>? J.items
    |> mapOk (List.map (fn o -> List.map (fn p -> (k, v) = p; (k, unwrap (J.text v))) (unwrap (J.fields o))));
  _ = expect "records -> JSON -> records" back (Ok recs);
  expect "and back to the same CSV text" (mapOk (fn rs -> C.render (C.table hdr rs)) back)
    (Ok (C.render (List.map (fn r -> List.map Str.trim r) rows))).

> expect "CSV round trip with every special" (C.parse (C.render [["a", "b"], ["x, y", "q\"q"], ["multi\nline", ""]]))
    (Ok [["a", "b"], ["x, y", "q\"q"], ["multi\nline", ""]]).
> expect "CRLF and no trailing newline" (C.parse "a,b\r\n1,2") (Ok [["a", "b"], ["1", "2"]]).
> expect "unterminated quote refused" (isOk (C.parse "a,\"b")) False.
> print "jsoncsv: OK".
