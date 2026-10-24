{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Surface-to-Core lowering, data layout and closure/join lifting.
module Frontend.Desugar where

import Control.Monad ( when, foldM, unless )
import Control.Monad.State.Strict
    ( gets, modify, MonadState(put, get), State )
import Core.Syntax ( Prog, Core(..), Name, freeVars )
import Data.Bits ( Bits(xor) )
import Data.Char ( ord, isDigit )
import Data.List
    ( foldl', intercalate, isPrefixOf, nub, sort, sortOn )
import Data.Word ( Word32 )
import Frontend.Syntax
    ( STop(TBind, TType, TShape),
      SGuard(..),
      SPat(..),
      SStmt(SBindPat, SBind),
      Seg(SegExpr, SegStr),
      SExpr(..) )
import qualified Data.Map.Strict as M
    ( keysSet, lookup, toList, union, fromList, traverseWithKey, Map )
import qualified Data.Set as S ( fromList, union )

data DEnv = DEnv
  { dFresh :: Int,
    dCons :: M.Map Name (Int, Int, Int),
    dShapes :: M.Map [Name] Int,
    dLifted :: [(Name, [Name], Core)],
    -- Private, saturated control-flow joins; ordinary lifted lambdas are
    -- not joins. Later passes may traverse these within the current turn.
    dJoins :: [Name]
  }

type D = Control.Monad.State.Strict.State DEnv

fresh :: String -> D Name
fresh pre = do
  s <- get
  put s {dFresh = dFresh s + 1}
  pure (pre ++ "_" ++ show (dFresh s))

builtinCons :: M.Map Name (Int, Int, Int)
builtinCons =
  M.fromList
    [ ("Unit", (0, 0, 0)),
      ("False", (1, 0, 0)),
      ("True", (1, 1, 0)),
      ("Nil", (2, 0, 0)),
      ("Cons", (2, 1, 2)),
      ("Ok", (3, 0, 1)),
      ("Err", (3, 1, 1)),
      ("Tup2", (4, 0, 2)),
      ("Tup3", (5, 0, 3)),
      -- wide tuples: tids 10..14 (fpr.h T_TUP4..T_TUP8).  Capped at 8
      -- to match call arity's register span; wider anonymous data
      -- should be a record or a declared constructor.
      ("Tup4", (10, 0, 4)),
      ("Tup5", (11, 0, 5)),
      ("Tup6", (12, 0, 6)),
      ("Tup7", (13, 0, 7)),
      ("Tup8", (14, 0, 8))
    ]

boolT, listT, atomT :: Int
boolT = 1
listT = 2
atomT = 6

-- CONTENT-ADDRESSED typeids (separate compilation): a type's id is a
-- function of (owning unit's hash, type name), so the defining unit and
-- every importer -- compiled separately -- assign the same id from the
-- same inputs, with no shared counter.  Ranges (all u32, disjoint from
-- builtins 0..14 (incl. Tup4..Tup8 at 10..14) and runtime 9000..):
--   record shapes : 0x00010000 + fnv32(fields)  mod 0x0FF00000
--   unit types    : 0x20000000 + fnv32(hash.T)  mod 0x5F000000
-- Main checks the merged maps for collisions and aborts loudly.
fnv32 :: String -> Int
fnv32 = fromIntegral . foldl' step (0x811c9dc5 :: Word32)
  where step acc c = (acc `xor` fromIntegral (ord c)) * 0x01000193

tidFor :: String -> Name -> Int
tidFor h n = 0x20000000 + fnv32 (h ++ "." ++ n) `mod` 0x5F000000

collectCons :: String -> [STop] -> M.Map Name (Int, Int, Int)
collectCons unitHash tops = M.union builtinCons (M.fromList user)
  where
    tdecls = [(n, cs) | TType n _ _ cs <- tops]
    user = concat [one (tidFor unitHash n) cs | (n, cs) <- tdecls]
    one tid cs = [(c, (tid, v, length tys)) | ((c, tys), v) <- zip cs [0 ..]]

collectShapes :: [STop] -> M.Map [Name] Int
collectShapes tops = M.fromList [(fs, shapeIdFor fs) | fs <- allShapes]
  where
    shapeIdFor fs = 0x00010000 + fnv32 (intercalate "," fs) `mod` 0x0FF00000
    allShapes = nub (concatMap topShapes tops)
    topShapes (TShape _ fs) = [sort (map fst fs)]
    topShapes (TBind _ ps g b) =
      concatMap patShapes ps
        ++ concatMap gShapes g
        ++ exprShapes b
      where
        gShapes (GBool e) = exprShapes e
        gShapes (GPat p e) = patShapes p ++ exprShapes e
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

-- ---- first-class paths (docs/2026-08-27-PATHS.md) --------------------------------
--
-- A TYPE-ROOTED path literal `@Model.field.sub` is validated here --
-- unconditionally, against the record alias's declared field types --
-- and desugars to an ORDINARY record value
--
--   { get  = fn s -> s.field.sub,
--     set  = fn v s -> {s | field.sub = v},
--     segs = ["field", "sub"] }
--
-- and, when the field's type can go on the wire, its codec and its zero
-- (`enc`, `dec`, `zero`: see `wireable` below).
--
-- at plain type Path s a: no new type-system machinery, all the magic
-- lives in this one rewrite (composition is a normal function, in
-- std/lens).  The parser already turns every `@...` into
-- SApp (SVar "Path") <string> (sol's file-path literal); a literal
-- whose FIRST segment names a declared record alias is a path into
-- that shape and rewrites, everything else passes through untouched
-- (file paths start lowercase or '/', so the split is honest).
--
-- The BARE root `@Model` is the SCHEMA: the flattened list of every
-- leaf that can go on the wire, each entry
--
--   { path = "a.b", tag = "int"|"str"|"bool"|"enum"|"wire",
--     wire   = fn s -> <the leaf through its codec>,
--     unwire = fn w s -> <s with the leaf decoded from w, or Err> }
--
-- -- the string tier for wires, shells and inspectors (std/lens walks
-- it, handing text over as a WStr) and the page's client state
-- (std/view's `locals`).  Nested record aliases are flattened; a leaf
-- with no codec (a function) is typed-tier-only and skipped.
--
-- Runs on the SURFACE tree right after module load (Compile.hs), so
-- collectShapes sees the generated records like any user record and
-- every profile downstream is oblivious.

dExpr :: SExpr -> D Core
dExpr = \case
  SMark _ e -> dExpr e -- positions stop at the Core boundary
  SVar n -> do
    cons <- gets dCons
    pure $ case M.lookup n cons of
      Just (_, _, _) -> CVar n
      Nothing -> CVar n
  SInt i -> pure (CInt i)
  SAtom a -> pure (CMk atomT 0 [CStr a])
  SApp a b -> CApp <$> dExpr a <*> dExpr b
  SLam ps e -> CLam ps <$> dExpr e
  SBlock stmts e -> go stmts
    where
      go [] = dExpr e
      go (SBind n ps rhs : rest) = do
        rhs' <- dExpr rhs
        let rhs'' = if null ps then rhs' else CLam ps rhs'
        CLet n rhs'' <$> go rest
      go (SBindPat p rhs : rest) = do
        rhs' <- dExpr rhs
        s <- fresh "bind"
        k <- go rest
        body <- matchPat (CVar s) p k (CErr ("let pattern: no match; pattern was " ++ show p))
        pure (CLet s rhs' body)
  SCase scrut arms -> do
    s <- fresh "scrut"
    sc' <- dExpr scrut
    body <-
      compileArms
        (CVar s)
        [(p, Nothing, e) | (p, e) <- arms]
        (CErr ("case: no matching pattern; arms were " ++ show (map fst arms)))
    pure (CLet s sc' body)
  SBin "|>" a f -> CApp <$> dExpr f <*> dExpr a
  SBin ">>" a b -> do
    a' <- dExpr a
    b' <- dExpr b
    u <- fresh "seq"
    pure (CLet u a' b')
  SBin "|>?" a f -> do
    v <- fresh "ok"
    e <- fresh "err"
    dExpr (SCase a [(PCon "Ok" [PVar v], SApp f (SVar v)), (PCon "Err" [PVar e], SApp (SVar "Err") (SVar e))])
  SBin "and" a b ->
    dExpr (SCase a [(PCon "True" [], b), (PCon "False" [], SVar "False")])
  SBin "or" a b ->
    dExpr (SCase a [(PCon "True" [], SVar "True"), (PCon "False" [], b)])
  SBin "::" a b -> dExpr (SApp (SApp (SVar "Cons") a) b)
  SBin op a b -> do
    a' <- dExpr a
    b' <- dExpr b
    pure (CApp (CApp (CVar op) a') b')
  SProj e path -> do
    e' <- dExpr e
    foldM projField e' path
  SRec fs -> do
    let sorted = sortOn fst fs
    tid <- shapeId (map fst sorted)
    -- records carry their FIELD COUNT in var (unused for shapes: one
    -- shape per tid).  The runtime's Vec fix_layout reads it to give
    -- record elements SoA columns by default -- the "no field counts
    -- in headers" limitation, closed where it bit hardest.
    CMk tid (length sorted) <$> mapM (dExpr . snd) sorted
  SUpd m assigns -> do
    m' <- dExpr m
    v <- fresh "rec"
    body <- updateRecord (CVar v) assigns
    pure (CLet v m' body)
  STup es -> do
    -- a tuple of any width is a real constructor cell (tupCon)
    con <- tupCon (length es)
    (tid, var, _) <- conInfo con
    CMk tid var <$> mapM dExpr es
  SList es -> dExpr (foldr (\x acc -> SApp (SApp (SVar "Cons") x) acc) (SVar "Nil") es)
  SStrI segs -> do
    parts <- mapM segCore segs
    pure $ case parts of
      [] -> CStr ""
      (p : ps) -> foldl' (\acc x -> CApp (CApp (CVar "strcat") acc) x) p ps
    where
      segCore (SegStr s) = pure (CStr s)
      segCore (SegExpr e) = CApp (CVar "str") <$> dExpr e

-- A tuple is as wide as it is written.  Tup2..Tup8 keep their small typeids
-- (runtime/fpr.h); a wider one is typeid tupWideBase + n, a range of its own
-- between the record shapes and the unit types, which the runtime reads the
-- arity back out of (render, Vec columns).  It used to stop at 8.
tupCon :: Int -> D String
tupCon n
  | n >= 2 = pure ("Tup" ++ show n)
  | otherwise = error ("tuple of " ++ show n ++ " elements")

tupWideBase :: Int
tupWideBase = 0x10000000 -- fpr.h T_TUPN

wideTup :: Name -> Maybe (Int, Int, Int)
wideTup c = case c of
  'T' : 'u' : 'p' : ds | not (null ds), all isDigit ds, n > 8 -> Just (tupWideBase + n, 0, n)
    where n = read ds
  _ -> Nothing

conInfo :: Name -> D (Int, Int, Int)
conInfo c = do
  cons <- gets dCons
  case M.lookup c cons of
    Just i -> pure i
    Nothing | Just i <- wideTup c -> pure i
    Nothing -> error ("unknown constructor: " ++ c)

shapeId :: [Name] -> D Int
shapeId fs = do
  shapes <- gets dShapes
  case M.lookup (sort fs) shapes of
    Just i -> pure i
    Nothing -> error ("unknown record shape: " ++ show fs)

projField :: Core -> Name -> D Core
projField scrut f = do
  shapes <- gets dShapes
  let cands = [(tid, idx, length fs) | (fs, tid) <- M.toList shapes, f `elem` fs, let idx = length (takeWhile (/= f) (sort fs))]
  case cands of
    [] -> pure (CErr ("no record shape has field ." ++ f))
    [(_, idx, _)] -> pure (CProj idx scrut)
    many' -> do
      v <- fresh "r"
      let chain = foldr (\(tid, idx, ar) rest -> CIf (CTagEq tid ar (CVar v)) (CProj idx (CVar v)) rest) (CErr ("no shape with field ." ++ f ++ " matched")) many'
      pure (CLet v scrut chain)

updateRecord :: Core -> [([Name], SExpr)] -> D Core
updateRecord scrut assigns = do
  shapes <- gets dShapes
  let roots = nub (map (head . fst) assigns)
      cands = [(fs, tid) | (fs, tid) <- M.toList shapes, all (`elem` fs) roots]
  when (null cands) $ error ("no record shape has fields " ++ show roots)
  arms <- mapM rebuild cands
  pure $ case arms of
    [(_, _, body)] -> body
    _ ->
      foldr
        (\(tid, ar, body) rest -> CIf (CTagEq tid ar scrut) body rest)
        (CErr "record update: no shape matched")
        arms
  where
    rebuild (fs, tid) = do
      let sorted = sort fs
      fields <- mapM (fieldValue tid) (zip [0 ..] sorted)
      pure (tid, length fs, CMk tid (length fs) fields)
      where
        fieldValue _ (idx, f) =
          case [(path, e) | (path, e) <- assigns, head path == f] of
            [] -> pure (CProj idx scrut)
            [([_], e)] -> dExpr e
            deeper -> do
              let subAssigns = [(tail p, e) | (p, e) <- deeper]
              updateRecord (CProj idx scrut) subAssigns

compileArms :: Core -> [(SPat, Maybe SExpr, SExpr)] -> Core -> D Core
compileArms scrut arms fallback = go True arms
  where
    go _ [] = pure fallback
    go first ((p, g, body) : rest) = do
      nxt0 <- go False rest
      -- A nested pattern has several failure edges. Copying the remaining
      -- arms into each edge grows the Core tree exponentially. Bind one
      -- delayed continuation OUTSIDE the pattern's binders; lambda lifting
      -- captures the enclosing locals, including names shadowed by this arm.
      -- The dummy argument keeps a capture-free fallback delayed too (a
      -- zero-arity lifted binding would be evaluated eagerly). liftProg
      -- recognizes these private binders and emits saturated direct calls.
      let build nxt = do
            body' <- dExpr body
            inner <- case g of
              Nothing -> pure body'
              Just ge -> do
                ge' <- dExpr ge
                pure (CIf ge' body' nxt)
            -- Omit the final head test only when earlier arms cover every
            -- other constructor. Single-constructor types retain the test.
            certain <- if null rest && not first && null [() | (_, Just _, _) <- arms] then coveredHead p else pure False
            if certain
              then case p of
                PCon _ ps -> matchFields scrut ps inner nxt
                PTup ps -> matchFields scrut ps inner nxt
                _ -> matchPat scrut p inner nxt
              else matchPat scrut p inner nxt
      case nxt0 of
        CErr _ -> build nxt0
        _ | patternTests p + maybe 0 (const 1) g > 1 -> do
          jn <- fresh "$case_fb"
          unit <- fresh "$case_unit"
          matched <- build (CApp (CVar jn) (CInt 0))
          pure (CLet jn (CLam [unit] nxt0) matched)
        _ -> build nxt0
    -- every other constructor of p's type heads an earlier arm whose
    -- sub-patterns cannot fail
    coveredHead :: SPat -> D Bool
    coveredHead p = do
      cons <- gets dCons
      let irrefutable = \case
            PVar _ -> True
            PWild -> True
            PSig _ _ -> True
            PRec _ -> True
            _ -> False
          headName = \case
            PCon c ps | all irrefutable ps -> Just c
            _ -> Nothing
          earlier = [c | (q, _, _) <- init arms, Just c <- [headName q]]
      case p of
        PCon c _ | Just (tid, _, _) <- M.lookup c cons ->
          pure (and [c' `elem` earlier | (c', (t, _, _)) <- M.toList cons, t == tid, c' /= c])
        _ -> pure False

-- Number of refutable tests that can enter a pattern's failure continuation.
patternTests :: SPat -> Int
patternTests = \case
  PWild -> 0; PVar _ -> 0; PRec _ -> 0; PSig _ _ -> 0
  PInt _ -> 1; PStr _ -> 1
  PCon _ ps -> 1 + sum (map patternTests ps)
  PTup ps -> 1 + sum (map patternTests ps)

matchPat :: Core -> SPat -> Core -> Core -> D Core
matchPat scrut p ok fail' = case p of
  PWild -> pure ok
  PVar x -> pure (CLet x scrut ok)
  PSig x _ -> pure (CLet x scrut ok) -- erased by erasePSig; PVar behavior if one survives
  PInt n -> pure (CIf (CApp (CApp (CVar "==") scrut) (CInt n)) ok fail')
  PStr s -> pure (CIf (CApp (CApp (CVar "==") scrut) (CStr s)) ok fail')
  PCon c ps -> do
    (tid, var, ar) <- conInfo c
    unless (length ps == ar) $ error ("constructor " ++ c ++ " arity mismatch in pattern")
    inner <- matchFields scrut ps ok fail'
    pure (CIf (CTagEq tid var scrut) inner fail')
  PTup ps -> do
    con <- tupCon (length ps)
    (tid, var, _) <- conInfo con
    inner <- matchFields scrut ps ok fail'
    pure (CIf (CTagEq tid var scrut) inner fail')
  PRec fs -> do
    let bind [] = pure ok
        bind (f : rest) = do
          proj <- projField scrut f
          CLet f proj <$> bind rest
    bind fs

matchFields :: Core -> [SPat] -> Core -> Core -> D Core
matchFields scrut ps ok fail' = go (zip [0 ..] ps)
  where
    go [] = pure ok
    go ((i, p) : rest) = do
      inner <- go rest
      matchPat (CProj i scrut) p inner fail'

compileTop :: [STop] -> D Prog
compileTop = compileTopBy compileGroup

-- A stage may supply a checked group lowerer while retaining the same
-- constructor stubs, source grouping and fresh-name order.
compileTopBy :: ((Name, [([SPat], [SGuard], SExpr)]) -> D (Name, ([Name], Core))) -> [STop] -> D Prog
compileTopBy lowerGroup tops = do
  conGlobals <- constructorStubs
  binds <- mapM lowerGroup (groupClauses tops)
  pure (M.union (M.fromList binds) conGlobals)

constructorStubs :: D Prog
constructorStubs = do
  cons <- gets dCons
  pure (M.fromList [(c, (params, CMk tid var (map CVar params)))
       | (c, (tid, var, ar)) <- M.toList cons, let params = ["x" ++ show i | i <- [1 .. ar]]])

-- EVERY clause of a name, in source order, wherever it sits. Inference reads
-- a function that way too; contiguous grouping silently discarded clauses.
groupClauses :: [STop] -> [(Name,[([SPat],[SGuard],SExpr)])]
groupClauses tops =
  [ (n, [(ps,g,b) | TBind n' ps g b <- tops, n'==n])
  | n <- nub [n | TBind n _ _ _ <- tops] ]

compileGroup :: (Name, [([SPat], [SGuard], SExpr)]) -> D (Name, ([Name], Core))
compileGroup (n, clauses@((ps0, _, _) : _)) = do
  let arity = length ps0
  args <- mapM (\i -> fresh ("a" ++ show i)) [1 .. arity]
  body <- goClauses args clauses
  pure (n, (args, body))
  where
    goClauses _ [] = pure (CErr ("no matching clause for " ++ n))
    goClauses args ((ps, g, b) : rest) = do
      nxt0 <- goClauses args rest
      -- JOIN POINT: matchPat inlines the fail continuation at EVERY
      -- test site, so a clause with t tests duplicates the whole
      -- remaining-clauses tree t times — exponential in the worst
      -- case. When a clause can fail from more than one place, bind
      -- the rest ONCE as a lifted top-level function and fail into a
      -- saturated call to it: in tail position that is a TCO'd jump
      -- (zero stack), it passes the function-entry fuel safepoint
      -- (uniform accounting: one unit per clause fallen through), and
      -- code size goes linear in the number of clauses.
      nxt <- case sum (map patternTests ps) + length g of
        t | t > 1, not (trivial nxt0) -> do
          jn <- fresh (n ++ "_fb")
          modify (\s -> s {dLifted = (jn, args, nxt0) : dLifted s, dJoins = jn : dJoins s})
          pure (foldl' CApp (CVar jn) (map CVar args))
        _ -> pure nxt0
      b' <- dExpr b
      inner <- foldGuards g b' nxt
      matchMany (zip (map CVar args) ps) inner nxt
    -- guards run left to right; a pattern guard binds its pattern for
    -- the guards to its right and for the body, and falls through to
    -- the next clause on a non-match, exactly like a pattern test
    foldGuards [] ok _ = pure ok
    foldGuards (gd : rest) ok nxt = do
      inner <- foldGuards rest ok nxt
      case gd of
        GBool ge -> do ge' <- dExpr ge; pure (CIf ge' inner nxt)
        GPat p ge -> do
          ge' <- dExpr ge
          sv <- fresh "gp"
          m <- matchPat (CVar sv) p inner nxt
          pure (CLet sv ge' m)
    trivial (CErr _) = True
    trivial _ = False
    matchMany [] ok _ = pure ok
    matchMany ((s, p) : rest) ok fail' = do
      inner <- matchMany rest ok fail'
      matchPat s p inner fail'
compileGroup (n, []) = error ("empty clause group: " ++ n)

--------------------------------------------------------------------------------
-- Lambda lifting
--------------------------------------------------------------------------------

liftProg :: Prog -> D Prog
liftProg prog = do
  -- clause-fallthrough JOIN functions were registered in dLifted during
  -- compileTop; they are globals-to-be, so lifting must not treat a
  -- reference to one as a lambda capture
  joins0 <- gets (map (\(jn, _, _) -> jn) . dLifted)
  let globalNames = M.keysSet prog `S.union` S.fromList joins0
  lifted <- M.traverseWithKey (\_ (ps, b) -> (ps,) <$> liftC globalNames ps b) prog
  extra <- gets dLifted
  modify (\s -> s {dLifted = []})
  extra' <-
    mapM
      ( \(n, ps, b) -> do
          b' <- liftC globalNames ps b
          pure (n, (ps, b'))
      )
      extra
  pure (M.union lifted (M.fromList extra'))
  where
    liftC globals bound = go (foldr (:) [] bound)
      where
        go env = \case
          -- Case failure continuations never escape as values. Lower them
          -- directly, rather than allocating a PAP and applying it: native
          -- tail calls must stay saturated calls, including through a case.
          CLet jn (CLam ps fallback) body | "$case_fb_" `isPrefixOf` jn -> do
            fallback' <- go (ps ++ env) fallback
            let capture = nub [v | v <- freeVars fallback', v `notElem` ps, v `elem` env]
            -- Snapshot captures outside the pattern binders. A failed arm
            -- may have bound the same spelling before its last test failed.
            saved <- mapM (const (fresh "$case_capture")) capture
            nm <- fresh "case_join"
            modify (\s -> s {dLifted = (nm, capture ++ ps, fallback') : dLifted s, dJoins = nm : dJoins s})
            let target = foldl' CApp (CVar nm) (map CVar saved)
            body' <- go (saved ++ env) (replaceJoin jn target body)
            pure (foldr (\(v, snapshot) b -> CLet snapshot (CVar v) b) body' (zip capture saved))
          CLam ps body -> do
            body' <- go (ps ++ env) body
            -- A LEXICAL BINDER WINS over a global of the same name.
            -- Testing globals/prims first dropped such a name from the
            -- capture set, so the lifted body resolved it to the global
            -- instead of the enclosing parameter -- silently, with a
            -- wrong value (`wrap tag x = (fn y -> "{tag}-{y}") x` printed
            -- the global `tag` function). Membership in `env` already
            -- means "bound out here", which is exactly what to capture;
            -- anything not in `env` is a global or prim reference and is
            -- filtered out by that same test.
            let capture = nub [v | v <- freeVars body', v `notElem` ps, v `elem` (env :: [Name])]
            nm <- fresh "lifted"
            modify (\s -> s {dLifted = (nm, capture ++ ps, body') : dLifted s})
            pure (foldl' CApp (CVar nm) (map CVar capture))
          CApp a b -> CApp <$> go env a <*> go env b
          CLet x a b -> CLet x <$> go env a <*> go (x : env) b
          CIf c t e -> CIf <$> go env c <*> go env t <*> go env e
          CMk t v fs -> CMk t v <$> mapM (go env) fs
          CTagEq t v e -> CTagEq t v <$> go env e
          CProj i e -> CProj i <$> go env e
          other -> pure other

-- Substitute only the private continuation binder. Fresh saved captures in
-- the replacement cannot be shadowed by source-level names.
replaceJoin :: Name -> Core -> Core -> Core
replaceJoin name target = go
  where
    go = \case
      CVar n | n == name -> target
      CApp f x -> CApp (go f) (go x)
      CLam ps b -> CLam ps (if name `elem` ps then b else go b)
      CLet n a b -> CLet n (go a) (if n == name then b else go b)
      CIf c t e -> CIf (go c) (go t) (go e)
      CMk t v fs -> CMk t v (map go fs)
      CTagEq t v e -> CTagEq t v (go e)
      CProj i e -> CProj i (go e)
      e -> e


liftFix :: Prog -> D Prog
liftFix p = do
  -- NOTE dLifted is NOT cleared here: compileTop registers clause-
  -- fallthrough join functions in it, and clearing before the first
  -- liftProg round would silently drop them (their call sites then
  -- resolve as fpr_g_ closure loads of a symbol that never exists).
  -- liftProg consumes-and-clears instead, which keeps the fixpoint
  -- rounds from re-adding old entries.
  p' <- liftProg p
  -- Lifting an existing clause join can enqueue more functions even when
  -- every lambda in p' has disappeared. Drain that work before finishing.
  pending <- gets dLifted
  if not (null pending) || any (hasLam . snd . snd) (M.toList p') then liftFix p' else pure p'
  where
    hasLam = \case
      CLam _ _ -> True
      CApp a b -> hasLam a || hasLam b
      CLet _ a b -> hasLam a || hasLam b
      CIf c t e -> hasLam c || hasLam t || hasLam e
      CMk _ _ fs -> any hasLam fs
      CTagEq _ _ e -> hasLam e
      CProj _ e -> hasLam e
      _ -> False

