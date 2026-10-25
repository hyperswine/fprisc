{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Ownership vocabulary/substitution independent of either AST or inference.
module Ownership.Shape where

import Ownership.Finding (Finding(..),renderLegacyFinding)
import Data.List ( nub )
import Data.Maybe ( fromMaybe )
import qualified Data.Map.Strict as M
    ( empty,
      toList,
      findWithDefault,
      fromList,
      fromListWith,
      insert,
      unionWith,
      Map )

-- Preserve record fields instead of collapsing them to LL: projecting an
-- owned field moves the record, so we must also account for residual owners.
-- The Bool records an open row whose remaining fields are not yet known.
--
-- Ownership through polymorphism (docs/2026-10-17-OWNERSHIP-POLYMORPHISM.md):
--   LVar a    a value whose type is the type variable `a` of the enclosing
--             signature.  Inside that function it is POSSIBLY owned: used
--             exactly once it moves; used otherwise the function records
--             "a must be unrestricted", and every call that instantiates
--             `a` with an owned shape is refused.  At a call site the
--             callee's variables are instantiated from the actual argument
--             shapes, so `identity : a -> a` hands back the owner it was
--             given and `Box Token` matched against `Box x` binds x owned.
--   LCon n own as
--             a generic type applied to arguments of those shapes (a Box, a
--             Result, a List).  `own` says the type is itself linear-named
--             (`Connection 1 s`): owned whatever its arguments are, but its
--             arguments still instantiate, so a pattern on it binds a field
--             of type `s` to what `s` was given.  A linear-named type with
--             no arguments stays LL.
data LShape
  = LU
  | LL
  | LTupS [LShape]
  | LRecS [(String, LShape)] Bool
  | LVar String
  | LCon String Bool [LShape]
  deriving (Show, Eq)

-- symbolic: a type variable may be instantiated with an owner, so it counts
isLin :: LShape -> Bool
isLin LL = True
isLin (LTupS ss) = any isLin ss
isLin (LRecS fs _) = any (isLin . snd) fs
isLin (LVar _) = True
isLin (LCon _ own as) = own || any isLin as
isLin LU = False

-- owned whatever the type variables turn out to be
hardLin :: LShape -> Bool
hardLin = isLin . eraseVars

-- the shape with every type variable unrestricted (the builtins' view)
eraseVars :: LShape -> LShape
eraseVars = substL M.empty LU

lvars :: LShape -> [String]
lvars = nub . go
  where
    go = \case
      LVar v -> [v]
      LTupS ss -> concatMap go ss
      LRecS fs _ -> concatMap (go . snd) fs
      LCon _ _ as -> concatMap go as
      _ -> []

-- a generic type whose arguments carry no ownership is unrestricted
lcon :: String -> [LShape] -> LShape
lcon n as | any isLin as = LCon n False as
lcon _ _ = LU

-- a linear-named generic type: owned, its arguments kept for instantiation
lown :: String -> [LShape] -> LShape
lown _ [] = LL
lown n as = LCon n True as

-- instantiate: every type variable to its binding, or to `dflt`
substL :: M.Map String LShape -> LShape -> LShape -> LShape
substL b dflt = go
  where
    go = \case
      LVar v -> M.findWithDefault dflt v b
      LTupS ss -> LTupS (map go ss)
      LRecS fs open -> LRecS [(f, go t) | (f, t) <- fs] open
      LCon n True as -> LCon n True (map go as)
      LCon n False as -> lcon n (map go as)
      s -> s

-- what a declared shape's type variables are, given the actual shape
matchL :: LShape -> LShape -> [(String, LShape)]
matchL (LVar v) s = [(v, s)]
matchL (LTupS as) (LTupS bs) | length as == length bs = concat (zipWith matchL as bs)
matchL (LRecS fs _) (LRecS gs _) = concat [matchL t u | (f, t) <- fs, Just u <- [lookup f gs]]
matchL (LCon n _ as) (LCon m _ bs) | n == m, length as == length bs = concat (zipWith matchL as bs)
matchL _ _ = []

bindingsL :: [LShape] -> [LShape] -> M.Map String LShape
bindingsL decl actual = M.fromListWith joinLShape (concat (zipWith matchL decl actual))

-- an obligation on a shape: owned for sure is an error; owned only if a
-- type variable is instantiated with an owner becomes a constraint on that
-- variable (an obligation the clause checker collects, never an error)
demandOwnership :: LShape -> String -> [Finding]
demandOwnership s msg
  | hardLin s = [Violation Nothing msg]
  | isLin s = [RequireUnrestricted v | v <- lvars s]
  | otherwise = []

-- Old helper API projections. The frontend uses the typed functions below.
demandL :: LShape -> String -> [String]
demandL shape message=map renderLegacyFinding (demandOwnership shape message)

constraintMark :: String -> String
constraintMark v = '\1' : v

isConstraintMark :: String -> Bool
isConstraintMark ('\1' : _) = True
isConstraintMark _ = False

-- A case result must retain ownership from every live arm. In particular an
-- unrestricted first arm cannot erase a linear closure returned by a later arm.
joinLShape :: LShape -> LShape -> LShape
joinLShape LU b = b
joinLShape a LU = a
joinLShape (LVar a) (LVar b) | a == b = LVar a
joinLShape (LCon n o as) (LCon m p bs) | n == m, length as == length bs = (if o || p then LCon n True else lcon n) (zipWith joinLShape as bs)
joinLShape (LTupS as) (LTupS bs) | length as == length bs = LTupS (zipWith joinLShape as bs)
joinLShape (LRecS as ar) (LRecS bs br) = LRecS (M.toList (M.unionWith joinLShape (M.fromList as) (M.fromList bs))) (ar || br)
joinLShape _ _ = LL

projectOwnership :: [String] -> LShape -> ([Finding], LShape)
projectOwnership [] sh = ([], sh)
projectOwnership (field : path) sh = case sh of
  LRecS fs open ->
    let residual = [f | (f, s) <- fs, f /= field, isLin s]
        errs = concat [demandOwnership s ("record projection discards linear field(s) " ++ show residual ++ "; destructure all owned fields together") | (f, s) <- fs, f /= field, isLin s]
          ++ concat [demandOwnership sh "cannot project from an owned record with an open row; its remaining owners are unknown" | open]
        (nested, result) = projectOwnership path (fromMaybe LU (lookup field fs))
     in (errs ++ nested, result)
  _ -> ([], LU)

updateOwnership :: [String] -> LShape -> LShape -> ([Finding], LShape)
updateOwnership [] new old =
  (demandOwnership old "record update discards an owned field; destructure and consume it before replacement", new)
updateOwnership (field : path) new sh =
  let (fs, open) = case sh of LRecS old row -> (old, row); _ -> ([], False)
      (errs, result) = updateOwnership path new (fromMaybe LU (lookup field fs))
      unknown = concat [demandOwnership sh "cannot replace an unknown field in an owned open record; its ownership is unknown" | open, field `notElem` map fst fs]
   in (unknown ++ errs, LRecS (M.toList (M.insert field result (M.fromList fs))) open)

projectLShape :: [String] -> LShape -> ([String], LShape)
projectLShape fields shape=let (findings,result)=projectOwnership fields shape
  in (map renderLegacyFinding findings,result)
updateLShape :: [String] -> LShape -> LShape -> ([String], LShape)
updateLShape fields new old=let (findings,result)=updateOwnership fields new old
  in (map renderLegacyFinding findings,result)
