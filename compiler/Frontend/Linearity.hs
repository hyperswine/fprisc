{-# OPTIONS_GHC -O2 #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE LambdaCase, TupleSections #-}

-- Linearity checking over surface syntax and ownership-shape evidence.
module Frontend.Linearity
  (LinInfo(..), LinearityResult, checkLinearity, linearityDiagnostics, linearityConstraints,
   primNames, shapeOfTy, shapeOfTyIn, buildLinInfo, builtinConSh, builtinConAr,
   conFields, Cnt, LRes, lcheck, lcheckOnce, wildLinErrs, bindPat, linExpr) where

import Core.Syntax ( Name )
import qualified Diagnostic.Syntax as Diagnostic
import Ownership.Finding (Finding(..),atFinding)
import Source.Span (SourceOffset(..))
import Data.List ( foldl', isPrefixOf, nub, sort )
import Data.Maybe ( fromMaybe, isJust, isNothing )
import Frontend.Paths ( shapeTyTable )
import Frontend.Syntax
    ( Ty(..),
      STop(TBind, TAlias, TSig, TType),
      SGuard(GPat, GBool),
      SPat(..),
      SStmt(SBindPat, SBind),
      Seg(SegExpr),
      SExpr(..) )
import Frontend.Traverse ( sFree )
import Ownership.Shape
    ( LShape(..),
      isLin,
      hardLin,
      eraseVars,
      lcon,
      lown,
      substL,
      bindingsL,
      matchL,
      demandOwnership,
      joinLShape,
      projectOwnership,
      updateOwnership,
      fnParamShape,
      fnResultShape,
      fnResultArity,
      fnVarInfo,
      fnPathName,
      fnVarNested,
      heldVar,
      fieldVar,
      heldAt,
      heldOf,
      heldOfVar,
      heldVarsAt,
      callableArity,
      repeatedCallbackPrims,
      closureShape )
import qualified Data.Map.Strict as M
    ( delete,
      empty,
      filter,
      keys,
      lookup,
      null,
      toList,
      union,
      findWithDefault,
      fromList,
      fromListWith,
      insert,
      intersectionWith,
      map,
      singleton,
      unionWith,
      Map )
import qualified Data.Set as S ( notMember, empty, insert )

primNames :: [Name]
primNames =
  [ "+",
    "-",
    "*",
    "/",
    "%",
    "^",
    "==",
    "!=",
    "<",
    ">",
    "<=",
    ">=",
    "!",
    "print",
    "String.len",
    "str",
    "strcat",
    "error"
  ]


--------------------------------------------------------------------------------
-- Linearity checker (static, pre-desugar).
--------------------------------------------------------------------------------

-- liUnres: per function, the type variables of its signature that its body
-- duplicates or discards, so a call may not instantiate them with an owner.
-- Derived from the bodies by lcheck itself (a fixpoint, callees first).
data LinInfo = LinInfo
  { liLinTys :: [Name],
    liSigs :: M.Map Name ([LShape], LShape),
    liConSh :: M.Map Name (LShape, [LShape]),
    liConAr :: M.Map Name Int,
    liUnres :: M.Map Name [Name],
    -- per constructor, per field: the field's shape with every function
    -- type in it as `fieldVar`, for the construction check (none when the
    -- constructor has no function-typed field)
    liConFnFields :: M.Map Name [LShape]
  }

shapeOfTy :: [Name] -> Ty -> LShape
shapeOfTy lin = shapeOfTyIn lin M.empty

-- A NAMED record type (`Cols = { xs : Vector Int, ... }`, a TShape) is the
-- record it names: its owned fields are owned through a declared signature
-- exactly as they are through an inferred one or a record type spelled out
-- in the signature.  Without this a declared `Cols -> Cols` was a hole: the
-- name resolved to an unrestricted constructor and the vectors inside were
-- invisible to the checker (docs/2026-10-19-STD-SUITE-REPAIRS.md).
shapeOfTyIn :: [Name] -> M.Map Name [(Name, Ty)] -> Ty -> LShape
shapeOfTyIn lin shapes = go S.empty
  where
    go seen = \case
      TTup ts -> LTupS (map (go seen) ts)
      TCon n [] | Just fs <- M.lookup n shapes, n `S.notMember` seen -> LRecS [(f, go (S.insert n seen) t) | (f, t) <- fs] False
      TCon n as -> if n `elem` lin then lown n (map (go seen) as) else lcon n (map (go seen) as)
      TVarT v -> LVar v
      TArrT _ _ -> LU
      TVApp _ _ -> LU
      TRecT fs row -> LRecS [(f, go seen t) | (f, t) <- fs] (isJust row)
      TOther -> LU

buildLinInfo :: [STop] -> LinInfo
buildLinInfo tops = LinInfo lin sigs conSh conAr M.empty conFn
  where
    -- TAlias resolves here too (the sol profile's module aliasing):
    -- an alias of a linear type is linear, and its constructors carry
    -- the target's shapes/arities
    aliases = [(t, tgt) | TAlias t tgt <- tops]
    lin0 = [n | TType n True _ _ <- tops]
    lin = lin0 ++ [t | (t, tgt) <- aliases, tgt `elem` lin0]
    -- function-typed parameters are symbolic callables and a
    -- function-typed result records its arity (docs/2026-11-09-CALLABLE-OWNERSHIP.md)
    sigs = M.fromList [(n, (zipWith param [0 ..] ps, result r)) | TSig n (ps, r) _ <- tops]
    param :: Int -> Ty -> LShape
    param i t = case t of
      TArrT _ _ -> fnParamShape i (arrows t)
      _ -> callables (\path k -> LVar (fnPathName (i : path) k)) t
    field t = case t of
      TArrT _ _ -> fnResultShape (arrows t)
      _ -> callables (\_ k -> fnResultShape k) t
    result t = case arrows t of
      0 -> callables (\_ _ -> LVar heldVar) t
      k -> fnResultShape k
    arrows (TArrT _ b) = 1 + arrows b
    arrows _ = 0 :: Int
    -- the shape of a type with each function type nested in it replaced
    -- by `at path arity`; a type with no function in it is exactly `sh`
    callables at t0 = if hasArrow t0 then walk [] t0 else sh t0
      where
        walk path t = case t of
          TArrT _ _ -> at path (arrows t)
          _ | not (hasArrow t) -> sh t
          TTup ts -> LTupS (zipWith (\j u -> walk (path ++ [j]) u) [0 ..] ts)
          TRecT fs row -> LRecS [(f, walk (path ++ [j]) u) | (j, (f, u)) <- zip [0 ..] fs] (isJust row)
          TCon n as | not (null as) -> (if n `elem` lin then lown else lcon) n (zipWith (\j u -> walk (path ++ [j]) u) [0 ..] as)
          _ -> sh t
    hasArrow t = case t of
      TArrT _ _ -> True
      TTup ts -> any hasArrow ts
      TRecT fs _ -> any (hasArrow . snd) fs
      TCon _ as -> any hasArrow as
      _ -> False
    conFn = M.fromList [(c, map (callables (\_ _ -> LVar fieldVar)) tys) | TType _ _ _ cs <- tops, (c, tys) <- cs, any hasArrow tys]
    -- a constructor of a generic type makes `T a b` with its parameters
    -- symbolic; the fields are the declared field types, parameters symbolic
    conSh0 = M.union
      (M.fromList [(c, ((if linear then lown else lcon) t (map LVar params), map field tys)) | TType t linear params cs <- tops, (c, tys) <- cs])
      builtinConSh
    conSh = foldl' (\m (t, tgt) -> maybe m (\e -> M.insert t e m) (M.lookup tgt m)) conSh0 aliases
    conAr0 = M.union (M.fromList [(c, length tys) | TType _ _ _ cs2 <- tops, (c, tys) <- cs2]) builtinConAr
    conAr = foldl' (\m (t, tgt) -> maybe m (\e -> M.insert t e m) (M.lookup tgt m)) conAr0 aliases
    sh = shapeOfTyIn lin (shapeTyTable tops)

-- the prelude's own generic containers: Result and List
builtinConSh :: M.Map Name (LShape, [LShape])
builtinConSh =
  M.fromList
    [ ("Ok", (LCon "Result" False [LVar "a", LVar "e"], [LVar "a"])),
      ("Err", (LCon "Result" False [LVar "a", LVar "e"], [LVar "e"])),
      ("Cons", (LCon "List" False [LVar "a"], [LVar "a", LCon "List" False [LVar "a"]])),
      ("Nil", (LCon "List" False [LVar "a"], []))
    ]

builtinConAr :: M.Map Name Int
builtinConAr = M.fromList [("Ok", 1), ("Err", 1), ("Cons", 2), ("Nil", 0)]

-- the fields a constructor pattern binds, instantiated from the scrutinee's
-- shape.  A scrutinee whose structure is unknown but owned (a plain LL,
-- reached by a join) is taken to own every generic field.
conFields :: LinInfo -> Name -> LShape -> Maybe [LShape]
conFields li c s = do
  (retSh, args) <- M.lookup c (liConSh li)
  let b = bindingsL [retSh] [s]
      dflt = if hardLin s && M.null b then LL else LU
  pure (map (substL b dflt) args)

type Cnt = M.Map Name Int

type LRes = ([Finding], Maybe Cnt, LShape)

-- The unrestricted-variable constraints come from the bodies and from the
-- calls those bodies make, so they are computed to a fixpoint: a round
-- derives each function's constraints from the current table, and the
-- errors of the round in which the table stops changing are the answer.
data LinearityResult = LinearityResult [Diagnostic.Diagnostic] (M.Map Name [Name])
linearityDiagnostics :: LinearityResult -> [Diagnostic.Diagnostic]
linearityDiagnostics (LinearityResult ds _)=ds
linearityConstraints :: LinearityResult -> M.Map Name [Name]
linearityConstraints (LinearityResult _ constraints)=constraints
checkLinearity :: LinInfo -> [STop] -> LinearityResult
checkLinearity li tops = go (M.map (sort . nub) (M.unionWith (++) (liUnres li) primCallbacks))
  where
    -- a source definition of the same name (a module's own `map`) is read
    -- from its body instead
    defined = [n | TBind n _ _ _ <- tops]
    primCallbacks = M.fromList [(n, vs) | n <- repeatedCallbackPrims, n `notElem` defined, Just (ps, _) <- [M.lookup n (liSigs li)],
                                         let vs = [v | LVar v <- ps, isJust (fnVarInfo v)], not (null vs)]
    -- Each round unions obligations into the old table. The functions and
    -- shape variables are finite, so strict growth terminates. A fixed round
    -- cap could return incomplete ownership evidence for a long wrapper chain.
    go unres =
      let result=checkLinearityRound li {liUnres=unres} tops
          next=linearityConstraints result
      in if next==unres then result else go next

-- Compatibility projections. Compiler consumers keep diagnostics/constraints
-- coupled in the named result and never inspect encoded string markers.
lcheck :: LinInfo -> [STop] -> [String]
lcheck li=map Diagnostic.renderLegacyDiagnostic . linearityDiagnostics . checkLinearity li
lcheckOnce :: LinInfo -> [STop] -> ([String], M.Map Name [Name])
lcheckOnce li tops=let result=checkLinearityRound li tops
  in (map Diagnostic.renderLegacyDiagnostic (linearityDiagnostics result),linearityConstraints result)
checkLinearityRound :: LinInfo -> [STop] -> LinearityResult
checkLinearityRound li tops = LinearityResult (concat [es | (_, es, _) <- results])
  (M.unionWith merge (liUnres li) (M.fromList [(n, cs) | (n, _, cs) <- results, not (null cs)]))
  where
    merge a b = sort (nub (a ++ b))
    results = [(n, [Diagnostic.inDefinition n (Diagnostic.diagnostic Diagnostic.LinearityError offset message)
                   | Violation offset message<-raw],sort (nub [v | RequireUnrestricted v<-raw]))
              | (n,clauses)<-groups,let raw=concatMap (checkClause n) clauses]
    groups = groupTB [b | b@TBind {} <- tops]
    groupTB [] = []
    groupTB (TBind n ps g b : rest) = let (same, others) = span (\(TBind n' _ _ _) -> n' == n) rest in (n, (ps, g, b) : [(p', g', b') | TBind _ p' g' b' <- same]) : groupTB others
    groupTB (_ : rest) = groupTB rest

    checkClause n (pats0, g, body0) =
      -- A clause may bind fewer parameters than its signature declares
      -- (`at t = fn n -> ...` for `Token -> Int -> Int`): the parameters
      -- it does bind still carry their shapes.  A guardless clause whose
      -- body is a lambda binds the lambda's parameters as its own
      -- (`twice = fn f -> (f 0, f 1)` is `twice f = (f 0, f 1)`), so a
      -- callable parameter of a lambda-bodied definition is checked too.
      let (pats, body) = if null g then absorb pats0 body0 else (pats0, body0)
          absorb ps b = case b of
            SMark _ inner | SLam {} <- unmark inner -> absorb ps inner
            SLam xs inner -> absorb (ps ++ map PVar xs) inner
            _ -> (ps, b)
          unmark (SMark _ e) = unmark e
          unmark e = e
          -- the declared result this clause's body produces: the
          -- signature's, or a function (of the parameters it leaves)
          declResult = case M.lookup n (liSigs li) of
            Just (ps, r)
              | length ps == length pats -> r
              | length ps > length pats -> fnResultShape (length ps - length pats)
            _ -> LU
          paramShapes = case M.lookup n (liSigs li) of
            Just (ps, _) | length ps >= length pats -> take (length pats) ps
            Just (ps, r) | fnResultArity r > 0 -> ps ++ replicate (length pats - length ps) LU
            _ -> replicate (length pats) LU
          binds = concat (zipWith (bindPat li) pats paramShapes)
          wildErrs = concat (zipWith (wildLinErrs li) pats paramShapes)
          env = M.fromList binds
          (genv, ge, gc) =
            foldl'
              ( \(en, errs, cnt) (index, gd) -> case gd of
                  GBool gx ->
                    let (e', c', _) = lin' en gx
                     in (en, errs ++ e', M.unionWith (+) cnt (fromMaybe M.empty c'))
                  GPat p gx ->
                    let (e', c', sh) = lin' en gx
                        new = bindPat li p sh
                        en' = M.union (M.fromList new) en
                        -- A failed guard can fall through without disposing
                        -- of a newly created owner. Until failure cleanup is
                        -- modeled, only irrefutable owner bindings are legal.
                        failureErr = concat [demandOwnership sh "a refutable pattern guard may discard a linear result; use an explicit case" | not (irrefutable p)]
                          ++ concat [demandOwnership sh "a later failing guard may discard a newly bound linear value; use an explicit case" | any canFail (drop (index + 1) g)]
                        shadowErr = concat [demandOwnership old ("pattern guard shadows an existing linear variable '" ++ v ++ "'") | (v, _) <- new, Just old <- [M.lookup v en]]
                     in (en', errs ++ e' ++ wildLinErrs li p sh ++ failureErr ++ shadowErr, M.unionWith (+) cnt (fromMaybe M.empty c'))
              )
              (env, [], M.empty)
              (zip [0 ..] g)
          (be, bc, bodyShape) = lin' genv body
          -- a body that returns a single-use closure where the signature
          -- has a function type (an owner it created or holds itself,
          -- not one a caller handed it) makes every result single-use
          heldErr = [RequireUnrestricted heldVar | heldAt declResult bodyShape]
            ++ [RequireUnrestricted (heldOf v) | v <- heldVarsAt declResult bodyShape]
          linear = [v | (v, s) <- M.toList genv, isLin s]
          guardUsed = M.keys (M.filter (> 0) gc)
          guardErr = concat [demandOwnership (M.findWithDefault LU v genv) ("guard uses linear variable(s) " ++ show guardUsed ++ " (guards may re-evaluate on fallthrough)") | v <- guardUsed]
          useErrs = case bc of
            Nothing -> []
            Just c -> concat [demandOwnership (M.findWithDefault LU v genv) ("linear variable '" ++ v ++ "' used " ++ show (M.findWithDefault 0 v c) ++ " time(s), expected exactly 1") | v <- linear, M.findWithDefault 0 v c /= 1]
       in nub (wildErrs ++ ge ++ be ++ guardErr ++ useErrs ++ heldErr)
      where
        lin' = linExpr li
        irrefutable (PVar _) = True
        irrefutable (PSig _ _) = True
        irrefutable (PTup ps) = all irrefutable ps
        irrefutable (PRec _) = True
        irrefutable _ = False
        canFail (GBool _) = True
        canFail (GPat p _) = not (irrefutable p)

-- a WILDCARD that swallows a linear shape is a silent leak: the value
-- is never counted, never consumed, never dropped.  Refuse it -- bind
-- a name and consume it (or `drop` it) instead.  Distributes through
-- tuple patterns so `(x, _) = Vec.get i v` (discarding the returned
-- HANDLE) is caught too.
wildLinErrs :: LinInfo -> SPat -> LShape -> [Finding]
wildLinErrs li p s = case p of
  PWild -> demandOwnership s "a linear value is DISCARDED by `_` -- bind it and consume it (or drop it explicitly)"
  PTup ps -> case s of
    LTupS ss | length ss == length ps -> concat (zipWith (wildLinErrs li) ps ss)
    _ -> []
  PRec names -> case s of
    LRecS fs open ->
      concat [demandOwnership sh ("record pattern discards linear field '" ++ f ++ "'; bind every owned field") | (f, sh) <- fs, f `notElem` names]
        ++ concat [demandOwnership s "cannot destructure an owned record with an open row; its remaining owners are unknown" | open]
    _ -> []
  -- A successful resource-opening constructor can hide a linear field.
  -- Checking only the outer pattern misses `Opened _` and nested forms.
  -- The fields are instantiated from the scrutinee: `Box _` on a Box Token
  -- discards the token.
  PCon c ps -> case conFields li c s of
    Just ss | length ss == length ps -> concat (zipWith (wildLinErrs li) ps ss)
    _ -> []
  _ -> []

bindPat :: LinInfo -> SPat -> LShape -> [(Name, LShape)]
bindPat li p s = case p of
  PVar x -> [(x, s)]
  PSig x _ -> [(x, s)] -- erased by erasePSig; PVar behavior if one survives
  PWild -> []
  PInt _ -> []
  PStr _ -> []
  PRec fs -> case s of
    LRecS fields _ -> [(f, fromMaybe LU (lookup f fields)) | f <- fs]
    _ -> [(f, LU) | f <- fs]
  PTup ps -> case s of
    LTupS ss | length ss == length ps -> concat (zipWith (bindPat li) ps ss)
    _ -> concatMap (\q -> bindPat li q LU) ps
  PCon c ps -> case conFields li c s of
    Just argShapes | length argShapes == length ps -> concat (zipWith (bindPat li) ps argShapes)
    _ -> concatMap (\q -> bindPat li q LU) ps

linExpr :: LinInfo -> M.Map Name LShape -> SExpr -> LRes
linExpr li env0 = go env0
  where
    zero = M.empty
    addC = M.unionWith (+)
    plus (Just a) (Just b) = Just (addC a b)
    plus _ _ = Nothing

    go :: M.Map Name LShape -> SExpr -> LRes
    go env = \case
      SMark offset e -> let (findings,count,shape)=go env e
                        in (map (atFinding (SourceOffset offset)) findings,count,shape)
      SVar v -> case M.lookup v env of
        Just s | isLin s -> ([], Just (M.singleton v 1), s)
        Just s -> ([], Just zero, s)
        Nothing -> ([], Just zero, globalShape v)
      SInt _ -> ([], Just zero, LU)
      SAtom _ -> ([], Just zero, LU)
      SStrI segs ->
        let rs = [go env e | SegExpr e <- segs]
         in (concat [e | (e, _, _) <- rs], foldl' plus (Just zero) [c | (_, c, _) <- rs], LU)
      e@SApp {} -> appSpine env e
      SBin "|>" a f -> go env (SApp f a)
      SBin "::" a b -> go env (SApp (SApp (SVar "Cons") a) b)
      SBin ">>" a b ->
        let (e1, c1, _) = go env a; (e2, c2, s2) = go env b
         in (e1 ++ e2, plus c1 c2, s2)
      SBin _ a b ->
        let (e1, c1, _) = go env a; (e2, c2, _) = go env b
         in (e1 ++ e2, plus c1 c2, LU)
      SProj e field ->
        let (er, c, sh) = go env e
            (errs, result) = projectOwnership field sh
         in (er ++ errs, c, result)
      SRec fs ->
        let rs = map (go env . snd) fs
            fields = zip (map fst fs) [s | (_, _, s) <- rs]
            repeated = M.filter (> (1 :: Int)) (M.fromListWith (+) [(f, 1) | (f, _) <- fields])
            errs = concat [demandOwnership s ("duplicate record field '" ++ f ++ "' discards or aliases an owned value") | f <- M.keys repeated, (n, s) <- fields, n == f]
         in (concat [e | (e, _, _) <- rs] ++ errs, foldl' plus (Just zero) [c | (_, c, _) <- rs], LRecS fields False)
      SUpd m as ->
        let base@(_, _, sh) = go env m
            updates = map (go env . snd) as
            rs = base : updates
            fields = zip (map fst as) [s | (_, _, s) <- updates]
            (errs, result) = foldl' (\(es, old) (path, new) -> let (more, next) = updateOwnership path new old in (es ++ more, next)) ([], sh) fields
         in (concat [e | (e, _, _) <- rs] ++ errs, foldl' plus (Just zero) [c | (_, c, _) <- rs], result)
      SList es ->
        let rs = map (go env) es
            sh = lcon "List" [foldl' joinLShape LU [s | (_, _, s) <- rs]]
         in (concat [e | (e, _, _) <- rs], foldl' plus (Just zero) [c | (_, c, _) <- rs], sh)
      STup es ->
        let rs = map (go env) es
         in (concat [e | (e, _, _) <- rs], foldl' plus (Just zero) [c | (_, c, _) <- rs], LTupS [s | (_, _, s) <- rs])
      SLam ps body ->
        -- a lambda may CAPTURE linear values: defining it consumes them
        -- (they live in the closure now), the body must use each
        -- exactly once, and the closure itself becomes LINEAR -- one
        -- application, enforced by the same counting as any LL value.
        -- (Runtime: the PAP carries the handle; the saturating apply
        -- hands it on.  A never-applied linear closure strands its
        -- handle -- consumed, not unsafe.)
        let env' = M.union (M.fromList [(p, LU) | p <- ps]) env
            (be, bc, _) = go env' body
            caps = [(v, s) | v <- sFree body, v `notElem` ps, Just s <- [M.lookup v env], isLin s]
            capErrs = case bc of
              Nothing -> []
              Just cc ->
                concat [ demandOwnership s ("lambda body uses linear capture '" ++ v ++ "' " ++ show k ++ " time(s), expected exactly 1")
                  | (v, s) <- caps, let k = M.findWithDefault 0 v cc, k /= 1 ]
            -- the closure owns what it captured: applying it twice is
            -- refused outright for a sure owner, and constrains the type
            -- variable for a possible one
            sh = closureShape (map snd caps)
         in (be ++ capErrs, bc, sh)
      SCase scrut arms ->
        let (se, sc, sshape) = go env scrut
            armRes = map (checkArm env sshape) arms
            errs = se ++ concat [e | (e, _, _) <- armRes]
            live = [(c, s) | (_, Just c, s) <- armRes]
            agree = case live of
              [] -> []
              ((c0, _) : rest) -> concat [demandOwnership (M.findWithDefault LU v env) ("case branches disagree on use of linear variable(s) " ++ show (disagreeing c0 c)) | (c, _) <- rest, v <- disagreeing c0 c]
            total = case live of
              [] -> Nothing
              ((c0, _) : _) -> plus sc (Just c0)
            shape = foldl' joinLShape LU (map snd live)
         in (errs ++ agree, total, shape)
      SBlock stmts final -> goBlock env stmts final

    -- a closure or partial application that holds an owner is itself
    -- single-use; say so, since nothing in its type is linear
    closureNote (LCon "fn" False _) = "; it is a closure or partial application holding a linear value, so it is single-use"
    closureNote _ = ""

    disagreeingM a b = M.filter id (M.intersectionWith (/=) a' b')
      where
        a' = M.unionWith (+) a (M.map (const 0) b)
        b' = M.unionWith (+) b (M.map (const 0) a)
    disagreeing a b = M.keys (disagreeingM a b)

    checkArm env sshape (p, body) =
      let binds = bindPat li p sshape
          env' = M.union (M.fromList binds) env
          (es, c, s) = go env' body
          linear = [v | (v, sh) <- binds, isLin sh]
          errs = case c of
            Nothing -> []
            Just cc -> concat [demandOwnership (fromMaybe LU (lookup v binds)) ("linear variable '" ++ v ++ "' bound in pattern used " ++ show (M.findWithDefault 0 v cc) ++ " time(s), expected 1") | v <- linear, M.findWithDefault 0 v cc /= 1]
          c' = fmap (\cc -> foldr M.delete cc (map fst binds)) c
       in (wildLinErrs li p sshape ++ es ++ errs, c', s)

    goBlock env [] final = go env final
    goBlock env (SBind n [] rhs : rest) final =
      let (e1, c1, sh) = go env rhs
          env' = M.insert n sh env
          (e2, c2, shf) = goBlock env' rest final
          errs = case c2 of
            Nothing -> []
            Just cc | isLin sh, M.findWithDefault 0 n cc /= 1 -> demandOwnership sh ("linear variable '" ++ n ++ "' used " ++ show (M.findWithDefault 0 n cc) ++ " time(s), expected exactly 1" ++ closureNote sh)
            _ -> []
          c2' = fmap (M.delete n) c2
       in (e1 ++ e2 ++ errs, plus c1 c2', shf)
    goBlock env (SBind n _ps rhs : rest) final =
      let caps = [(v, s) | v <- sFree rhs, Just s <- [M.lookup v env], isLin s]
          errs = concat [demandOwnership s ("local function '" ++ n ++ "' captures linear variable(s) " ++ show (map fst caps)) | (_, s) <- caps]
          (e2, c2, shf) = goBlock (M.insert n LU env) rest final
       in (errs ++ e2, c2, shf)
    goBlock env (SBindPat p rhs : rest) final =
      let (e1, c1, sh) = go env rhs
          e1w = e1 ++ wildLinErrs li p sh
          binds = bindPat li p sh
          env' = M.union (M.fromList binds) env
          (e2, c2, shf) = goBlock env' rest final
          linear = [v | (v, s) <- binds, isLin s]
          errs = case c2 of
            Nothing -> []
            Just cc -> concat [demandOwnership (fromMaybe LU (lookup v binds)) ("linear variable '" ++ v ++ "' used " ++ show (M.findWithDefault 0 v cc) ++ " time(s), expected exactly 1") | v <- linear, M.findWithDefault 0 v cc /= 1]
          c2' = fmap (\cc -> foldr M.delete cc (map fst binds)) c2
       in (e1w ++ e2 ++ errs, plus c1 c2', shf)

    appSpine env e =
      let (h, args) = flatten e []
          argRes = map (go env) args
          argErrs = concat [er | (er, _, _) <- argRes]
          argCnt = foldl' plus (Just zero) [c | (_, c, _) <- argRes]
          anyLinArg = any (\(_, _, s) -> isLin s) argRes
          heldShape = closureShape [s | (_, _, s) <- argRes]
          -- the callee's own owner, when its body returns a single-use
          -- closure (heldVar among its obligations)
          selfHeld g = isNothing (M.lookup g env) && heldVar `elem` M.findWithDefault [] g (liUnres li)
       in case h of
            SVar "error" | Nothing <- M.lookup "error" env -> (argErrs, Nothing, LU)
            SVar g ->
              -- a PARTIAL application over linear argument(s) is a
              -- linear PAP: the args are consumed into it (argCnt
              -- already counts them once) and the PAP itself must be
              -- applied exactly once.  A saturated call instantiates the
              -- callee's type variables from the arguments: the result
              -- carries the ownership that went in, and a variable the
              -- callee duplicates or discards may not receive an owner.
              -- Local callbacks shadow globals, just as they do during
              -- inference and execution. A global with the same spelling
              -- cannot supply this callback's result shape or constraints.
              -- A local callable whose arity is known (a function-typed
              -- parameter, a function name or field bound locally) that
              -- receives fewer arguments is a partial application: over
              -- an owner it holds that owner and is single-use.
              let (sh, full, callErrs) = case M.lookup g env of
                    Just local -> (LU, maybe True (length args >=) (callableArity local), [])
                    Nothing -> headShape g [s | (_, _, s) <- argRes]
                  self = selfHeld g
                  sh2 = if (anyLinArg || self) && not full then closureShape ([s | (_, _, s) <- argRes] ++ [LL | self]) else sh
                  (he, hc, _) = go env (SVar g)
               in (argErrs ++ callErrs ++ he, plus hc argCnt, sh2)
            _ ->
              -- an expression head (a case choosing a function, an
              -- application returning one, a lambda): when its arity is
              -- unknown, whatever owners the arguments hand it may be held
              -- by the result, which is then single-use
              let (he, hc, hs) = go env h
                  arity = case h of
                    SLam ps _ -> Just (length ps)
                    _ -> callableArity hs
                  partial = maybe True (length args <) arity
               in (argErrs ++ he, plus hc argCnt, if anyLinArg && partial then heldShape else LU)
      where
        flatten (SApp f a) acc = flatten f (a : acc)
        flatten (SMark _ f) acc@(_ : _) = flatten f acc
        flatten f acc = (f, acc)

    headShape g argShapes
      | Just (retSh, fields) <- M.lookup g (liConSh li),
        Just ar <- M.lookup g (liConAr li) =
          (if nargs == ar then substL (bindingsL fields argShapes) LU retSh else LU, nargs >= ar, stored)
      | Just (ps, r) <- M.lookup g (liSigs li) =
          let b = bindingsL ps argShapes
              required = M.findWithDefault [] g (liUnres li)
              violated = concat [demandOwnership s (unresMessage v) | v <- required, v /= heldVar, isNothing (heldOfVar v), Just s <- [M.lookup v b]]
              -- a module's definition is spelled `name@hash` here
              shown = takeWhile (/= '@') g
              unresMessage v
                | Just (i, _) <- fnVarInfo v = "'" ++ shown ++ "' may call " ++ (if fnVarNested v then "a function inside its argument #" else "its function argument #") ++ show (1 + i)
                    ++ " more than once (or never), so it cannot take a single-use closure there (a lambda or partial application that captured a linear value)"
                | otherwise = "'" ++ shown ++ "' duplicates or discards its argument of type `" ++ v ++ "`, so it cannot take an owned value there"
              total = length ps + fnResultArity r
              -- what the result's nested function positions hold: what
              -- the body showed it keeps there (an owner of its own, or
              -- the arguments for those symbolic owners)
              owners = [LL | heldVar `elem` required] ++ [s | r0 <- required, Just v <- [heldOfVar r0], Just s <- [M.lookup v b], isLin s]
              -- one symbolic owner is the value itself (a callable passed
              -- through): kept as it is, so it joins with the arm that
              -- returns it directly
              heldShape' = case owners of
                [o] | not (hardLin o) -> o
                _ -> closureShape owners
              b' = M.insert heldVar heldShape' b
           in (if nargs == length ps then substL b' LU r else LU, nargs >= total, violated)
      | otherwise = (LU, True, [])
      where
        nargs = length argShapes
        -- a single-use closure in a function-typed field is lost to the
        -- constructed value's type: refused (constrains a callable
        -- parameter of the enclosing function instead, when symbolic)
        stored = case M.lookup g (liConFnFields li) of
          -- each function-typed position on its own: joining two
          -- unrestricted callables of different arity is not an owner
          Just templates
            | held@(_ : _) <- [a | (v, a) <- concat (zipWith matchL templates argShapes), v == fieldVar, isLin a] ->
                concatMap (`demandOwnership` storedMessage) held
          _ -> []
        storedMessage = "constructor '" ++ g' ++ "' cannot store a single-use closure (a lambda or partial application that captured a linear value) in a function-typed field: the field's type cannot say it is single-use; pass the owner as its own field instead"
          -- (the constructor's spelling without its module hash)
          where g' = takeWhile (/= '@') g
    globalShape v
      | Just (ps, _) <- M.lookup v (liSigs li), null ps, heldVar `elem` M.findWithDefault [] v (liUnres li) = closureShape [LL]
      | Just (ps, r) <- M.lookup v (liSigs li), null ps = eraseVars r
      | Just (ps, r) <- M.lookup v (liSigs li) = fnResultShape (length ps + fnResultArity r)
      | Just (r, as) <- M.lookup v (liConSh li), null as = eraseVars r
      | otherwise = LU
