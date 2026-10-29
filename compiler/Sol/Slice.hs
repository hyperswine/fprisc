-- Sol/Slice.hs — demand-driven prelude slicing (docs/2026-10-29-SOL-INCREMENTAL-PRELUDE.md).
--
-- The prelude is ~450 lines of declarations; a script or REPL command uses a
-- handful.  Every compile used to parse, typecheck, specialize, lower and
-- bytecode-compile all of it, then shake away what the run cannot reach.
-- `slicePrelude` keeps only the prelude declarations the user program can
-- name -- the closure, over-approximated by every identifier-like string in
-- the program text -- so the unchanged whole-program pipeline runs over a
-- small program.  Over-inclusion is always safe; the caller treats any
-- rejection of the sliced program as "inconclusive" and recompiles with the
-- full prelude, so diagnostics are always the full pipeline's.
module Sol.Slice (slicePrelude, sliceIndices, mentions, injectedNames, shapeSeed, orderedShapes) where

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (foldl', sortOn)
import Frontend.Syntax (STop (..), Ty (TOther))
import Sol.Lang (Name)

-- Names the compiler introduces AFTER the point where the program is
-- sliced (desugarings, precondition splices, literal splices; `%` and `^`
-- resolve to Int.mod / Int.pow).  Kept whenever the prelude defines them.
-- Path codecs (wire*) are introduced before slicing and found as mentions.
injectedNames :: [Name]
injectedNames =
  [ "and", "or", "not", "and2", "or2", "error", "Ok", "Err", "Result", "Cons", "Nil", "True", "False", "Unit", "Bool"
  , "Path", "Int.mod", "Int.pow", "String", "$cast", "$unsafe", "main"
  , "measure", "mulMV", "mulMM", "f64frombits", "f32frombits", "Vec.newAs", "Vec.map"
  ]

-- Every string literal in the shown syntax tree, plus its dotted prefixes
-- (`Str.len` also mentions `Str`).
mentions :: Show a => a -> S.Set Name
mentions x = S.fromList (concatMap expand (strings (show x)))
  where
    strings ('"' : rest) = case reads ('"' : rest) of
      [(s, rest')] -> s : strings rest'
      _ -> strings rest
    strings (_ : rest) = strings rest
    strings [] = []
    expand s = let segs = splitDots s in s : [joinDots (take k segs) | k <- [1 .. length segs - 1]]
    splitDots s = case break (== '.') s of
      (a, []) -> [a]
      (a, _ : b) -> a : splitDots b
    joinDots = foldr1 (\a b -> a ++ "." ++ b)

wordLike :: Name -> Bool
wordLike n = case dropWhile (== '(') n of
  (c : _) -> c == '_' || c == '$' || c == '?' || c `elem` ['A' .. 'Z'] || c `elem` ['a' .. 'z']
  [] -> False

-- What a prelude top declares under its own (qualified) names: what
-- prelude code itself can refer to.
defines :: STop -> [Name]
defines t = case t of
  TBind n _ _ _ -> [n]
  TSig n _ _ -> [n]
  TType n _ _ cs -> n : map fst cs
  TShape n _ -> [n]
  TSigDef n _ -> [n]
  TStruct n _ ms -> [n ++ "." ++ m | (m, _) <- ms]
  TAlias n _ -> [n]
  _ -> []

-- Members reachable WITHOUT their qualifier: `x.len` / `x + y` are resolved
-- by the operand's type to whichever struct or sig carries the member, so a
-- program that writes `len` or `+` demands every struct and sig that has one.
members :: STop -> [Name]
members t = case t of
  -- a struct's bare name: the struct as a first-class record or a
  -- (s : Sig) argument. Not followed from prelude code, where `List` in a
  -- signature is the TYPE (types are always kept)
  TSigDef _ fs -> concat [[f, "(" ++ f ++ ")"] | (f, _) <- fs]
  TStruct n _ ms -> n : concat [[m, "(" ++ m ++ ")"] | (m, _) <- ms]
  _ -> []

-- Keep, in original order, every prelude top reachable from the seed names
-- (the user program's mentions) and the fixed names (compiler-introduced
-- names and builtins a prelude definition would shadow; by name only).
-- Seeds (the user program's mentions) reach declarations by name and by bare
-- member; inside kept prelude code, references are by name only (prelude
-- code spells its struct calls qualified, and its operators are resolved by
-- their own operand types). Under-inclusion is never silent: a name the
-- slice lacks is unbound or unresolvable, the sliced compile is rejected,
-- and the caller compiles with the whole prelude.
slicePrelude :: S.Set Name -> S.Set Name -> [STop] -> [STop]
slicePrelude seeds fixed ptops = [t | (i, t) <- zip [0 ..] ptops, S.member i (sliceIndices seeds fixed ptops)]

-- The positions slicePrelude keeps. Used over prelude ++ verified libraries
-- (Sol.Main), which are sliced as one body of trusted, already-checked code.
sliceIndices :: S.Set Name -> S.Set Name -> [STop] -> S.Set Int
sliceIndices seeds fixed ptops = kept
  where
    indexed = zip [0 :: Int ..] ptops
    byName = M.fromListWith (++) [(n, [i]) | (i, t) <- indexed, n <- defines t]
    byMember = M.fromListWith (++) [(n, [i]) | (i, t) <- indexed, n <- members t]
    -- type declarations are always kept: constructor tags are numbered by
    -- declaration order (Sol.Lang.collectCons), so dropping one would
    -- renumber every later type's tags
    always = [i | (i, t) <- indexed, null (defines t) || isType t]
    isType TType {} = True
    isType TAlias {} = True
    isType _ = False
    topAt = M.fromList indexed
    seedTops = concat [M.findWithDefault [] n byName ++ M.findWithDefault [] n byMember | n <- S.toList seeds]
                 ++ concat [M.findWithDefault [] n byName | n <- S.toList fixed]
    kept = close S.empty (always ++ seedTops)
    close seen [] = seen
    close seen (i : rest)
      | S.member i seen = close seen rest
      | otherwise = close (S.insert i seen) (refsOf i ++ rest)
    refsOf i | isType (topAt M.! i) = []
             | otherwise = [j | n <- S.toList (mentions (topAt M.! i)), wordLike n, j <- M.findWithDefault [] n byName]

-- Record shape ids are numbered by first appearance over the compiled
-- program (Sol.Lang.collectShapes). The prelude's only records are its
-- structs' first-class values, one per struct in declaration order. Placing
-- them first, from the WHOLE prelude, gives every shape the id the
-- whole-prelude compile gives it, whatever the slice kept.
shapeSeed :: [STop] -> [STop]
shapeSeed ptops = [TShape n [(f, TOther) | (f, _) <- fs] | TStruct n _ fs <- ptops] ++ [t | t@TShape {} <- ptops]

-- Shapes as TShape declarations in id order, for seeding: the record shapes
-- a list of declarations introduces, in first-appearance order.
orderedShapes :: M.Map [Name] Int -> [STop]
orderedShapes m = [TShape "" [(f, TOther) | f <- fs] | (fs, _) <- sortOn snd (M.toList m)]
