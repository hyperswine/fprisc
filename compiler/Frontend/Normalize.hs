{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Profile inspection, eval desugaring and native arity normalization.
module Frontend.Normalize where

import Core.Syntax ( Name )
import Core.Primitives ( corePrims, primArities )
import Frontend.Syntax
    ( Ty(TCon),
      STop(TBind, TSig, TEval, TStruct),
      SGuard(GPat, GBool),
      SPat(PVar, PTup),
      SStmt(SBind, SBindPat),
      Seg(SegExpr),
      SExpr(SBlock, SLam, SCase, SBin, SProj, STup, SList, SRec, SUpd,
            SStrI, SMark, SVar, SApp) )
import qualified Data.Map.Strict as M
    ( filterWithKey, lookup, toList, fromList )

profileNames :: [String]
profileNames = ["builtin", "base", "extbase", "sol"]

declaredProfile :: [STop] -> Maybe String
declaredProfile tops =
  case [n | TSig "$profile" (_, TCon n []) _ <- tops] ++ [n | TSig "$module" (_, TCon n []) _ <- tops, n /= "Unit"] of
    (n : _) -> Just n
    [] -> Nothing

-- Up to 64 parameters use the native ABI. Larger arities retain 63 and
-- pack the remainder into one tuple; guards cannot read spilled parameters.
aritySpill :: [STop] -> ([STop], [String])
aritySpill tops = (map top tops, notes)
  where
    -- the NATIVE convention (8 regs + 56 hart argspill cells,
    -- Codegen.hs/fpr.h) carries arity <= 64 with no restrictions --
    -- this pass is only the >64 extension: keep 63 params + ONE
    -- spilled tuple, as wide as the rest (tuples have no cap: tupCon).
    natCeil = 64
    keepN = natCeil - 1
    wide = M.fromList [(n, length ps) | TBind n ps _ _ <- tops, length ps > natCeil]
    guardy = [n | TBind n ps gs _ <- tops, length ps > natCeil,
                  any (refG (spilledNames ps)) gs]
    spillable = M.filterWithKey (\n _ -> n `notElem` guardy) wide
    notes =
      ["aritySpill: " ++ n ++ ": " ++ show a ++ " params -> " ++ show keepN ++ " + spilled tuple"
        | (n, a) <- M.toList spillable]
      ++ ["aritySpill: " ++ n ++ ": guards reference spilled params -- NOT spilled (use a constructor)"
           | n <- guardy]
    spilledNames ps = [v | PVar v <- drop keepN ps]
    refG vs (GBool e) = any (\v -> refE' v e) vs
    refG vs (GPat _ e) = any (\v -> refE' v e) vs
    refE' v e = case e of
      SMark _ e' -> refE' v e'
      SVar x -> x == v
      SApp a b -> refE' v a || refE' v b
      SLam _ b -> refE' v b
      SBlock ss fin -> any (refE' v) (concatMap es ss) || refE' v fin
      SCase sc arms -> refE' v sc || any (refE' v . snd) arms
      SBin _ a b -> refE' v a || refE' v b
      SProj a _ -> refE' v a
      STup xs -> any (refE' v) xs
      SList xs -> any (refE' v) xs
      SRec fs -> any (refE' v . snd) fs
      SUpd a us -> refE' v a || any (refE' v . snd) us
      SStrI segs -> or [refE' v e' | SegExpr e' <- segs]
      _ -> False
      where es (SBind _ _ x) = [x]
            es (SBindPat _ x) = [x]
    spillVar n = "_spill_" ++ n
    top (TBind n ps gs b)
      | Just _ <- M.lookup n spillable =
          let kept = take keepN ps
              rest = drop keepN ps
              b' = SBlock [SBindPat (PTup rest) (SVar (spillVar n))] (goE b)
              b'' = case goE b of
                SBlock ss fin -> SBlock (SBindPat (PTup rest) (SVar (spillVar n)) : ss) fin
                other -> b' `seq` SBlock [SBindPat (PTup rest) (SVar (spillVar n))] other
           in TBind n (kept ++ [PVar (spillVar n)]) gs b''
    top (TBind n ps gs b) = TBind n ps gs (goE b)
    top t = t
    -- call sites: rewrite saturated applications of spillable functions
    goE e = case unspine e of
      (SVar n, args)
        | Just a <- M.lookup n spillable, length args == a ->
            respine (SVar n) (map goE (take keepN args) ++ [STup (map goE (drop keepN args))])
      _ -> descend e
    unspine (SApp f a) = let (h, as) = unspine f in (h, as ++ [a])
    unspine e = (e, [])
    respine h = foldl SApp h
    descend e = case e of
      SMark o a -> SMark o (goE a)
      SApp a b -> SApp (goE a) (goE b)
      SLam x b -> SLam x (goE b)
      SBlock ss fin -> SBlock (map stmt ss) (goE fin)
      SCase sc arms -> SCase (goE sc) [(p, goE x) | (p, x) <- arms]
      SBin o a b -> SBin o (goE a) (goE b)
      SProj a f' -> SProj (goE a) f'
      STup xs -> STup (map goE xs)
      SList xs -> SList (map goE xs)
      SRec fs -> SRec [(f', goE x) | (f', x) <- fs]
      SUpd a us -> SUpd (goE a) [(f', goE x) | (f', x) <- us]
      SStrI segs -> SStrI (map seg segs)
      _ -> e
      where
        stmt (SBind x xs rhs) = SBind x xs (goE rhs)
        stmt (SBindPat p rhs) = SBindPat p (goE rhs)
        seg (SegExpr x) = SegExpr (goE x)
        seg s = s

-- A float primitive (`F64.str`, `F32.sqrt`, ...) has a runtime entry for
-- saturated calls but no first-class runtime object: only the core
-- primitives have one (Codegen.foreignEntries, fpr_prim_obj_). Specialization
-- usually hides this by cloning the consumer (`List.map F64.str` becomes a
-- map that calls F64.str directly), so the same program failed to build only
-- under FPR_NO_SPEC (typed-ir strict: "the primitive or HAL value
-- `F64.str`"). A value occurrence becomes the lambda the source could have
-- written, `fn x -> F64.str x`, which every configuration lowers as an
-- ordinary closure. Saturated calls, partial applications and the function
-- side of `|>` are left alone: there the primitive is a call head.
etaPrimitiveValues :: [STop] -> [STop]
etaPrimitiveValues = map top
  where
    valueless = M.fromList [ (n, a) | (n, a) <- primArities, a > 0, n `notElem` corePrims
                           , any (`isPrefixOfName` n) ["F64.", "F32."] ]
    isPrefixOfName pre n = take (length pre) n == pre
    top = \case
      TBind n ps gs b -> TBind n ps (map guard gs) (goE b)
      TEval e -> TEval (goE e)
      TStruct n sigs fs -> TStruct n sigs [(f, goE e) | (f, e) <- fs]
      t -> t
    guard (GBool e) = GBool (goE e)
    guard (GPat p e) = GPat p (goE e)
    eta n a = let xs = ["$eta." ++ show i | i <- [1 .. a]]
               in SLam xs (foldl SApp (SVar n) (map SVar xs))
    -- the head of an application keeps its name; its arguments are values
    goHead = \case
      SMark o e -> SMark o (goHead e)
      SVar n -> SVar n
      SApp f a -> SApp (goHead f) (goE a)
      e -> goE e
    goE = \case
      SVar n | Just a <- M.lookup n valueless -> eta n a
      SMark o e -> SMark o (goE e)
      SApp f a -> SApp (goHead f) (goE a)
      SLam ps b -> SLam ps (goE b)
      SBlock ss fin -> SBlock (map stmt ss) (goE fin)
      SCase sc arms -> SCase (goE sc) [(p, goE e) | (p, e) <- arms]
      SBin "|>" a f -> SBin "|>" (goE a) (goHead f)
      SBin o a b -> SBin o (goE a) (goE b)
      SProj a fs -> SProj (goE a) fs
      STup xs -> STup (map goE xs)
      SList xs -> SList (map goE xs)
      SRec fs -> SRec [(k, goE v) | (k, v) <- fs]
      SUpd a us -> SUpd (goE a) [(k, goE v) | (k, v) <- us]
      SStrI segs -> SStrI (map seg segs)
      e -> e
    stmt (SBind x ps rhs) = SBind x ps (goE rhs)
    stmt (SBindPat p rhs) = SBindPat p (goE rhs)
    seg (SegExpr x) = SegExpr (goE x)
    seg s = s

-- The autodrop pass that lived here (compiler-inserted `drop`s on receive
-- paths, docs/2026-08-25-MEMORY.md) was retired on 2026-10-24: a received
-- message root dies with the turn that took it, released by the runtime at
-- the turn boundary (docs/2026-10-24-REGIONS-STAGE1.md).

adHeadName :: SExpr -> Maybe Name
adHeadName (SMark _ e) = adHeadName e
adHeadName (SVar n) = Just n
adHeadName (SApp f _) = adHeadName f
adHeadName _ = Nothing

-- fold the `> e.` statements into a synthesized `main` (a block whose
-- statements bind throwaways, last one is the result).  An explicit
-- `main` alongside `>` statements is a conflict, reported by Main.
desugarEvals :: [STop] -> ([STop], Int)
desugarEvals tops =
  let evs = [e | TEval e <- tops]
      rest = [t | t <- tops, notEval t]
      notEval (TEval _) = False
      notEval _ = True
   in case evs of
        [] -> (tops, 0)
        _ ->
          let stmts = [SBind ("_top" ++ show i) [] e | (i, e) <- zip [(1 :: Int) ..] (init evs)]
              mainB = TBind "main" [] [] (SBlock stmts (last evs))
           in (rest ++ [mainB], length evs)
