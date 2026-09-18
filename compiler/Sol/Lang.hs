{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Sol/Lang.hs — the HostedBytecode profile's LANGUAGE SURFACE.
--
-- The pipeline is FPRISC.hs, whole: surface AST, parser, Core,
-- desugar, pattern compiler, lambda lifter, linearity checker — one
-- frontend, re-exported here so sol's consumers keep their imports.
-- What remains below is only what genuinely differs for this profile:
--
--   * tid policy: the VM's constructor/shape ids are per-run
--     sequential (collectCons from 10, collectShapes from 100) where
--     the AOT tiers content-address them for ABI stability — both
--     feed the SAME desugar through DEnv;
--   * string decoding: the shared lexer stores literals as UTF-8
--     BYTES (the AOT codegen contract); the VM speaks real Chars, so
--     decodeProgStrings walks the compiled Prog once after lifting;
--   * module splicing: binder-aware renaming and alias qualification
--     for the content-addressed file modules (Mod.hs).
--
-- This file was a ~1,100-line fork of FPRISC.hs (with a dead
-- evaluator inside); the un-forking is tracked by
-- tools/dedup-ratchet.sh.
module Sol.Lang (module Sol.Lang, module FPRISC) where

import FPRISC hiding (collectCons, collectShapes)
import Data.List (foldl', nub, sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- ---- guard helpers over the shared AST --------------------------------------

guardExprs :: [SGuard] -> [SExpr]
guardExprs gs = [e | g <- gs, e <- case g of GBool e' -> [e']; GPat _ e' -> [e']]

guardPats :: [SGuard] -> [SPat]
guardPats gs = [p | GPat p _ <- gs]

mapGuardP :: (SPat -> SPat) -> SGuard -> SGuard
mapGuardP _ (GBool e) = GBool e
mapGuardP f (GPat p e) = GPat (f p) e

-- ---- UTF-8 decode: bytes (shared lexer) -> Chars (the VM) -------------------

decodeU8 :: String -> String
decodeU8 [] = []
decodeU8 (c : cs)
  | b < 0x80 = c : decodeU8 cs
  | b >= 0xC0 && b < 0xE0, (c1 : r) <- cs, cont c1 = toEnum ((b - 0xC0) * 64 + v c1) : decodeU8 r
  | b >= 0xE0 && b < 0xF0, (c1 : c2 : r) <- cs, cont c1, cont c2 = toEnum ((b - 0xE0) * 4096 + v c1 * 64 + v c2) : decodeU8 r
  | b >= 0xF0 && b < 0xF8, (c1 : c2 : c3 : r) <- cs, cont c1, cont c2, cont c3 = toEnum ((b - 0xF0) * 262144 + v c1 * 4096 + v c2 * 64 + v c3) : decodeU8 r
  | otherwise = c : decodeU8 cs
  where
    b = fromEnum c
    cont x = fromEnum x >= 0x80 && fromEnum x < 0xC0
    v x = fromEnum x - 0x80

-- the surface->Core boundary used to decode inline (sol's dExpr fork);
-- the shared desugar keeps bytes, so decode ONCE over the lifted Prog
decodeProgStrings :: Prog -> Prog
decodeProgStrings = M.map (\(ps, b) -> (ps, goC b))
  where
    goC = \case
      CStr s -> CStr (decodeU8 s)
      CApp a b -> CApp (goC a) (goC b)
      CLam ps e -> CLam ps (goC e)
      CLet n a b -> CLet n (goC a) (goC b)
      CIf c t e -> CIf (goC c) (goC t) (goC e)
      CMk t v fs -> CMk t v (map goC fs)
      CTagEq t v e -> CTagEq t v (goC e)
      CProj i e -> CProj i (goC e)
      e -> e

-- ---- tid policy: per-run sequential (the VM has no ABI to keep) -------------

collectCons :: [STop] -> M.Map Name (Int, Int, Int)
collectCons tops = withAliases (M.union builtinCons (M.fromList user))
  where
    tdecls = [cs | TType _ _ _ cs <- tops]
    user = concat (zipWith one [10 ..] tdecls)
    one tid cs = [(c, (tid, v, length tys)) | ((c, tys), v) <- zip cs [0 ..]]
    withAliases m = foldl' (\acc (t, tgt) -> maybe acc (\e -> M.insert t e acc) (M.lookup tgt m)) m
                            [(t, tgt) | TAlias t tgt <- tops]

collectShapes :: [STop] -> M.Map [Name] Int
collectShapes tops = M.fromList (zip allShapes [100 ..])
  where
    allShapes = nub (concatMap topShapes tops)
    topShapes (TShape _ fs) = [sort (map fst fs)]
    topShapes (TBind _ ps g b) =
      concatMap patShapes ps
        ++ concatMap exprShapes (guardExprs g)
        ++ concatMap patShapes (guardPats g)
        ++ exprShapes b
    topShapes _ = []
    patShapes = \case
      PCon _ ps -> concatMap patShapes ps
      PTup ps -> concatMap patShapes ps
      _ -> []
    exprShapes = \case
      SMark _ e -> exprShapes e
      SRec fs -> [sort (map fst fs)] ++ concatMap (exprShapes . snd) fs
      SApp a b -> exprShapes a ++ exprShapes b
      SLam _ e -> exprShapes e
      SBlock ss e -> concatMap stmtShapes ss ++ exprShapes e
      SCase s as -> exprShapes s ++ concatMap (\(p, e) -> patShapes p ++ exprShapes e) as
      SBin _ a b -> exprShapes a ++ exprShapes b
      SProj e _ -> exprShapes e
      SUpd m as -> exprShapes m ++ concatMap (exprShapes . snd) as
      STup es -> concatMap exprShapes es
      SList es -> concatMap exprShapes es
      SStrI segs -> concat [exprShapes e | SegExpr e <- segs]
      _ -> []
    stmtShapes (SBind _ _ x) = exprShapes x
    stmtShapes (SBindPat p x) = patShapes p ++ exprShapes x


-- ---- module splicing (Mod.hs): binder-aware rename + alias qualify ---------

renGuards ::
  (S.Set Name -> SExpr -> SExpr) ->
  (SPat -> SPat) ->
  S.Set Name ->
  [SGuard] ->
  (S.Set Name, [SGuard])
renGuards re rp = go
  where
    go bs [] = (bs, [])
    go bs (GBool e : gs) = let (bs', gs') = go bs gs in (bs', GBool (re bs e) : gs')
    go bs (GPat p e : gs) =
      let bs2 = S.union bs (S.fromList (patVars p))
          (bs', gs') = go bs2 gs
       in (bs', GPat (rp p) (re bs e) : gs')


renameTops :: M.Map Name Name -> [STop] -> [STop]
renameTops rn tops0 = map top tops0
  where
    look n = M.findWithDefault n n rn
    -- dotted-head renaming exists ONLY for struct field self-references
    -- (`ListS.add` before the struct expands to flat globals). It must
    -- NOT fire for other dotted names: diamond file-module imports leave
    -- canonical cross-module refs like `logic.base.findCh` whose head
    -- coincides with a use-binding name — renaming those dangles them.
    structNames = S.fromList [n | TStruct n _ _ <- tops0]
    lookDotted v = case M.lookup v rn of
      Just r -> r
      Nothing -> case break (== '.') v of
        (h, '.' : rest) | S.member h structNames, M.member h rn -> look h ++ "." ++ rest
        _ -> v
    top = \case
      TBind n ps g b ->
        let bs = S.fromList (concatMap patVars ps)
            (bs', g') = renGuards re rp bs g
         in TBind (look n) (map rp ps) g' (re bs' b)
      TSig n (ps, r) pcs -> TSig (look n) (map rt ps, rt r) pcs
      TType n l ps cs -> TType (look n) l ps [(look c, map rt tys) | (c, tys) <- cs]
      TEval e -> TEval (re S.empty e)
      TAlias t tgt -> TAlias (look t) (look tgt)
      TSigDef n fs -> TSigDef (look n) fs
      TStruct n sigs fs -> TStruct (look n) (map look sigs) [(f, re S.empty e) | (f, e) <- fs]
      other -> other
    rt = \case
      TCon n as -> TCon (look n) (map rt as)
      TTup ts -> TTup (map rt ts)
      o -> o
    rp = \case
      PCon c ps -> PCon (look c) (map rp ps)
      PTup ps -> PTup (map rp ps)
      PSig n sg -> PSig n (look sg)
      o -> o
    re = transformEP step rp
    step bs e = case e of
      SVar v | not (S.member v bs) -> SVar (lookDotted v)
      _ -> e


-- every name a module defines at top level (what an importer may reference)
topNames :: [STop] -> [Name]
topNames tops =
  concat
    [ [n | TBind n _ _ _ <- tops],
      [n | TSig n _ _ <- tops],
      [n | TType n _ _ _ <- tops],
      [c | TType _ _ _ cs <- tops, (c, _) <- cs],
      [t | TAlias t _ <- tops],
      [n | TSigDef n _ <- tops],
      [n | TStruct n _ _ <- tops]
    ]

qualifyUses :: M.Map Name Name -> [STop] -> [STop]
qualifyUses aliases = map top
  where
    top = \case
      TBind n ps g b ->
        let bs = S.fromList (concatMap patVars ps)
            (bs', g') = renGuards re id bs g
         in TBind n ps g' (re bs' b)
      TEval e -> TEval (re S.empty e)
      -- the shared parser produces TUse for `m = use "spec".`; splicing
      -- already happened in expandUses — re-emit the RUNTIME binding so
      -- first-class Module values (`run m`) keep working
      TUse mn spec -> TBind mn [] [] (re S.empty (SApp (SVar "use") (SStrI [SegStr spec])))
      TAlias t tgt -> TAlias t (retgt tgt)
      other -> other
    retgt tgt = case break (== '.') tgt of
      (m, '.' : rest) | Just canon <- M.lookup m aliases -> canon ++ "." ++ rest
      _ -> tgt
    re = transformE step
    step bs e = case e of
      SProj (SVar m) (f : rest)
        | Just canon <- M.lookup m aliases,
          not (S.member m bs) ->
            let base = SVar (canon ++ "." ++ f)
             in if null rest then base else SProj base rest
      _ -> e
