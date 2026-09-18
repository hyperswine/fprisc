# interactive_script.sol -- a railway-oriented line calculator.
#
# The lexer and evaluator are total recursive functions with checked measures.
# readLineNow is deliberately realtime: an interactive session cannot be
# replayed as one whole-script transaction. Enter a blank line, `quit`, or
# `exit` to leave.

CalcOperator = Type (AddOp | SubOp | MulOp | DivOp | NegOp | PosOp | LeftOp).
CalcToken = Type (CalcNum Int Int | CalcOp CalcOperator Int Int | CalcLeft Int | CalcRight Int).

isDigit c = and (c >= 48) (c <= 57).
isNumberChar c = or (isDigit c) (c == 46).

decimalText raw =
  front = case Str.at raw 1 == 46 of True -> "0{raw}" | False -> raw;
  case Str.at front (Str.len front) == 46 of
    True -> "{front}0"
  | False -> front.

numberToken raw column = case raw == "." of
  True -> Err "expected a number at column {column}"
| False -> Try.parseNum (decimalText raw) |> mapOk (fn value -> CalcNum value column).

symbolToken c column = case c of
  43 -> Ok (CalcOp AddOp 1 column)
  | 45 -> Ok (CalcOp SubOp 1 column)
  | 42 -> Ok (CalcOp MulOp 2 column)
  | 47 -> Ok (CalcOp DivOp 2 column)
  | 40 -> Ok (CalcLeft column)
  | 41 -> Ok (CalcRight column)
  | _ -> Err "unexpected character '{Str.fromCode c}' at column {column}".

# One measured character walk emits tokens in reverse, then flips them once.
lexChars : String -> (i : Int | measure (limit - i)) -> (limit : Int) -> Int -> String -> Int -> List CalcToken -> Result (List CalcToken) String .
lexChars s i limit mode raw start acc | i > limit = case mode of
  0 -> Ok (List.rev acc)
  | _ -> numberToken raw start |> mapOk (fn token -> List.rev (token :: acc)).
lexChars s i limit mode raw start acc =
  c = Str.at s i;
  case isNumberChar c of
    True -> (case mode of
      0 -> lexChars s (i + 1) limit 1 (Str.fromCode c) i acc
      | _ -> lexChars s (i + 1) limit 1 "{raw}{Str.fromCode c}" start acc)
  | False -> (case Str.isSpace c of
      True -> (case mode of
        0 -> lexChars s (i + 1) limit 0 "" 0 acc
        | _ -> numberToken raw start
            |>? (fn token -> lexChars s (i + 1) limit 0 "" 0 (token :: acc)))
    | False -> (case mode of
        0 -> symbolToken c i
            |>? (fn token -> lexChars s (i + 1) limit 0 "" 0 (token :: acc))
        | _ -> numberToken raw start
            |>? (fn number -> symbolToken c i
          |>? (fn symbol -> lexChars s (i + 1) limit 0 "" 0 (symbol :: number :: acc))))).

tokenize source = lexChars source 1 (Str.len source) 0 "" 0 [].

isUnary op = case op of NegOp -> True | PosOp -> True | _ -> False.
isLeft op = case op of LeftOp -> True | _ -> False.

applyOperator op column values = case op of
    NegOp -> (case values of
        value :: rest -> Ok ((0 - value) :: rest)
      | _ -> Err "missing value for unary '-' at column {column}")
  | PosOp -> (case values of
      value :: rest -> Ok (value :: rest)
    | _ -> Err "missing value for unary '+' at column {column}")
  | _ -> (case values of
      right :: left :: rest -> (case op of
          AddOp -> Ok ((left + right) :: rest)
        | SubOp -> Ok ((left - right) :: rest)
        | MulOp -> Ok ((left * right) :: rest)
        | DivOp -> (case right == 0 of
              True -> Err "division by zero"
            | False -> Ok ((Numeric.div left right) :: rest))
        | _ -> Err "unknown calculator operator")
    | _ -> Err "missing value for operator at column {column}").

reduceUnary : (operators : List (CalcOperator, Int, Int) | measure operators) -> List Int -> Result (List Int, List (CalcOperator, Int, Int)) String .
reduceUnary operators values = case operators of
  [] -> Ok (values, [])
  | (op, priority, column) :: rest -> case isUnary op of
        False -> Ok (values, operators)
      | True -> applyOperator op column values |>? (fn nextValues -> reduceUnary rest nextValues).

reduceFor : (operators : List (CalcOperator, Int, Int) | measure operators) -> List Int -> Int -> Result (List Int, List (CalcOperator, Int, Int)) String .
reduceFor operators values incoming = case operators of
  [] -> Ok (values, [])
  | (op, priority, column) :: rest -> case or (isLeft op) (priority < incoming) of
      True -> Ok (values, operators)
      | False -> applyOperator op column values
          |>? (fn nextValues -> reduceFor rest nextValues incoming).

reduceGroup : (operators : List (CalcOperator, Int, Int) | measure operators) -> List Int -> Int -> Result (List Int, List (CalcOperator, Int, Int)) String .
reduceGroup operators values closeColumn = case operators of
  [] -> Err "unmatched ')' at column {closeColumn}"
  | (op, priority, column) :: rest -> case isLeft op of
      True -> Ok (values, rest)
      | False -> applyOperator op column values
          |>? (fn nextValues -> reduceGroup rest nextValues closeColumn).

finishOperators : (operators : List (CalcOperator, Int, Int) | measure operators) -> List Int -> Result (List Int) String .
finishOperators operators values = case operators of
  [] -> Ok values
| (op, priority, column) :: rest -> case isLeft op of
    True -> Err "unmatched '(' at column {column}"
  | False -> applyOperator op column values |>? (fn nextValues -> finishOperators rest nextValues).

finishValue values = case values of
  [value] -> Ok value
| _ -> Err "incomplete expression".

# Shunting-yard state: value stack, operator stack, then whether a value is
# expected. Every recursive call consumes the strict tail of `tokens`.
consume : (tokens : List CalcToken | measure tokens) -> List Int -> List (CalcOperator, Int, Int) -> Bool -> Result Int String .
consume tokens values operators expectValue = case tokens of
  [] -> (case expectValue of
      True -> Err "expected a number or '(' at end of input"
    | False -> finishOperators operators values |>? finishValue)
  | token :: rest -> case token of
    CalcNum value column -> (case expectValue of
      False -> Err "expected an operator at column {column}"
    | True -> reduceUnary operators (value :: values)
          |>? (fn state -> (nextValues, nextOperators) = state;
                consume rest nextValues nextOperators False))
    | CalcLeft column -> (case expectValue of
        False -> Err "expected an operator at column {column}"
      | True -> consume rest values ((LeftOp, 0, column) :: operators) True)
    | CalcRight column -> (case expectValue of
        True -> Err "expected a number before ')' at column {column}"
      | False -> reduceGroup operators values column
            |>? (fn grouped -> (groupValues, groupOperators) = grouped;
                  reduceUnary groupOperators groupValues)
            |>? (fn state -> (nextValues, nextOperators) = state;
                  consume rest nextValues nextOperators False))
    | CalcOp op priority column -> (case expectValue of
        True -> (case op of
          AddOp -> consume rest values ((PosOp, 3, column) :: operators) True
        | SubOp -> consume rest values ((NegOp, 3, column) :: operators) True
        | _ -> Err "expected a number before operator at column {column}")
      | False -> reduceFor operators values priority
            |>? (fn state -> (nextValues, nextOperators) = state;
                              consume rest nextValues ((op, priority, column) :: nextOperators) True)).

evaluate source = tokenize source |>? (fn tokens -> consume tokens [] [] True).

resultText result = case result of
  Ok value -> "= {value}"
  | Err e -> "error: {e}".

# A CLI session is intentionally bounded so its recursion has a real measure.
# One million turns is effectively open-ended for a human while remaining an
# honest static bound.
repl : (turns : Int | measure turns) -> Unit .
repl turns | turns <= 0 = print "session limit reached".
repl turns =
  prompt = print "> expr";
  line = Str.trim (readLineNow Unit);
  case or (line == "") (or (line == "quit") (line == "exit")) of
    True -> print "bye"
  | False -> shown = print (resultText (evaluate line));
                     repl (turns - 1).

> repl 1000000.
