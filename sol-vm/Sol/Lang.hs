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

-- This profile adapter preserves its public frontend compatibility exports.
import FPRISC hiding (collectCons, collectShapes)
import Data.Char (isUpper)
import Data.List (foldl', nub, sort, sortOn, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- ---- guard helpers over the shared AST --------------------------------------

guardExprs :: [SGuard] -> [SExpr]
guardExprs gs = [e | g <- gs, e <- case g of GBool e' -> [e']; GPat _ e' -> [e']]

guardPats :: [SGuard] -> [SPat]
guardPats gs = [p | GPat p _ <- gs]

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
    -- (`ListS.add`, including qualified `ui.Style.flex`, before expansion). It must
    -- NOT fire for other dotted names: diamond file-module imports leave
    -- canonical cross-module refs like `logic.base.findCh` whose head
    -- coincides with a use-binding name — renaming those dangles them.
    structNames = S.fromList [n | TStruct n _ _ <- tops0]
    structPrefixes = reverse (sortOn length [n | n <- S.toList structNames, M.member n rn])
    lookDotted v = case M.lookup v rn of
      Just r -> r
      Nothing -> case [look n ++ drop (length n) v
                      | n <- structPrefixes, (n ++ ".") `isPrefixOf` v] of
        renamed : _ -> renamed
        [] -> v
    top = \case
      TBind n ps g b ->
        let bs = S.fromList (concatMap patVars ps)
            (bs', g') = renGuards re rp bs g
         in TBind (look n) (map rp ps) g' (re bs' b)
      TSig n (ps, r) pcs -> TSig (look n) (map rt ps, rt r) pcs
      TType n l ps cs -> TType (look n) l ps [(look c, map rt tys) | (c, tys) <- cs]
      -- a record type's name and its field types are the module's too: a
      -- field `vary : List Variant` names this module's Variant
      TShape n fs -> TShape (look n) [(x, rt t) | (x, t) <- fs]
      TEval e -> TEval (re S.empty e)
      TAlias t tgt -> TAlias (look t) (look tgt)
      TSigDef n fs -> TSigDef (look n) fs
      TStruct n sigs fs -> TStruct (look n) (map look sigs) [(f, re S.empty e) | (f, e) <- fs]
      other -> other
    rt = renameTypeNames look
    rp = \case
      PCon c ps -> PCon (look c) (map rp ps)
      PTup ps -> PTup (map rp ps)
      PSig n sg -> PSig n (look sg)
      o -> o
    re = transformEP step rp
    step bs e = case e of
      SVar v | not (S.member v bs) -> SVar (lookDotted v)
      -- a module's @Model.field / @Msg literal names its own type, as a type
      -- occurrence does: rename the root with the type (Modules.reSelf is the
      -- AOT twin); a sol file path (no renamed upper-case root) is untouched
      SApp (SVar "Path") (SStrI [SegStr p])
        | (root@(c : _), fields) <- break (== '.') p,
          isUpper c,
          Just r <- M.lookup root rn ->
            SApp (SVar "Path") (SStrI [SegStr (r ++ fields)])
      _ -> e


-- every name a module defines at top level (what an importer may reference)
topNames :: [STop] -> [Name]
topNames tops =
  concat
    [ [n | TBind n _ _ _ <- tops],
      [n | TSig n _ _ <- tops],
      [n | TType n _ _ _ <- tops],
      [c | TType _ _ _ cs <- tops, (c, _) <- cs],
      [n | TShape n _ <- tops],
      [t | TAlias t _ <- tops],
      [n | TSigDef n _ <- tops],
      [n | TStruct n _ _ <- tops]
    ]

-- A module reached TWICE (a diamond: json uses map and option, map uses option)
-- is spliced once, and the second alias is re-pointed at the canonical copy.
-- That re-pointing has to reach everything that can name the module's things:
-- expressions, PATTERNS (`O.Some x ->`) and the TYPES in signatures and
-- constructor fields (`-> O.Option a`).  It only did expressions, so the second
-- importer's patterns and signatures named a module that was never spliced.
-- EVERY position a type name can sit in: a bare `Option` left in `(a -> Option b)`
-- once broke std/option.fpr under any alias.  Shared by both renamers above.
renameTypeNames :: (Name -> Name) -> Ty -> Ty
renameTypeNames f = rt
  where
    rt = \case
      TCon n as -> TCon (f n) (map rt as)
      TTup ts -> TTup (map rt ts)
      TArrT a b -> TArrT (rt a) (rt b)
      TVApp n as -> TVApp n (map rt as)
      TRecT fs tl -> TRecT [(x, rt t) | (x, t) <- fs] tl
      o -> o

qualifyUses :: M.Map Name Name -> [STop] -> [STop]
qualifyUses aliases = map top
  where
    top = \case
      TBind n ps g b ->
        let bs = S.fromList (concatMap patVars ps)
            (bs', g') = renGuards re rp bs g
         in TBind n (map rp ps) g' (re bs' b)
      TSig n (ps, r) pcs -> TSig n (map rt ps, rt r) pcs
      TType n l ps cs -> TType n l ps [(c, map rt tys) | (c, tys) <- cs]
      TShape n fs -> TShape n [(x, rt t) | (x, t) <- fs]
      TStruct n sigs fs -> TStruct n sigs [(f, re S.empty e) | (f, e) <- fs]
      TEval e -> TEval (re S.empty e)
      -- the shared parser produces TUse for `m = use "spec".`; splicing
      -- already happened in expandUses — re-emit the RUNTIME binding so
      -- first-class Module values (`run m`) keep working
      TUse mn spec -> TBind mn [] [] (re S.empty (SApp (SVar "use") (SStrI [SegStr spec])))
      TAlias t tgt -> TAlias t (retgt tgt)
      other -> other
    retgt tgt = case break (== '.') tgt of
      (m, '.' : rest) | Just canon <- M.lookup m aliases, canon /= m -> canon ++ "." ++ rest
      _ -> tgt
    rt = renameTypeNames retgt
    rp = \case
      PCon c ps -> PCon (retgt c) (map rp ps)
      PTup ps -> PTup (map rp ps)
      o -> o
    re = transformEP step rp
    step bs e = case e of
      SProj (SVar m) (f : rest)
        | Just canon <- M.lookup m aliases,
          not (S.member m bs) ->
            let base = SVar (canon ++ "." ++ f)
             in if null rest then base else SProj base rest
      -- the same reference when the parser gave it as ONE dotted name
      SVar v | retgt v /= v, not (S.member (takeWhile (/= '.') v) bs) -> SVar (retgt v)
      _ -> e

-- ---- Core builtin names across module splices --------------------------------
--
-- `Option`, `None`, `Some`, `Result`, `Ok` and `Err` are Core builtins (v1.0
-- spec; std/option.fpr no longer declares `Option`).  Splicing renames a
-- module's definitions under its alias, and that renaming used to capture a
-- builtin a module only REFERS to: std/map's bare `Option` became `CLI.Option`
-- inside sol/lib/cli.sol, which declares a type of that name, and its bare
-- `None` met the preamble's `Cmd` constructor of the same spelling.  Two
-- steps keep the builtin meaning:
--
--  * when an .fpr module is spliced, the builtin names it uses but does not
--    define are marked (`@None`), which no later rename touches;
--  * resolveCoreBuiltins, over the preamble and the expanded program, turns
--    marks back into the builtins, sends a qualified `O.None` whose module
--    does not define `None` to the builtin (the rule Modules.hs applies to
--    FP-RISC programs), and renames the preamble's `Cmd` constructor `None`
--    to `Cmd.None`.  A bare `None` is always the builtin, as in FP-RISC
--    (v1.0 spec Q6, decided 2026-11-22); "no command" is written `Cmd.None`,
--    as an FP-RISC game writes `G.None`.  The VM prints a user constructor by
--    its base name, so it still shows as `None`, and the web runtime matches
--    it by that name.

coreBuiltinNames :: [Name]
coreBuiltinNames = ["Option", "None", "Some", "Result", "Ok", "Err"]

-- the marks a spliced .fpr module's own references get
coreBuiltinMarks :: [Name] -> M.Map Name Name
coreBuiltinMarks defined = M.fromList [(b, '@' : b) | b <- coreBuiltinNames, b `notElem` defined]

resolveCoreBuiltins :: [STop] -> [STop] -> ([STop], [STop])
resolveCoreBuiltins prel prog = (map (renameNamesBy prelName) prel, map (renameNamesBy progName . shadowTop) prog)
  where
    -- THE ROOT SCRIPT SHADOWS. A type or constructor the script itself
    -- declares under a builtin type's name (`Option`, `Result`) or a preamble
    -- type's or constructor's (`Cmd`, `Msg`) is the script's: the two used to
    -- merge into one type, so exhaustiveness asked the script's `case` for
    -- `Some`/`None` and a value of one unified with the other. A spliced
    -- module's definitions are already qualified (`CLI.Option`); the root's
    -- are the unqualified ones, so only those are renamed, to `Main.<name>`
    -- (the VM prints a constructor by its base name, so output is unchanged).
    -- `None`, `Some`, `Ok` and `Err` stay the builtins, as above.
    isRoot = \case
      TEval {} -> True
      t -> case topNames [t] of
        n : _ -> '.' `notElem` n
        [] -> False
    rootTops = filter isRoot prog
    -- types and constructors are separate namespaces: a type `Msg` beside
    -- the preamble's constructor `Msg` is no clash
    rootTypes = S.fromList ([n | TType n _ _ _ <- rootTops] ++ [n | TShape n _ <- rootTops])
    rootCons = S.fromList [c | TType _ _ _ cs <- rootTops, (c, _) <- cs]
    prelTypes = S.fromList (["Option", "Result"] ++ [n | TType n _ _ _ <- prel] ++ [n | TShape n _ <- prel])
    prelCons = S.fromList [prelName c | TType _ _ _ cs <- prel, (c, _) <- cs]
    shadowed =
      S.difference
        (S.union (S.intersection rootTypes prelTypes) (S.intersection rootCons prelCons))
        (S.fromList ["None", "Some", "Ok", "Err"])
    shadowName n = if S.member n shadowed then "Main." ++ n else n
    -- `@Option` / `@Cmd.field` literals name the type as well
    shadowPath = \case
      SApp (SVar "Path") (SStrI [SegStr p])
        | (root, fields) <- break (== '.') p,
          S.member root shadowed ->
            SApp (SVar "Path") (SStrI [SegStr ("Main." ++ root ++ fields)])
      e -> e
    tp = transformEP (\_ e -> shadowPath e) id S.empty
    shadowExprs = \case
      TBind n ps g b -> TBind n ps (map (mapGuardE tp) g) (tp b)
      TEval e -> TEval (tp e)
      TStruct n sigs fs -> TStruct n sigs [(x, tp e) | (x, e) <- fs]
      other -> other
    shadowTop t
      | S.null shadowed || not (isRoot t) = t
      | otherwise = case shadowExprs (renameNamesBy shadowName t) of
          TType n l ps cs -> TType (shadowName n) l ps cs
          TShape n fs -> TShape (shadowName n) fs
          other -> other
    everything = prel ++ prog
    -- the root's shadowing names (`Main.Option`) are its own definitions
    defined = S.union (S.fromList (topNames everything)) (S.map ("Main." ++) shadowed)
    prelName n
      | n == "None" = "Cmd.None"
      | otherwise = n
    progName n = case n of
      '@' : b | b `elem` coreBuiltinNames -> b
      "Cmd.None" -> n
      _ | '.' `elem` n,
          base <- reverse (takeWhile (/= '.') (reverse n)),
          base `elem` coreBuiltinNames,
          S.notMember n defined -> base
        | otherwise -> n

-- rename every constructor, type and value reference (and constructor
-- definitions) by a function; locals are lowercase, so no binder can collide
renameNamesBy :: (Name -> Name) -> STop -> STop
renameNamesBy f = top
  where
    rp = \case
      PCon c ps -> PCon (f c) (map rp ps)
      PTup ps -> PTup (map rp ps)
      o -> o
    rt = renameTypeNames f
    re bs = transformEP (\_ e -> case e of SVar v -> SVar (f v); _ -> e) rp bs
    top = \case
      TBind n ps g b ->
        let (bs, g') = renGuards re rp (S.fromList (concatMap patVars ps)) g
         in TBind n (map rp ps) g' (re bs b)
      TEval e -> TEval (re S.empty e)
      TStruct n sigs fs -> TStruct n sigs [(x, re S.empty e) | (x, e) <- fs]
      TSig n (ps, r) pcs -> TSig n (map rt ps, rt r) pcs
      TType n l ps cs -> TType n l ps [(f c, map rt tys) | (c, tys) <- cs]
      TShape n fs -> TShape n [(x, rt t) | (x, t) <- fs]
      other -> other
