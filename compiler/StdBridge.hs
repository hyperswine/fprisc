{-# LANGUAGE LambdaCase #-}

-- StdBridge.hs — the seam between the FP-RISC frontend and the StdCheck
-- proof engine (`fprc --stdcheck file.fpr`).
--
-- WHAT THIS IS: the PoC of "std is provable" wired to the REAL parser.
-- StdCheck.hs is the engine (interval abstract domain, conservative
-- termination/measure certification, symbolic WCET equations, dynamic
-- check insertion).  This module lowers a conservative SUBSET of parsed
-- .fpr top-levels into StdCheck's Prog and runs compile+report.
--
-- THE CONTRACT (PoC conventions, all zero-churn on the shared frontend):
--
--   * A function is DECLARED SAFE iff it carries a signature whose
--     parameter and return types are all Int.  "std means: signed,
--     Int-fragment, obligations discharged" — a signed Int function
--     that falls outside the checkable fragment is a hard error, the
--     same way `unsafe` leaking into std is.
--   * Parameter preconditions come from the existing contract syntax
--     `(n : Int | n > 0)` — the same decidable fragment Precond.hs
--     uses; comparisons against literals become intervals here.
--   * POSTCONDITIONS have no sig slot yet, so the PoC channel is a
--     sibling sig named `post_<f>`: `post_f : (r : Int | r >= 1) -> Int.`
--     declares f's result interval.  (The honest fix is a ret-precond
--     slot in TSig; deferred to keep module hashes stable.)
--   * A name containing "unsafe" is UnsafeFn regardless of anything.
--   * `foldRange lo hi f acc` lowers to the builtin bounded recursion
--     scheme (StdCheck.Fold) — its bound is generic, proven once in
--     the engine's transfer function, never per use-site.
--   * Calls to names with no definition in the file (builtins, core.*)
--     lower to OPAQUE UNSAFE externs: their cost is ω(name) and safety
--     is infectious upward exactly as designed — a declared-safe
--     function reaching one is a compile error, an inferred function
--     is silently demoted with a note.
module StdBridge (runStdCheck) where

import Control.Monad.State.Strict
import Data.Char (toLower)
import Data.List (isInfixOf, nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC
import qualified StdCheck as SC

--------------------------------------------------------------------------
-- interval extraction from the contract predicate fragment
--------------------------------------------------------------------------

predItv :: Name -> SExpr -> Maybe SC.Itv
predItv n e = case e of
  SApp (SApp (SVar "and2") a) b -> SC.meetItv <$> predItv n a <*> predItv n b
  SBin "and" a b -> SC.meetItv <$> predItv n a <*> predItv n b
  SBin op (SVar x) (SInt k) | x == n -> cmpItv op k
  SBin op (SInt k) (SVar x) | x == n -> cmpItv (flipOp op) k
  _ -> Nothing
  where
    cmpItv ">" k = Just (SC.atLeast (k + 1))
    cmpItv ">=" k = Just (SC.atLeast k)
    cmpItv "<" k = Just (SC.atMost (k - 1))
    cmpItv "<=" k = Just (SC.atMost k)
    cmpItv "==" k = Just (SC.exactly k)
    cmpItv _ _ = Nothing
    flipOp ">" = "<"
    flipOp ">=" = "<="
    flipOp "<" = ">"
    flipOp "<=" = ">="
    flipOp o = o

isIntTy :: Ty -> Bool
isIntTy (TCon "Int" []) = True
isIntTy _ = False

--------------------------------------------------------------------------
-- surface lambda lift
--
-- The compiler proper lambda-lifts long before codegen, so a lambda in
-- `foldRange`'s step position is NOT outside the checkable fragment in
-- any real sense -- only outside this bridge's view of the surface tree.
-- Rather than re-plumbing the bridge onto the lifted Core, we lift the
-- one shape std actually writes AT THE SURFACE: a lambda in a call-
-- argument position becomes a synthesized top-level clause group
-- `<host>__stepN` and the argument becomes its name.  Captures need no
-- special handling BECAUSE of how the engine treats free names:
--
--   * a captured name used in CALL-HEAD position (retryN's `step i`)
--     stays a free call in the lifted body, which the driver below
--     already turns into an opaque unsafe extern -- omega(step), the
--     exact uncertainty term the retry equation states;
--   * a captured name used as a VALUE has no analogue in the engine's
--     Expr (variables resolve to params only), so that group is
--     reported outside the fragment with the honest instruction: name
--     the step function and pass the value as an accumulator.
--------------------------------------------------------------------------

liftSurfaceLams :: [STop] -> [STop]
liftSurfaceLams tops = concat (evalState (mapM liftTop tops) (0 :: Int, []))
  where
    liftTop (TBind n pats gs body) = do
      body' <- goE n body
      (i, outs) <- get
      put (i, [])
      pure (TBind n pats gs body' : outs)
    liftTop t = pure [t]
    -- state: (fresh counter across the file, lifted tops of the current group)
    goE :: Name -> SExpr -> State (Int, [STop]) SExpr
    goE host e = case e of
      SMark o x -> SMark o <$> goE host x
      SApp f a -> SApp <$> goE host f <*> goA host a
      SLam ps b -> SLam ps <$> goE host b -- head-position lambda: leave it
      SBlock ss fin -> SBlock <$> mapM goS ss <*> goE host fin
      SCase s arms -> SCase <$> goE host s <*> mapM (\(p, b) -> (,) p <$> goE host b) arms
      SBin o a b -> SBin o <$> goE host a <*> goE host b
      SProj a ns -> (`SProj` ns) <$> goE host a
      SRec fs -> SRec <$> mapM (\(k, v) -> (,) k <$> goE host v) fs
      SUpd a us -> SUpd <$> goE host a <*> mapM (\(p, v) -> (,) p <$> goE host v) us
      STup es -> STup <$> mapM (goE host) es
      SList es -> SList <$> mapM (goE host) es
      SStrI segs -> SStrI <$> mapM (\case SegExpr x -> SegExpr <$> goE host x; s -> pure s) segs
      _ -> pure e
      where
        goS (SBind x ps v) = SBind x ps <$> goE host v
        goS (SBindPat p v) = SBindPat p <$> goE host v
    -- an ARGUMENT position: this is where a lambda gets lifted
    goA host (SLam ps b) = do
      b' <- goE host b
      (i, outs) <- get
      let nm = host ++ "__step" ++ show i
      put (i + 1, outs ++ [TBind nm (map PVar ps) [] b'])
      pure (SVar nm)
    goA host a = goE host a

--------------------------------------------------------------------------
-- expression lowering (fresh call-site ids threaded through State)
--------------------------------------------------------------------------

type B = State Int

freshSite :: B Int
freshSite = state (\i -> (i, i + 1))

cmpOf :: Name -> Maybe SC.COp
cmpOf = \case
  "<" -> Just SC.CLt
  "<=" -> Just SC.CLe
  ">" -> Just SC.CGt
  ">=" -> Just SC.CGe
  "==" -> Just SC.CEq
  "/=" -> Just SC.CNe
  _ -> Nothing

aopOf :: Name -> Maybe SC.AOp
aopOf = \case
  "+" -> Just SC.Add
  "-" -> Just SC.Sub
  "*" -> Just SC.Mul
  "/" -> Just SC.Div
  _ -> Nothing

-- a comparison in condition position
bridgeCond :: SExpr -> B (Either String SC.CExpr)
bridgeCond (SBin op a b)
  | Just c <- cmpOf op = do
      ea <- bridgeE a
      eb <- bridgeE b
      pure (SC.Cmp c <$> ea <*> eb)
bridgeCond e = pure (Left ("condition outside the comparison fragment: " ++ take 40 (show e)))

bridgeE :: SExpr -> B (Either String SC.Expr)
bridgeE = \case
  SInt k -> pure (Right (SC.Lit k))
  SVar x -> pure (Right (SC.Var x))
  SBin op a b
    | Just o <- aopOf op -> do
        ea <- bridgeE a
        eb <- bridgeE b
        pure (SC.Bin o <$> ea <*> eb)
  -- case cond of True -> t | False -> f   (and the flipped arm order)
  SCase scrut arms
    | Just (t, f) <- boolArms arms -> do
        ec <- bridgeCond scrut
        et <- bridgeE t
        ef <- bridgeE f
        pure (SC.If <$> ec <*> et <*> ef)
  SMark _ x -> bridgeE x
  SBlock stmts final -> bridgeBlock stmts final
  app@(SApp _ _) ->
    let (hd, args) = spine app []
     in case hd of
          SVar "foldRange" | [lo, hi, SVar f, acc] <- args -> do
            site <- freshSite
            elo <- bridgeE lo
            ehi <- bridgeE hi
            eac <- bridgeE acc
            pure (SC.Fold site <$> elo <*> ehi <*> pure f <*> eac)
          SVar f -> do
            site <- freshSite
            eargs <- mapM bridgeE args
            pure (SC.Call site f <$> sequence eargs)
          _ -> pure (Left "call head is not a plain name")
  e -> pure (Left ("outside the checkable fragment: " ++ take 40 (show e)))
  where
    spine (SApp f a) acc = spine f (a : acc)
    spine hd acc = (hd, acc)
    boolArms [(PCon "True" [], t), (PCon "False" [], f)] = Just (t, f)
    boolArms [(PCon "False" [], f), (PCon "True" [], t)] = Just (t, f)
    boolArms _ = Nothing

bridgeBlock :: [SStmt] -> SExpr -> B (Either String SC.Expr)
bridgeBlock [] final = bridgeE final
bridgeBlock (SBind x [] e : rest) final = do
  ee <- bridgeE e
  er <- bridgeBlock rest final
  pure (SC.Let x <$> ee <*> er)
bridgeBlock (s : _) _ = pure (Left ("block statement outside fragment: " ++ take 40 (show s)))

--------------------------------------------------------------------------
-- clause groups -> one FnDef body (guards become If-chains)
--------------------------------------------------------------------------

-- one clause: params must be PVar or PInt; PInt positions become
-- equality conditions against the group's canonical param names.
bridgeClause :: [Name] -> ([SPat], [SGuard], SExpr) -> B (Either String ([SC.CExpr], SC.Expr))
bridgeClause pnames (pats, guards, body) = do
  intConds <-
    mapM
      ( \(pn, p) -> case p of
          PVar _ -> pure (Right Nothing)
          PWild -> pure (Right Nothing)
          PInt k -> pure (Right (Just (SC.Cmp SC.CEq (SC.Var pn) (SC.Lit k))))
          _ -> pure (Left "constructor/tuple pattern outside fragment")
      )
      (zip pnames pats)
  gConds <-
    mapM
      ( \case
          GBool e -> bridgeCond e
          GPat {} -> pure (Left "pattern guard outside fragment")
      )
      guards
  eb <- bridgeE body
  pure $ do
    ics <- sequence intConds
    gcs <- sequence gConds
    b <- eb
    pure ([c | Just c <- ics] ++ gcs, b)

-- fold a clause list into nested Ifs; the last clause is the default.
clausesToBody :: [([SC.CExpr], SC.Expr)] -> Either String SC.Expr
clausesToBody [] = Left "no clauses"
clausesToBody [( [], b)] = Right b
clausesToBody [(_, b)] = Right b -- last clause: its conditions are the fallthrough default
clausesToBody ((cs, b) : rest) = do
  r <- clausesToBody rest
  pure (foldr (\c acc -> SC.If c acc r) b cs)

canonicalParams :: [[SPat]] -> [Name]
canonicalParams clauses =
  [ pick i | i <- [0 .. arity - 1] ]
  where
    arity = case clauses of [] -> 0; (p : _) -> length p
    pick i = case [n | ps <- clauses, PVar n <- [ps !! i]] of
      (n : _) -> n
      [] -> "_p" ++ show i

--------------------------------------------------------------------------
-- the whole-file bridge + driver
--------------------------------------------------------------------------

isUnsafeName :: Name -> Bool
isUnsafeName n = "unsafe" `isInfixOf` map toLower n

isCoreName :: Name -> Bool
isCoreName n = take 5 n == "core_" || take 5 n == "core."

runStdCheck :: [STop] -> IO ()
runStdCheck tops0 = do
  let tops = liftSurfaceLams tops0
  let sigs = M.fromList [(n, (ps, ret, pcs)) | TSig n (ps, ret) pcs <- tops]
      posts =
        M.fromList
          [ (drop 5 n, itv)
            | TSig n (_, _) pcs <- tops,
              take 5 n == "post_",
              Just (pn, pe) <- take 1 pcs,
              Just itv <- [predItv pn pe]
          ]
      clauseGroups =
        M.toList $
          M.fromListWith
            (flip (++))
            [(n, [(pats, gs, body)]) | TBind n pats gs body <- tops, n /= "main"]
      declaredSafe n = case M.lookup n sigs of
        Just (ps, ret, _) -> all isIntTy ps && isIntTy ret && not (isUnsafeName n)
        Nothing -> False
      paramItv n pn = case M.lookup n sigs of
        Just (_, _, pcs) ->
          case [itv | Just (x, pe) <- pcs, x == pn, Just itv <- [predItv x pe]] of
            (i : _) -> i
            [] -> SC.top
        Nothing -> SC.top
      postOf n = M.findWithDefault SC.top n posts

      -- bridge every clause group (foldRange itself is the builtin scheme:
      -- its .fpr definition exists so the file also COMPILES, but the
      -- checker sees the once-proven Fold bound instead of re-analyzing it)
      bridged =
        flip evalState 1000 $
          mapM
            ( \(n, clauses) -> do
                let pnames = canonicalParams [ps | (ps, _, _) <- clauses]
                res <- bridgeGroup n pnames clauses
                pure (n, res)
            )
            [ (n, clauses)
              | (n, clauses) <- clauseGroups,
                n /= "foldRange",
                take 5 n /= "post_",
                not (isCoreName n) -- core.* / core_* is the raw tier: ALWAYS an opaque unsafe extern to std, even when defined
            ]
      bridgeGroup n pnames clauses = do
        ecs <- mapM (bridgeClause pnames) clauses
        pure $ do
          cs <- sequence ecs
          body <- clausesToBody cs
          let params = [SC.Param pn (paramItv n pn) | pn <- pnames]
              safety
                | isUnsafeName n = SC.UnsafeFn
                | otherwise = SC.SafeFn -- provisional; demotion pass below
          pure (SC.FnDef n params (postOf n) safety body)

      okDefs = M.fromList [(n, fd) | (n, Right fd) <- bridged]
      failed = [(n, err) | (n, Left err) <- bridged]

      -- every call target with no definition = opaque unsafe extern ω(g)
      calledNames = nub (concat [[g | (_, g, _) <- SC.callsIn (SC.fBody fd)] | fd <- M.elems okDefs])
      arityOf g = maximum (1 : [length as | fd <- M.elems okDefs, (_, g', as) <- SC.callsIn (SC.fBody fd), g' == g])
      externs =
        [ SC.FnDef
            g
            [SC.Param ("a" ++ show i) SC.top | i <- [1 .. arityOf g]]
            SC.top
            SC.UnsafeFn
            (SC.Call (negate 1) g [SC.Var ("a" ++ show i) | i <- [1 .. arityOf g]])
          | g <- calledNames,
            not (M.member g okDefs),
            g `notElem` [n | (n, _) <- failed]
        ]
      failedStubs =
        [ SC.FnDef n [SC.Param "a1" SC.top] SC.top SC.UnsafeFn (SC.Call (negate 2) n [SC.Var "a1"])
          | (n, _) <- failed
        ]

      env0 = M.fromList [(SC.fName f, f) | f <- M.elems okDefs ++ externs ++ failedStubs]
      -- transitive demotion: an INFERRED-safe function reaching unsafety
      -- is quietly demoted; a DECLARED-safe one is left for the engine
      -- to reject loudly (unsafety leaking into std is an error).
      unsafeSet = fixpt (S.fromList [SC.fName f | f <- M.elems env0, SC.fSafety f == SC.UnsafeFn])
      fixpt s =
        let s' =
              s
                `S.union` S.fromList
                  [ SC.fName f
                    | f <- M.elems env0,
                      not (declaredSafe (SC.fName f)),
                      any (`S.member` s) (SC.callees f)
                  ]
         in if s' == s then s else fixpt s'
      demote f
        | SC.fName f `S.member` unsafeSet, not (declaredSafe (SC.fName f)) = f {SC.fSafety = SC.UnsafeFn}
        | otherwise = f
      prog = map demote (M.elems okDefs) ++ externs ++ failedStubs

  mapM_
    (\(n, err) -> putStrLn ("std: " ++ n ++ ": NOT in the checkable fragment (" ++ err ++ ")" ++ if declaredSafe n then "  <-- signed Int function: this is an error" else "  (inferred unsafe, opaque cost)"))
    failed
  case [n | (n, _) <- failed, declaredSafe n] of
    (_ : _) -> putStrLn "stdcheck: FAILED (signed functions outside the fragment)"
    [] -> case SC.compile prog of
      Left errs -> mapM_ (putStrLn . SC.showErr) errs >> putStrLn "stdcheck: FAILED"
      Right c -> do
        putStr (SC.report [f | f <- prog, M.member (SC.fName f) okDefs] c)
        putStrLn "stdcheck: OK — every obligation above is either PROVEN or carries an inserted DYNAMIC check; ω terms mark exactly where unsafe cost enters."
