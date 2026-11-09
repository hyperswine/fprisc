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
      m@(LCon "->" False as) | all (== LU) as -> m -- a callable's arity, no owners
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
joinLShape a b | a == b = a
joinLShape LU b = b
joinLShape a LU = a
joinLShape (LVar a) (LVar b) | a == b = LVar a
joinLShape (LCon n o as) (LCon m p bs) | n == m, length as == length bs = (if o || p then LCon n True else lcon n) (zipWith joinLShape as bs)
joinLShape (LTupS as) (LTupS bs) | length as == length bs = LTupS (zipWith joinLShape as bs)
joinLShape (LRecS as ar) (LRecS bs br) = LRecS (M.toList (M.unionWith joinLShape (M.fromList as) (M.fromList bs))) (ar || br)
-- Two callables (a callable parameter, a closure, an arity marker): the
-- join holds what either holds, and stays symbolic, instead of collapsing
-- to a sure owner (a case returning one of two callback parameters).
joinLShape a b | Just xs <- callableOwners a, Just ys <- callableOwners b = lcon "fn" (nub (xs ++ ys))
joinLShape _ _ = LL

-- the owners a callable-shaped value holds, when it is one
callableOwners :: LShape -> Maybe [LShape]
callableOwners = \case
  LVar v | isFnVar v -> Just [LVar v]
  LCon "fn" False xs -> Just xs
  LCon "->" False as | all (== LU) as -> Just []
  _ -> Nothing

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

-- Callable ownership (docs/2026-11-09-CALLABLE-OWNERSHIP.md).
--
-- A function-typed PARAMETER of a signature is symbolic, exactly like a
-- type variable: the argument may be a single-use closure (one that
-- captured an owner), so a body that calls or copies the parameter more
-- than once, or never uses it, records "this callable must be
-- unrestricted" and every call passing a linear closure there is refused.
-- The variable is named "->i" (no source type variable can be spelled so).
-- The name also records how many arguments the parameter takes, so a call
-- that supplies fewer is known to be a partial application.
fnParamShape :: Int -> Int -> LShape
fnParamShape i k = LVar (fnVarName i k)

fnVarName :: Int -> Int -> String
fnVarName i k = fnPathName [i] k

-- A function type NESTED in a parameter (`((Int -> Int), Int)`, a record
-- field, a `List (Int -> Int)`) is symbolic too; its variable is named by
-- the path to it, "->0.1/1", the first index being the parameter.
fnPathName :: [Int] -> Int -> String
fnPathName path k = "->" ++ dotted path ++ "/" ++ show k
  where
    dotted [] = "0"
    dotted [i] = show i
    dotted (i : is) = show i ++ "." ++ dotted is

-- (parameter position, arity) of a callable parameter variable
fnVarInfo :: String -> Maybe (Int, Int)
fnVarInfo ('-' : '>' : rest) = case break (== '/') rest of
  (path, '/' : k) | [(iv, "")] <- reads (takeWhile (/= '.') path), [(kv, "")] <- reads k -> Just (iv, kv)
  _ -> Nothing
fnVarInfo _ = Nothing

-- (parameter position, nested?) for a diagnostic
fnVarNested :: String -> Bool
fnVarNested v = '.' `elem` takeWhile (/= '/') v

-- A function type nested in a RESULT (`Token -> ((Int -> Int), Int)`) is
-- this variable.  A call binds it to the owners the closure may hold: the
-- owned arguments, and an owner of the callee's own when its body returns a
-- single-use closure there (the callee then carries heldVar among its
-- obligations).  Unbound, it is unrestricted.
heldVar :: String
heldVar = "->held"

-- A function type in a constructor FIELD, for the construction check: a
-- single-use closure stored there is invisible to the constructed value's
-- type, so constructing one is refused (or, over a callable parameter,
-- constrains that parameter to be unrestricted).
fieldVar :: String
fieldVar = "->field"

-- A body whose result, at a function position, holds a closure over a
-- SYMBOLIC owner (a parameter of type `a`, a callable parameter) records
-- heldOf v: a call's result then holds whatever the call passed for v.
heldOf :: String -> String
heldOf v = heldVar ++ ":" ++ v

heldOfVar :: String -> Maybe String
heldOfVar r = case splitAt (length heldVar + 1) r of
  (p, v) | p == heldVar ++ ":" -> Just v
  _ -> Nothing

-- the symbolic owners a body's result holds at the declared function
-- positions (see heldAt)
heldVarsAt :: LShape -> LShape -> [String]
heldVarsAt decl body = case (decl, body) of
  (LVar v, b) | v == heldVar -> lvars b
  (LCon "->" False as, b) | all (== LU) as -> lvars b
  (LTupS ds, LTupS bs) | length ds == length bs -> concat (zipWith heldVarsAt ds bs)
  (LRecS ds _, LRecS bs _) -> concat [heldVarsAt d b | (f, d) <- ds, Just b <- [lookup f bs]]
  (LCon n _ ds, LCon m _ bs) | n == m, length ds == length bs -> concat (zipWith heldVarsAt ds bs)
  _ -> []

-- Does a body's result hold an owner for sure at a position where the
-- declared result has a function type?  Then the function's result is a
-- single-use closure even when its arguments are unrestricted.
heldAt :: LShape -> LShape -> Bool
heldAt decl body = case (decl, body) of
  (LVar v, b) | v == heldVar -> hardLin b
  (LCon "->" False as, b) | all (== LU) as -> hardLin b
  (LTupS ds, LTupS bs) | length ds == length bs -> or (zipWith heldAt ds bs)
  (LRecS ds _, LRecS bs _) -> or [heldAt d b | (f, d) <- ds, Just b <- [lookup f bs]]
  (LCon n _ ds, LCon m _ bs) | n == m, length ds == length bs -> or (zipWith heldAt ds bs)
  _ -> False

isFnVar :: String -> Bool
isFnVar ('-' : '>' : _) = True
isFnVar _ = False

-- A function-typed RESULT of k further parameters.  It is unrestricted
-- (isLin is False, and substitution collapses it to LU); only its arity is
-- read, so a call that supplies the declared parameters but not the ones the
-- returned function takes is a partial application, and a partial
-- application over an owner is a single-use closure.
fnResultShape :: Int -> LShape
fnResultShape k | k > 0 = LCon "->" False (replicate k LU)
fnResultShape _ = LU

fnResultArity :: LShape -> Int
fnResultArity (LCon "->" False as) | all (== LU) as = length as
fnResultArity _ = 0

-- How many arguments a function value with this shape takes, when known:
-- a callable parameter, or a function name or field read through its type.
callableArity :: LShape -> Maybe Int
callableArity (LVar v) = snd <$> fnVarInfo v
callableArity s = case fnResultArity s of
  0 -> Nothing
  k -> Just k

-- Primitives have no body for the checker to read, so the ones that call
-- their callback once per element or per iteration say so here: a
-- single-use closure is refused there exactly as at a source function that
-- calls its parameter twice.  (A primitive that calls its callback once,
-- like `Sys.arena` or `spawn`, is not listed.)
repeatedCallbackPrims :: [String]
repeatedCallbackPrims =
  ["Vec.map", "Vec.mapSame", "Vec.filter", "Vec.fold", "Sys.loop", "Sys.loopWith",
   -- HostedBytecode's list schemes (Sol.Infer.solBuiltins), which the
   -- Sol prelude's List.map / List.filter / List.foldl reach
   "map", "filter", "foldl"]

-- The ownership of a closure that holds these values: owned if any is
-- (surely or symbolically), unrestricted otherwise.  Unlike a join it
-- keeps distinct type variables symbolic instead of collapsing them to LL,
-- so a generic helper that builds a closure over its argument constrains
-- that argument rather than failing outright.
closureShape :: [LShape] -> LShape
closureShape = lcon "fn" . filter isLin
