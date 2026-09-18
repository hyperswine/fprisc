# rx.sol -- a regex the size of a coffee break: literals . * + ? ^ $ [a-z]
# [^..] \d \w \s, backtracking over the subject as a LIST OF CODES
# (Str.codes: one pass; indexing a string is O(i) in this VM).  Enough
# for the grep/sed patterns one actually types.
#   rx.sol PATTERN FILE          lines matching (grep -E)
#   rx.sol -o PATTERN FILE       the first match of each matching line (grep -o)
unsafe program.

# ---- the pattern: atoms (kind code negated classId quant) + a class table ----
# kind: 1 char | 2 any | 3 class | 4 \d | 5 \w | 6 \s | 7 ^ | 8 $
# quant: 0 one | 1 star | 2 plus | 3 opt
Atom = Type (Atom Int Int Int Int Int).
Cls  = Type (Cls Int (List (Int, Int))).
Res  = Type (Hit (List Int) | Miss).
boolInt b = case b of True -> 1 | False -> 0.
rev xs = List.fold (fn acc x -> x :: acc) [] xs.

parseRx s = parseAt s 1 [] [].
parseAt s i atoms classes | i > Str.len s = (rev atoms, rev classes).
parseAt s i atoms classes =
  c = charAt s i;
  case c == 94 of
    True -> parseAt s (i + 1) (Atom 7 0 0 0 0 :: atoms) classes
  | False -> (case c == 36 of
        True -> parseAt s (i + 1) (Atom 8 0 0 0 0 :: atoms) classes
      | False -> parseAtom s i atoms classes).
parseAtom s i atoms classes =
  c = charAt s i;
  (atom, j, classes2) = (case c == 46 of
        True -> (Atom 2 0 0 0 0, i + 1, classes)
      | False -> (case c == 92 of
            True -> (escAtom (charAt s (i + 1)), i + 2, classes)
          | False -> (case c == 91 of
                True -> parseClass s (i + 1) classes
              | False -> (Atom 1 c 0 0 0, i + 1, classes))));
  (q, k) = quantAt s j;
  parseAt s k (withQuant atom q :: atoms) classes2.
escAtom c = case c == 100 of True -> Atom 4 0 0 0 0
  | False -> (case c == 119 of True -> Atom 5 0 0 0 0
  | False -> (case c == 115 of True -> Atom 6 0 0 0 0
  | False -> Atom 1 c 0 0 0)).
withQuant (Atom k c n r _) q = Atom k c n r q.
quantAt s j | j > Str.len s = (0, j).
quantAt s j = c = charAt s j;
  case c == 42 of True -> (1, j + 1)
  | False -> (case c == 43 of True -> (2, j + 1)
  | False -> (case c == 63 of True -> (3, j + 1) | False -> (0, j))).
parseClass s i classes =
  neg = boolInt (charAt s i == 94);
  (pairs, j) = classPairs s (i + neg) [];
  (Atom 3 0 neg (List.len classes + 1) 0, j, Cls neg pairs :: classes).
classPairs s i acc | charAt s i == 93 = (rev acc, i + 1).
classPairs s i acc =
  c = charAt s i;
  case and (charAt s (i + 1) == 45) (charAt s (i + 2) != 93) of
    True -> classPairs s (i + 3) ((c, charAt s (i + 2)) :: acc)
  | False -> classPairs s (i + 1) ((c, c) :: acc).

# ---- one code against one atom ------------------------------------------------
pairIn c (lo, hi) = and (c >= lo) (c <= hi).
inPairs c pairs = List.len (List.filter (pairIn c) pairs) > 0.
isDigit c = and (c >= 48) (c <= 57).
isWord c = or (or (isDigit c) (and (c >= 97) (c <= 122))) (or (and (c >= 65) (c <= 90)) (c == 95)).
classHit (Cls n pairs) c = xor (n == 1) (inPairs c pairs).
one (Atom k code neg id _) classes c = case k of
    1 -> c == code
  | 2 -> c != 10
  | 3 -> classHit (classes ! id) c
  | 4 -> isDigit c
  | 5 -> isWord c
  | 6 -> Str.isSpace c
  | _ -> False.
quantOf (Atom _ _ _ _ q) = q.

# ---- the matcher: Hit rest | Miss; bol says "nothing consumed yet on this line" --
m atoms classes cs bol = case atoms of
    [] -> Hit cs
  | (Atom 7 _ _ _ _) :: r -> (case bol of True -> m r classes cs bol | False -> Miss)
  | (Atom 8 _ _ _ _) :: r -> (case cs of [] -> m r classes cs bol | _ -> Miss)
  | a :: r -> (case quantOf a of
        0 -> step a r classes cs
      | 1 -> star a r classes cs bol
      | 2 -> (case cs of
            [] -> Miss
          | c :: t -> (case one a classes c of True -> star a r classes t False | False -> Miss))
      | _ -> (case step a r classes cs of Miss -> m r classes cs bol | h -> h)).
step a r classes cs = case cs of
    [] -> Miss
  | c :: t -> (case one a classes c of True -> m r classes t False | False -> Miss).
# greedy star: the tails after 0..n atoms of the run, tried longest first
star a r classes cs bol = tryAll r classes (rev (runTails a classes cs)) bol.
runTails a classes cs = cs :: (case cs of
    [] -> []
  | c :: t -> (case one a classes c of True -> runTails a classes t | False -> [])).
tryAll r classes cands bol = case cands of
    [] -> Miss
  | c :: more -> (case m r classes c (case more of [] -> bol | _ -> False) of
        Miss -> tryAll r classes more bol
      | h -> h).

# ---- search: the first suffix that matches -> (consumed codes, rest) -------------
search (atoms, classes) cs = searchAt atoms classes cs True.
searchAt atoms classes cs bol = case m atoms classes cs bol of
    Hit rest -> Hit rest
  | Miss -> (case cs of [] -> Miss | c :: t -> searchAt atoms classes t False).
matches rx line = case search rx (Str.codes line) of Miss -> False | _ -> True.
firstMatch rx line =
  cs = Str.codes line;
  case searchSpan rx cs of
    (0, _) -> ""
  | (n, from) -> Str.join "" (List.map chr (List.take n from)).
# the span: walk suffixes until one matches; n = consumed = len suffix - len rest
searchSpan (atoms, classes) cs = spanAt atoms classes cs True.
spanAt atoms classes cs bol = case m atoms classes cs bol of
    Hit rest -> (List.len cs - List.len rest, cs)
  | Miss -> (case cs of [] -> (0, []) | c :: t -> spanAt atoms classes t False).

execute argv = case argv of
    "-o" :: pat :: path :: [] -> rx = parseRx pat;
        u = map (fn l -> print (firstMatch rx l)) (List.filter (matches rx) (Str.lines (readPath path))); Unit
  | pat :: path :: [] -> rx = parseRx pat;
        u = map print (List.filter (matches rx) (Str.lines (readPath path))); Unit
  | _ -> error "usage: rx.sol [-o] PATTERN FILE".
> execute (args Unit).
