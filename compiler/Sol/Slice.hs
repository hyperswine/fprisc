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
module Sol.Slice (slicePrelude, mentions, injectedNames) where

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (foldl')
import Frontend.Syntax (STop (..))
import Sol.Lang (Name)

-- Names the compiler itself introduces into programs (desugarings, the
-- MVU wire codecs, operator globals, literal splices).  Kept whenever the
-- prelude defines them, whether or not the user text mentions them.
injectedNames :: [Name]
injectedNames =
  [ "and", "or", "not", "and2", "or2", "error", "Ok", "Err", "Result", "Cons", "Nil", "True", "False", "Unit", "Bool"
  , "Path", "List", "Int", "Str", "String", "Numeric", "Option", "Some", "None", "$cast", "$unsafe", "main"
  , "measure", "mulMV", "mulMM", "f64frombits", "f32frombits", "Vec.newAs", "Vec.map"
  , "Wire", "WInt", "WStr", "WBool", "WList", "WRec", "WCon", "wireCon", "wireInt", "wireDigits", "wireMap", "wireAnd"
  , "wireAt", "wireToInt", "wireToStr", "wireToBool", "wireToList", "wireListGo", "wireRev", "wireField"
  , "%", "^", "(%)", "(^)", "+", "-", "*", "/", "(+)", "(-)", "(*)", "(/)", "==", "!=", "<", ">", "<=", ">="
  ]

-- Every string literal in the shown syntax tree, plus its dotted segments
-- and prefixes (`Str.len` mentions `Str`, `len` and `Str.len`).
mentions :: Show a => a -> S.Set Name
mentions x = S.fromList (concatMap expand (strings (show x)))
  where
    strings ('"' : rest) = case reads ('"' : rest) of
      [(s, rest')] -> s : strings rest'
      _ -> strings rest
    strings (_ : rest) = strings rest
    strings [] = []
    expand s =
      let segs = splitDots s
       in s : segs ++ [joinDots (take k segs) | k <- [1 .. length segs]] ++ map paren segs
    paren s = "(" ++ s ++ ")"
    splitDots s = case break (== '.') s of
      (a, []) -> [a]
      (a, _ : b) -> a : splitDots b
    joinDots = foldr1 (\a b -> a ++ "." ++ b)

-- What a prelude top declares (and so can be demanded by).
defines :: STop -> [Name]
defines t = case t of
  TBind n _ _ _ -> [n]
  TSig n _ _ -> [n]
  TType n _ _ cs -> n : map fst cs
  TShape n _ -> [n]
  TSigDef n fs -> n : concat [[f, "(" ++ f ++ ")"] | (f, _) <- fs]
  TStruct n _ ms -> n : concat [[m, n ++ "." ++ m, "(" ++ m ++ ")"] | (m, _) <- ms]
  TAlias n _ -> [n]
  _ -> []

-- Keep, in original order, every prelude top reachable from the seed names.
-- Tops that declare nothing (TSkip, evals) are kept as-is.
slicePrelude :: S.Set Name -> [STop] -> [STop]
slicePrelude seeds ptops = [t | (i, t) <- indexed, S.member i kept]
  where
    indexed = zip [0 :: Int ..] ptops
    byName = M.fromListWith (++) [(n, [i]) | (i, t) <- indexed, n <- defines t]
    -- type declarations are always kept: constructor tags are numbered by
    -- declaration order (Sol.Lang.collectCons), so dropping one would
    -- renumber every later type's tags
    always = [i | (i, t) <- indexed, null (defines t) || isType t]
    isType TType {} = True
    isType TAlias {} = True
    isType _ = False
    topAt = M.fromList indexed
    kept = go (S.fromList always) (S.toList (foldl' S.union seeds [mentions (topAt M.! i) | i <- always])) S.empty
    go keep [] _ = keep
    go keep (n : rest) seen
      | S.member n seen = go keep rest seen
      | otherwise =
          let new = [i | i <- M.findWithDefault [] n byName, not (S.member i keep)]
              keep' = foldl' (flip S.insert) keep new
              more = concatMap (S.toList . mentions . (topAt M.!)) new
           in go keep' (more ++ rest) (S.insert n seen)
