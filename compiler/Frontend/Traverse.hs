{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Surface scope traversal and position erasure for module identity.
module Frontend.Traverse where

import Core.Syntax ( Name )
import Data.List ( nub )
import Frontend.Syntax
    ( STop(TStruct, TBind, TEval),
      SPat(PRec, PVar, PSig, PCon, PTup),
      SStmt(SBindPat, SBind),
      Seg(SegExpr),
      SExpr(SStrI, SVar, SMark, SApp, SLam, SBlock, SCase, SBin, SProj,
            SRec, SUpd, STup, SList),
      SGuard, mapGuardE )
import qualified Data.Set as S ( Set, fromList, insert, union )

-- Parser marks survive until lowering; erase them here only when hashing
-- module identity or explicitly requesting a positionless surface tree.
stripPosTops :: [STop] -> [STop]
stripPosTops = map stripTop
  where
    stripTop = \case
      TBind n ps g b -> TBind n ps (map (mapGuardE stripE) g) (stripE b)
      TEval e -> TEval (stripE e)
      TStruct n sigs fs -> TStruct n sigs [(f, stripE e) | (f, e) <- fs]
      t -> t

-- erase every position wrapper (module identity, and any consumer that
-- needs the pure syntactic tree)
stripE :: SExpr -> SExpr
stripE = \case
  SMark _ e -> stripE e
  SApp a b -> SApp (stripE a) (stripE b)
  SLam ps e -> SLam ps (stripE e)
  SBlock ss e -> SBlock (map stripS ss) (stripE e)
  SCase s arms -> SCase (stripE s) [(p, stripE e) | (p, e) <- arms]
  SBin o a b -> SBin o (stripE a) (stripE b)
  SProj e fs -> SProj (stripE e) fs
  SRec fs -> SRec [(f, stripE e) | (f, e) <- fs]
  SUpd m as -> SUpd (stripE m) [(p, stripE e) | (p, e) <- as]
  STup es -> STup (map stripE es)
  SList es -> SList (map stripE es)
  SStrI segs -> SStrI [case sg of SegExpr e -> SegExpr (stripE e); s -> s | sg <- segs]
  e -> e
  where
    stripS (SBind n ps e) = SBind n ps (stripE e)
    stripS (SBindPat p e) = SBindPat p (stripE e)

-- look through position wrappers: every SHAPE-SENSITIVE match (a pass
-- recognizing a special form by syntax) goes through this first
unmark :: SExpr -> SExpr
unmark (SMark _ e) = unmark e
unmark e = e

sFree :: SExpr -> [Name]
sFree = nub . go
  where
    go = \case
      SMark _ e -> go e
      SVar v -> [v]
      SApp a b -> go a ++ go b
      SLam ps e -> filter (`notElem` ps) (go e)
      SBin _ a b -> go a ++ go b
      SProj e _ -> go e
      SRec fs -> concatMap (go . snd) fs
      SUpd m as -> go m ++ concatMap (go . snd) as
      STup es -> concatMap go es
      SList es -> concatMap go es
      SStrI segs -> concat [go e | SegExpr e <- segs]
      SCase s arms -> go s ++ concatMap armF arms
      SBlock ss e -> blockF ss e
      _ -> []
    armF (p, e) = filter (`notElem` patB p) (go e)
    patB = \case
      PVar x -> [x]
      PCon _ ps -> concatMap patB ps
      PTup ps -> concatMap patB ps
      PRec fs -> fs
      _ -> []
    blockF [] e = go e
    blockF (SBind n ps rhs : rest) e = filter (`notElem` ps) (go rhs) ++ filter (/= n) (blockF rest e)
    blockF (SBindPat p rhs : rest) e = go rhs ++ filter (`notElem` patB p) (blockF rest e)

--------------------------------------------------------------------------------
-- Generic expr traversal + pattern vars (shared by Struct/Infer)
--------------------------------------------------------------------------------

patVars :: SPat -> [Name]
patVars = \case
  PVar n -> [n]
  PSig n _ -> [n]
  PCon _ ps -> concatMap patVars ps
  PTup ps -> concatMap patVars ps
  PRec ns -> ns
  _ -> []

-- generic bottom-up expr transform threading the set of locally-bound names
transformE :: (S.Set Name -> SExpr -> SExpr) -> S.Set Name -> SExpr -> SExpr
transformE f = transformEP f id

transformEP :: (S.Set Name -> SExpr -> SExpr) -> (SPat -> SPat) -> S.Set Name -> SExpr -> SExpr
transformEP f pf = go
  where
    go bs e0 = f bs $ case e0 of
      SMark o e -> SMark o (go bs e)
      SApp a b -> SApp (go bs a) (go bs b)
      SLam ps b -> SLam ps (go (bs `S.union` S.fromList ps) b)
      SBlock stmts fin ->
        let (stmts', bs') = goStmts bs stmts
         in SBlock stmts' (go bs' fin)
      SCase s alts -> SCase (go bs s) [(pf p, go (bs `S.union` S.fromList (patVars p)) e) | (p, e) <- alts]
      SBin op a b -> SBin op (go bs a) (go bs b)
      SProj e path -> SProj (go bs e) path
      SRec fs -> SRec [(n, go bs e) | (n, e) <- fs]
      SUpd m as -> SUpd (go bs m) [(p, go bs e) | (p, e) <- as]
      STup es -> STup (map (go bs) es)
      SList es -> SList (map (go bs) es)
      SStrI segs -> SStrI [case s of SegExpr e -> SegExpr (go bs e); o -> o | s <- segs]
      other -> other
    goStmts bs [] = ([], bs)
    goStmts bs (SBind n ps x : rest) =
      let x' = go (bs `S.union` S.fromList (n : ps)) x
          (rest', bs') = goStmts (S.insert n bs) rest
       in (SBind n ps x' : rest', bs')
    goStmts bs (SBindPat p x : rest) =
      let x' = go bs x
          (rest', bs') = goStmts (bs `S.union` S.fromList (patVars p)) rest
       in (SBindPat (pf p) x' : rest', bs')

-- Source clause order is part of first-match semantics. Shared by semantic
-- lowering and the compatibility desugarer, without backend dependencies.
sourceGroups :: [STop] -> [(Name,[([SPat],[SGuard],SExpr)])]
sourceGroups tops=[(n,[(ps,g,b) | TBind n' ps g b<-tops,n'==n]) | n<-nub [n | TBind n _ _ _<-tops]]
