{-# LANGUAGE LambdaCase #-}

-- Case-arm coverage: every `case` must be exhaustive and no arm may be
-- unreachable.  Both are plain bugs on their own, and together they
-- close the one hole the arm grammar leaves open: a `case` written
-- unparenthesized inside a NON-final arm takes every arm after it
--
--     case x of True -> case y of A -> 1 | B -> 2 | False -> 3
--
-- parses with the inner case owning `False -> 3`.  Whatever the types,
-- that shape now fails to compile: either the inner case ends up with
-- an arm it can never reach, or the outer case is left with a single
-- constructor arm and is no longer exhaustive.  Parenthesize the inner
-- case (or move it to the final arm) and both checks are quiet again.
--
-- The check is Maranget's usefulness relation over pattern matrices:
-- an arm is unreachable when its pattern is not useful after the arms
-- before it; the case is exhaustive when a wildcard is not useful
-- after all of its arms.  Constructor sets come from the inference
-- constructor environment (user types and Bool); Int and String
-- literals never form a complete set, so a case over them needs a
-- catch-all arm.  Record patterns bind fields and never fail, so they
-- count as irrefutable.

module Exhaust (Siblings, checkArms, checkClauses, siblingsOf) where

import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing, listToMaybe, mapMaybe)
import FPRISC (Name, SPat (..))

-- the constructors of a constructor's type, with their arities
type Siblings = Name -> Maybe [(Name, Int)]

-- constructor heads a pattern can start with
data Head = HCon Name | HInt Integer | HStr String | HTup Int
  deriving (Eq, Show)

-- Nothing: the pattern matches anything (a variable, `_`, a record
-- pattern or a sig-constrained parameter)
headOf :: SPat -> Maybe (Head, [SPat])
headOf = \case
  PCon c ps -> Just (HCon c, ps)
  PInt n -> Just (HInt n, [])
  PStr s -> Just (HStr s, [])
  PTup ps -> Just (HTup (length ps), ps)
  _ -> Nothing

showHead :: Head -> String
showHead = \case
  HCon c -> c
  HInt n -> show n
  HStr s -> show s
  HTup n -> "a " ++ show n ++ "-tuple"

-- the arms of one case, in order -> the errors to report
checkArms :: Siblings -> [SPat] -> [String]
checkArms sibs pats = unreachable ++ missing
  where
    rows = map pure pats
    -- only an arm with a refutable head is reported: a trailing `_`
    -- after every constructor is how actor loops queue the messages
    -- the static type does not name (`receive` is unsafe by design)
    unreachable =
      [ "case: the arm for " ++ describe p ++ " can never match -- the arms before it already cover it"
          ++ " (a `case` nested in a non-final arm takes the arms after it; parenthesize it)"
        | (i, p) <- zip [0 :: Int ..] pats,
          Just _ <- [headOf p],
          not (useful sibs (take i rows) [p])
      ]
    missing = ["case: not exhaustive -- " ++ witness | useful sibs rows [PWild]]
    witness = case nub [h | p <- pats, Just (h, _) <- [headOf p]] of
      [] -> "no arm matches"
      hs@(HCon c : _)
        | Just sib <- sibs c,
          absent@(_ : _) <- [n | (n, _) <- sib, HCon n `notElem` hs] ->
            "no arm matches " ++ unwordsOr absent
      hs@(HCon _ : _) -> "some value under " ++ unwordsOr (map showHead hs) ++ " is not matched by any arm"
      hs@(HTup _ : _) -> "some value under " ++ unwordsOr (map showHead hs) ++ " is not matched by any arm"
      hs -> "add a catch-all arm (`_ -> ...`) after " ++ unwordsOr (map showHead hs)
    unwordsOr [x] = x
    unwordsOr xs = concat (zipWith (++) ("" : replicate (length xs - 2) ", " ++ [" or "]) xs)

-- ---- clause coverage -------------------------------------------------------
--
-- `case` has been checked since the arm grammar made it necessary; a
-- function's CLAUSES were not, and a value matching none of them fell
-- through to a runtime error ("no matching clause for f").  That is the
-- same bug the case checker exists to prevent, one syntax over -- and the
-- worse one, because it is the definition's own shape that is incomplete.
--
-- The relation is identical, just wider: one column per parameter instead
-- of one.  `useful` already works on matrices, so only the question
-- changes.
--
-- A GUARDED clause never counts as covering: its patterns can match and
-- its guard still pass the value on to the next clause.  So the matrix is
-- built from the unguarded clauses alone -- which is equally why a guarded
-- clause cannot make a later one unreachable.
checkClauses :: Siblings -> Name -> [([SPat], Bool)] -> [String]
checkClauses sibs f cls
  | null cls = []
  | arity == 0 = [] -- a value, not a function: nothing to match on
  | any ((/= arity) . length . fst) cls = [] -- arity disagreement is its own error
  | otherwise = case witness sibs arity [ps | (ps, False) <- cls] of
      Nothing -> []
      -- no "in NAME:" prefix here: the caller adds it, which is what lets
      -- the diagnostic sink resolve the message to a file and line
      Just w ->
        [ "the clauses are not exhaustive -- nothing matches `"
            ++ unwords (f : map describeArg w)
            ++ "` (add a clause for it, or a catch-all)"
        ]
  where
    arity = length (fst (head cls))

-- A vector of values no row matches, when one exists: Maranget's I, the
-- counterexample that falls out of the same specialization the usefulness
-- test uses.  It is what lets the message name the missing case instead of
-- merely asserting that one exists.
witness :: Siblings -> Int -> [[SPat]] -> Maybe [SPat]
witness _ 0 rows = if null rows then Just [] else Nothing
witness sibs n rows = case complete sibs heads of
  Just all' ->
    listToMaybe
      [ rebuilt
        | (h, a) <- all',
          Just w <- [witness sibs (a + n - 1) (specialize h a rows)],
          let (args, rest) = splitAt a w,
          let rebuilt = patOf h args : rest
      ]
  Nothing -> do
    rest <- witness sibs (n - 1) [ps | (p : ps) <- rows, isNothing (headOf p)]
    pure (absent : rest)
  where
    heads = nub [h | (p : _) <- rows, Just (h, _) <- [headOf p]]
    absent = case heads of
      [] -> PWild
      HCon c : _
        | Just sib <- sibs c,
          (n', a) : _ <- [(m, a') | (m, a') <- sib, HCon m `notElem` heads] ->
            PCon n' (replicate a PWild)
      HInt _ : _ -> PInt (head [i | i <- [0 ..], HInt i `notElem` heads])
      HStr _ : _ -> PStr (head [s | s <- "" : ["x" ++ replicate k '\'' | k <- [0 ..]], HStr s `notElem` heads])
      _ -> PWild

patOf :: Head -> [SPat] -> SPat
patOf h args = case h of
  HCon c -> PCon c args
  HInt i -> PInt i
  HStr s -> PStr s
  HTup _ -> PTup args

describe :: SPat -> String
describe = \case
  PCon c [] -> c
  -- a list is written with its operator, not its constructor's name
  PCon "Cons" [h, t] -> describeArg h ++ " :: " ++ describeArg t
  PCon c ps -> c ++ " " ++ unwords (map describeArg ps)
  PInt n -> show n
  PStr s -> show s
  PTup ps -> "(" ++ concatMap (\p -> describe p ++ ", ") (init ps) ++ describe (last ps) ++ ")"
  PVar v -> v
  PWild -> "_"
  PRec _ -> "a record"
  PSig v _ -> v

-- as an ARGUMENT: only a constructor that carries fields needs parentheses
describeArg :: SPat -> String
describeArg p@(PCon _ (_ : _)) = "(" ++ describe p ++ ")"
describeArg p = describe p

-- the complete constructor set the column's heads belong to, when the
-- heads present already cover all of it (Maranget's Σ complete test)
complete :: Siblings -> [Head] -> Maybe [(Head, Int)]
complete sibs heads = case heads of
  HTup n : _ -> Just [(HTup n, n)]
  HCon c : _ -> do
    sib <- sibs c
    let all' = [(HCon n, a) | (n, a) <- sib]
    if all ((`elem` heads) . fst) all' then Just all' else Nothing
  _ -> Nothing

-- is the vector q useful after the rows (can a value match q and no row)?
useful :: Siblings -> [[SPat]] -> [SPat] -> Bool
useful _ [] _ = True
useful _ _ [] = False
useful sibs rows (q : qs) = case headOf q of
  Just (h, args) -> useful sibs (specialize h (length args) rows) (args ++ qs)
  Nothing ->
    let heads = nub (mapMaybe (fmap fst . headOf . head) rows)
     in case complete sibs heads of
          Just all' -> any (\(h, a) -> useful sibs (specialize h a rows) (replicate a PWild ++ qs)) all'
          Nothing -> useful sibs [ps | (p : ps) <- rows, isNothing (headOf p)] qs

specialize :: Head -> Int -> [[SPat]] -> [[SPat]]
specialize h a rows =
  [ args ++ ps
    | (p : ps) <- rows,
      Just args <- [case headOf p of
                      Just (h', args) | h' == h -> Just args
                      Just _ -> Nothing
                      Nothing -> Just (replicate a PWild)]
  ]

-- derive the sibling relation from a "constructor -> result type name,
-- arity" table: every constructor whose scheme lands in the same type
siblingsOf :: [(Name, (Name, Int))] -> Siblings
siblingsOf table = \c -> do
  (ty, _) <- M.lookup c byCon
  M.lookup ty byType
  where
    byCon = M.fromList table
    byType = M.fromListWith (flip (++)) [(ty, [(c, a)]) | (c, (ty, a)) <- table]
