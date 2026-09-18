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

module Exhaust (Siblings, checkArms, siblingsOf) where

import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing, mapMaybe)
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

describe :: SPat -> String
describe = \case
  PCon c [] -> c
  PCon c ps -> c ++ " " ++ unwords (map describeArg ps)
  PInt n -> show n
  PStr s -> show s
  PTup ps -> "(" ++ concatMap (\p -> describe p ++ ", ") (init ps) ++ describe (last ps) ++ ")"
  PVar v -> v
  PWild -> "_"
  PRec _ -> "a record"
  PSig v _ -> v
  where
    describeArg p@PCon {} = "(" ++ describe p ++ ")"
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
