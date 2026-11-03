{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
-- Whole-program representation inference and budgeted type/representation
-- specialization (C2) for the standalone ARC and raw builtin ABIs.
--
-- When type specialization is enabled (default; `FPR_NO_TYPE_SPEC=1` rolls back
-- to strict monomorphic unification):
--   1. Each connected data-type instance (`Data tid inst`) tracks its own field
--      representations so distinct instantiations of a polymorphic container or
--      pair (e.g. `List Int` vs `List Word`, or `List IPair` vs `List WPair`)
--      do not collide on a single global `(tid, variant, field)` slot, while
--      values that meet through a shared binding, branch or `==` still unify
--      their instances and reject incompatible element kinds.
--   2. Non-exported polymorphic functions called with distinct argument
--      representations are cloned per representation signature within a
--      bounded Core node budget (`typeSpecBudget`), with budget declines
--      reported for `--remarks`.
module Representation
  ( represent,
    representWith,
    representWithOptions,
    typeSpecBudget,
    Kind (..),
    primitiveShape,
  ) where

import Control.Monad (forM_, mapAndUnzipM, replicateM_, unless, when, zipWithM_)
import Control.Monad.State.Strict
import Core.Syntax (Core (..), Name, Prog)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Representation.Types

typeSpecBudget :: Int
typeSpecBudget = 4096

data Ty
  = Var Int
  | Scalar Kind
  | Text
  | Data Int Int
  deriving (Eq, Show)

data St = St
  { next :: Int,
    subs :: M.Map Int Ty,
    dataSubs :: M.Map Int Int,
    marks :: M.Map Core Ty,
    fields :: M.Map (Int, Int, Int, Int) Ty,
    projections :: [(Ty, Int, Ty)],
    progDefs :: Prog,
    sigs :: M.Map Name ([Ty], Ty),
    primaryKeys :: M.Map Name [String],
    cloneMap :: M.Map (Name, [String]) Name,
    inferredFns :: S.Set Name,
    activeFns :: S.Set Name,
    clonedNodes :: Int,
    declined :: [(Name, String)]
  }

type G = StateT St (Either String)

freshId :: G Int
freshId = do
  s <- get
  put s {next = next s + 1}
  pure (next s)

fresh :: G Ty
fresh = Var <$> freshId

freshData :: Bool -> Int -> G Ty
freshData False tid = pure (Data tid 0)
freshData True tid = Data tid <$> freshId

err :: String -> G a
err = lift . Left . ("automatic ARC: " ++)

resolveData :: Int -> G Int
resolveData i =
  gets (M.lookup i . dataSubs) >>= maybe (pure i) resolveData

dataInstance :: Ty -> G Int
dataInstance (Data _ i) = resolveData i
dataInstance _ = pure 0

resolve :: Ty -> G Ty
resolve (Var n) = gets (M.lookup n . subs) >>= maybe (pure (Var n)) resolve
resolve (Data tid i) = Data tid <$> resolveData i
resolve t = pure t

prettyTy :: Ty -> String
prettyTy = \case
  Var n -> "Var " ++ show n
  Scalar k -> "Scalar " ++ show k
  Text -> "Text"
  Data tid _ -> "Data " ++ show tid

unify :: Ty -> Ty -> G ()
unify a b = do
  x <- resolve a
  y <- resolve b
  case (x, y) of
    _ | x == y -> pure ()
    -- Strings and tagged/managed values share the same one-word ARC
    -- representation. Result Ok/Err projections may meet both variants;
    -- the source type checker already enforces their semantic types.
    (Text, Scalar Managed) -> pure ()
    (Scalar Managed, Text) -> pure ()
    (Data t1 i1, Data t2 i2)
      | t1 == t2 -> do
          modify (\s -> s {dataSubs = M.insert i1 i2 (dataSubs s)})
          fs <- gets fields
          let pairs = [((v, k), ty) | ((t, i, v, k), ty) <- M.toList fs, t == t1, i == i1]
          forM_ pairs $ \((v, k), ty1) -> do
            ty2 <- field (t1, i2, v, k)
            unify ty1 ty2
    (Var n, t) -> modify (\s -> s {subs = M.insert n t (subs s)})
    (t, Var n) -> modify (\s -> s {subs = M.insert n t (subs s)})
    _ ->
      err
        ( "incompatible representations "
            ++ prettyTy x
            ++ " and "
            ++ prettyTy y
            ++ "; specialize the function or data type for each representation"
        )

kind :: Ty -> G Kind
kind t =
  resolve t >>= \x -> pure $ case x of
    Scalar k -> k
    _ -> Managed

field :: (Int, Int, Int, Int) -> G Ty
field (tid, inst0, v, k) = do
  inst <- resolveData inst0
  let key = (tid, inst, v, k)
  m <- gets fields
  case M.lookup key m of
    Just t -> pure t
    Nothing -> do
      t <- fresh
      modify (\s -> s {fields = M.insert key t (fields s)})
      pure t

-- Repeated AnyValue slots share one fresh type per application. Primitive
-- signatures use the same representation constructors as checked interfaces.
primitiveShape :: String -> Maybe PrimitiveShape
primitiveShape n = M.lookup n shapes
  where
    t = KnownValue (ScalarRep Managed)
    w = KnownValue (ScalarRep RawWord)
    a = KnownValue (ScalarRep RawAddr)
    d = KnownValue (ScalarRep RawF64)
    f = KnownValue (ScalarRep RawF32)
    s = KnownValue TextRep
    b = KnownValue (DataRep 1)
    u = KnownValue (DataRep 0)
    r = KnownValue (DataRep 3)
    sh = PrimitiveShape
    shapes =
      M.fromList $
        [(x, sh [t, t] t) | x <- ["+", "-", "*", "/"]]
          ++ [(x, sh [t, t] b) | x <- ["<", ">", "<=", ">="]]
          ++ [ ("==", sh [AnyValue, AnyValue] b),
               ("!=", sh [AnyValue, AnyValue] b),
               ("str", sh [AnyValue] s),
               ("print", sh [AnyValue] u),
               ("strcat", sh [s, s] s),
               ("String.len", sh [s] t),
               ("error", sh [s] AnyValue),
               ("intMax", sh [u] t),
               ("intMin", sh [u] t)
             ]
          ++ [ ("Word." ++ x, sh ps result)
               | (x, ps, result) <-
                   [ ("fromInt", [t], w),
                     ("toInt", [w], t),
                     ("bits", [u], t),
                     ("and", [w, w], w),
                     ("or", [w, w], w),
                     ("xor", [w, w], w),
                     ("add", [w, w], w),
                     ("sub", [w, w], w),
                     ("not", [w], w),
                     ("shl", [w, t], w),
                     ("shr", [w, t], w),
                     ("mask", [t, t], w),
                     ("eq", [w, w], b),
                     ("bitSet", [w, t], w),
                     ("bitClear", [w, t], w),
                     ("bitTest", [w, t], b)
                   ]
             ]
          ++ [ ("Addr." ++ x, sh ps result)
               | (x, ps, result) <-
                   [ ("fromWord", [w], a),
                     ("toWord", [a], w),
                     ("add", [a, t], a),
                     ("null", [u], a),
                     ("eq", [a, a], b)
                   ]
             ]
          ++ [ ("Mem." ++ x, sh ps result)
               | (x, ps, result) <-
                   [ ("read8", [a], t),
                     ("read16", [a], t),
                     ("read32", [a], w),
                     ("readWord", [a], w),
                     ("write8", [a, t], u),
                     ("write16", [a, t], u),
                     ("write32", [a, w], u),
                     ("writeWord", [a, w], u),
                     ("atomicExchange", [a, w], w),
                     ("compareExchange", [a, w, w], w),
                     ("alloc", [t], a),
                     ("realloc", [a, t], a),
                     ("free", [a], u),
                     ("fence", [u], u),
                     ("liveAllocations", [u], t)
                   ]
             ]
          ++ [ ("CPU." ++ x, sh ps result)
               | (x, ps, result) <-
                   [ ("csrRead", [t], w),
                     ("csrWrite", [t, w], u),
                     ("irqSave", [u], t),
                     ("irqRestore", [t], u),
                     ("irqEnable", [u], u),
                     ("wait", [u], u),
                     ("instructionFence", [u], u)
                   ]
             ]
          ++ [ ("f64frombits", sh [t, t] d),
               ("f32frombits", sh [t] f),
               ("F64.ofF32", sh [f] d),
               ("F32.ofF64", sh [d] f)
             ]
          ++ concat
            [ [(p ++ x, sh [k, k] k) | x <- ["+", "-", "*", "/", "pow"]]
                ++ [(p ++ x, sh [k, k] b) | x <- ["<", ">", "<=", ">=", "==", "!="]]
                ++ [(p ++ x, sh [k] k) | x <- ["sqrt", "log", "log2", "exp", "sin", "cos"]]
                ++ [(p ++ "ofInt", sh [t] k), (p ++ "toInt", sh [k] t), (p ++ "str", sh [k] s)]
              | (p, k) <- [("F64.", d), ("F32.", f)]
            ]
          ++ [ ("I32." ++ x, sh [t, t] t)
               | x <-
                   [ "+",
                     "-",
                     "*",
                     "/",
                     "rem",
                     "divU",
                     "remU",
                     "and",
                     "or",
                     "xor",
                     "shl",
                     "shr",
                     "sar",
                     "rotl",
                     "rotr"
                   ]
             ]
          ++ [("I32." ++ x, sh [t, t] b) | x <- ["<", ">", "<=", ">=", "==", "!=", "ltU", "gtU", "leU", "geU"]]
          ++ [("I32." ++ x, sh [t] t) | x <- ["not", "neg", "clz", "ctz", "popcnt", "ofInt"]]
          ++ [("I32." ++ x, sh [t] s) | x <- ["str", "strU", "hex"]]
          ++ [("I32.toInt", sh [t] r), ("I32.toIntU", sh [t] r), ("I32.parse", sh [s] r)]

repType :: Bool -> Rep -> G Ty
repType typeSpec = \case
  ScalarRep k -> pure (Scalar k)
  TextRep -> pure Text
  DataRep tid -> freshData typeSpec tid

coreSize :: Core -> Int
coreSize = \case
  CApp a b -> 1 + coreSize a + coreSize b
  CLet _ a b -> 1 + coreSize a + coreSize b
  CIf a b c -> 1 + coreSize a + coreSize b + coreSize c
  CMk _ _ fs -> 1 + sum (map coreSize fs)
  CTagEq _ _ x -> 1 + coreSize x
  CProj _ x -> 1 + coreSize x
  CLam _ b -> 1 + coreSize b
  _ -> 1

represent :: Prog -> Either String (Prog, M.Map Core Kind, M.Map String [Kind])
represent = representWith M.empty

representWith :: M.Map String CallSignature -> Prog -> Either String (Prog, M.Map Core Kind, M.Map String [Kind])
representWith declarations input = do
  (p, ann, args, _) <- representWithOptions False S.empty declarations input
  pure (p, ann, args)

representWithOptions ::
  Bool ->
  S.Set String ->
  M.Map String CallSignature ->
  Prog ->
  Either String (Prog, M.Map Core Kind, M.Map String [Kind], [(String, String)])
representWithOptions typeSpec pinned declarations input =
  evalStateT work (St 0 M.empty M.empty M.empty M.empty [] M.empty M.empty M.empty M.empty S.empty S.empty 0 [])
  where
    -- A checked declaration fixes a *parameter's* representation; the call
    -- sites then agree and the uniform entry serves them, so no clone is
    -- needed. The result representation never blocks cloning: a function whose
    -- parameters are representation-unknown is called at more than one
    -- representation, and that is exactly what a clone is for.
    hasConcreteDecl n = case M.lookup n declarations of
      Just (CallSignature ps _) -> not (null ps) && all (/= Nothing) ps
      Nothing -> False
    canClone n =
      typeSpec
        && S.notMember n pinned
        && not (hasConcreteDecl n)
        && case M.lookup n input of
          Just (ps, b) -> not (null ps) && coreSize b <= 256
          Nothing -> False

    work = do
      prog0 <- M.traverseWithKey (\_ (ps, b) -> do
        ns <- mapM (const freshName) ps
        b' <- rename (M.fromList (zip ps ns)) b
        pure (ns, b')) input
      sig0 <- traverse (\(ps, _) -> do
        as <- mapM (const fresh) ps
        r <- fresh
        pure (as, r)) prog0
      modify (\s -> s {progDefs = prog0, sigs = sig0})

      forM_ (M.toList declarations) $ \(n, CallSignature params result) -> do
        sMap <- gets sigs
        case M.lookup n sMap of
          Nothing -> err ("checked representation declaration has no function: " ++ n)
          Just (as, r) -> do
            unless (length as == length params) (err ("checked representation declaration changed physical arity: " ++ n))
            zipWithM_ (\a known -> maybe (pure ()) (\rep -> repType typeSpec rep >>= unify a) known) as params
            maybe (pure ()) (\rep -> repType typeSpec rep >>= unify r) result

      sMap0 <- gets sigs
      case M.lookup "machineInterrupt" sMap0 of
        Nothing -> pure ()
        Just (as, result) -> do
          unless (length as == 3) $ err "machineInterrupt requires cause, pc and trap-value Word arguments"
          mapM_ (`unify` Scalar RawWord) as
          d0 <- freshData typeSpec 0
          unify result d0

      -- Infer roots first so call-site argument representations flow top-down
      -- into polymorphic helpers; then infer any remaining unreached functions.
      let rootNames =
            [n | n <- ["main", "machineInterrupt"], M.member n prog0]
              ++ [n | n <- S.toList pinned, M.member n prog0]
              ++ [n | n <- M.keys prog0, hasConcreteDecl n]
      mapM_ inferFunction rootNames
      remaining <- gets (M.keys . progDefs)
      mapM_ inferFunction remaining

      -- Projections may also acquire a data type through another projection.
      ps <- gets projections
      replicateM_ (length ps + 1) $ forM_ ps $ \(obj, i, result) -> do
        t <- resolve obj
        case t of
          Data tid inst -> do
            inst' <- resolveData inst
            fs <- gets fields
            let candidates = [v | ((t', i', _, i''), v) <- M.toList fs, t' == tid, i' == inst', i'' == i]
            mapM_ (unify result) candidates
          Var _ -> pure ()
          _ -> err "projection from a non-algebraic representation"
      forM_ ps $ \(obj, _, _) ->
        resolve obj >>= \t -> case t of
          Var _ -> err "cannot determine projected data layout; use a concrete data type"
          _ -> pure ()

      finalProg <- gets progDefs
      finalSigs <- gets sigs
      ann <- gets marks >>= traverse kind
      args <- traverse (mapM kind . fst) finalSigs
      decls <- gets (reverse . declined)
      pure (finalProg, ann, args, decls)

    freshName = do
      n <- freshId
      pure ("$rep." ++ show n)

    rename env = \case
      CVar n -> pure (CVar (M.findWithDefault n n env))
      CLet n a b -> do
        a' <- rename env a
        n' <- freshName
        b' <- rename (M.insert n n' env) b
        pure (CLet n' a' b')
      CApp f x -> CApp <$> rename env f <*> rename env x
      CIf c t f -> CIf <$> rename env c <*> rename env t <*> rename env f
      CMk t v fs -> CMk t v <$> mapM (rename env) fs
      CProj i x -> CProj i <$> rename env x
      CTagEq t v x -> CTagEq t v <$> rename env x
      CLam {} -> err "lambda survived lifting"
      e -> pure e

    inferFunction n = do
      done <- gets (S.member n . inferredFns)
      active <- gets (S.member n . activeFns)
      unless (done || active) $ do
        pMap <- gets progDefs
        sMap <- gets sigs
        case (M.lookup n pMap, M.lookup n sMap) of
          (Just (ps, b), Just (as, r)) -> do
            modify (\s -> s {activeFns = S.insert n (activeFns s)})
            (b', t) <- infer (M.fromList (zip ps as)) b
            unify r t
            modify
              ( \s ->
                  s
                    { progDefs = M.insert n (ps, b') (progDefs s),
                      inferredFns = S.insert n (inferredFns s),
                      activeFns = S.delete n (activeFns s)
                    }
              )
          _ -> pure ()

    repKey seen t = do
      r <- resolve t
      case r of
        Scalar k -> pure [kindTag k]
        Text -> pure "s"
        Var _ -> pure "t"
        Data tid inst -> do
          inst' <- resolveData inst
          if S.member inst' seen
            then pure ("D" ++ show tid)
            else do
              fs <- gets fields
              let entries =
                    [ (v, k, ty)
                      | ((t', i', v, k), ty) <- M.toList fs,
                        t' == tid,
                        i' == inst'
                    ]
              sub <-
                mapM
                  (\(v, k, ty) -> do
                    rk <- repKey (S.insert inst' seen) ty
                    pure (show v ++ ":" ++ show k ++ ":" ++ rk))
                  entries
              pure ("D" ++ show tid ++ "[" ++ intercalate "," sub ++ "]")

    infer env e = do
      (e', t) <- case e of
        CInt _ -> pure (e, Scalar Managed)
        CStr _ -> pure (e, Text)
        CVar n -> case M.lookup n env of
          Just t -> pure (e, t)
          Nothing -> do
            pMap <- gets progDefs
            case M.lookup n pMap of
              -- Every occurrence of a nullary constructor allocates its own
              -- instance: a `Nil` shared across two containers of one nominal
              -- type would otherwise make `List Int` and `List Word` meet and
              -- merge, which is exactly the case C2 must keep apart.
              Just ([], CMk tid _ []) -> do
                d <- freshData typeSpec tid
                pure (e, d)
              _ -> do
                (target, r) <- apply n [] []
                pure (CVar target, r)
        CLet n a b -> do
          (a', t) <- infer env a
          (b', tb) <- infer (M.insert n t env) b
          pure (CLet n a' b', tb)
        CIf c a b -> do
          (c', tc) <- infer env c
          d1 <- freshData typeSpec 1
          unify tc d1
          (a', ta) <- infer env a
          (b', tb) <- infer env b
          unify ta tb
          pure (CIf c' a' b', ta)
        CMk tid v fs -> do
          (fs', ftys) <- mapAndUnzipM (infer env) fs
          d <- freshData typeSpec tid
          inst <- dataInstance d
          forM_ (zip [0 ..] ftys) $ \(i, fty) -> do
            b <- field (tid, inst, v, i)
            unify fty b
          pure (CMk tid v fs', d)
        CTagEq tid v x -> do
          (x', t) <- infer env x
          d <- freshData typeSpec tid
          unify t d
          d1 <- freshData typeSpec 1
          pure (CTagEq tid v x', d1)
        CProj i x -> do
          (x', a) <- infer env x
          b <- fresh
          ra <- resolve a
          case ra of
            Data tid inst -> do
              inst' <- resolveData inst
              fs <- gets fields
              let candidates = [v | ((t', i', _, i''), v) <- M.toList fs, t' == tid, i' == inst', i'' == i]
              mapM_ (unify b) candidates
            _ -> pure ()
          modify (\s -> s {projections = (a, i, b) : projections s})
          pure (CProj i x', b)
        CApp {} ->
          let (f, as) = spine e
           in case f of
                CVar n | M.notMember n env -> do
                  (as', actualTys) <- mapAndUnzipM (infer env) as
                  (target, r) <- apply n as' actualTys
                  pure (foldl CApp (CVar target) as', r)
                _ -> err "indirect calls and partial applications are not supported yet"
        CErr _ -> (\t -> (e, t)) <$> fresh
        CLam {} -> err "lambda survived lifting"
      modify (\s -> s {marks = M.insert e' t (marks s)})
      pure (e', t)

    apply n actualExprs actual = do
      sMap <- gets sigs
      case M.lookup n sMap of
        Just (expected, result) -> do
          unless (length actual == length expected) $
            err ("partial/over-application of " ++ n ++ " is not supported yet")
          if not (canClone n) || null actualExprs
            then do
              zipWithM_ unify actual expected
              inferFunction n
              pure (n, result)
            else do
              key <- mapM (repKey S.empty) actual
              pKeys <- gets primaryKeys
              cMap <- gets cloneMap
              case M.lookup n pKeys of
                Nothing -> do
                  modify
                    ( \s ->
                        s
                          { primaryKeys = M.insert n key (primaryKeys s),
                            cloneMap = M.insert (n, key) n (cloneMap s)
                          }
                    )
                  zipWithM_ unify actual expected
                  inferFunction n
                  pure (n, result)
                Just key0
                  | key == key0 -> do
                      zipWithM_ unify actual expected
                      inferFunction n
                      pure (n, result)
                  | Just target <- M.lookup (n, key) cMap -> do
                      sMap' <- gets sigs
                      let (expT, resT) = sMap' M.! target
                      zipWithM_ unify actual expT
                      inferFunction target
                      pure (target, resT)
                  | otherwise -> instantiateClone n key actual (expected, result)
        Nothing | "$sym." `isPrefixOf` n -> do
          unless (null actual) $ err ("partial/over-application of " ++ n ++ " is not supported yet")
          pure (n, Scalar RawAddr)
        Nothing -> case primitiveShape n of
          Nothing -> err ("unsupported primitive or function value: " ++ n)
          Just (PrimitiveShape params result) -> do
            unless (length actual == length params) $
              err ("partial/over-application of " ++ n ++ " is not supported yet")
            anyT <- fresh
            let ty AnyValue = pure anyT
                ty (KnownValue rep) = repType typeSpec rep
            expected <- mapM ty params
            resT <- ty result
            zipWithM_ unify actual expected
            pure (n, resT)

    instantiateClone n key actual (expected0, result0) = do
      let (psOrig, bodyOrig) = input M.! n
          cost = coreSize bodyOrig
      used <- gets clonedNodes
      if used + cost > typeSpecBudget
        then do
          modify (\s -> s {declined = (n, "type specialization budget exceeded (" ++ show (used + cost) ++ " > " ++ show typeSpecBudget ++ " nodes)") : declined s})
          zipWithM_ unify actual expected0
          inferFunction n
          pure (n, result0)
        else do
          pMap <- gets progDefs
          let stem = n ++ "$typespec$" ++ intercalate "_" key
              target =
                if M.notMember stem pMap
                  then stem
                  else head [c | k <- [1 :: Int ..], let c = stem ++ "$" ++ show k, M.notMember c pMap]
          ns <- mapM (const freshName) psOrig
          b' <- rename (M.insert n target (M.fromList (zip psOrig ns))) bodyOrig
          asT <- mapM (const fresh) ns
          rT <- fresh
          modify
            ( \s ->
                s
                  { progDefs = M.insert target (ns, b') (progDefs s),
                    sigs = M.insert target (asT, rT) (sigs s),
                    cloneMap = M.insert (n, key) target (cloneMap s),
                    clonedNodes = used + cost
                  }
            )
          zipWithM_ unify actual asT
          inferFunction target
          pure (target, rT)

    spine = go []
      where
        go as (CApp f x) = go (x : as) f
        go as f = (f, as)
