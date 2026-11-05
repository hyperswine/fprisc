{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
-- Whole-program representation inference and finite type/representation
-- specialization (C2) for the standalone ARC and raw builtin ABIs.
--
-- Type specialization is enabled by default. `FPR_NO_TYPE_SPEC=1` disables
-- cloning while preserving checked generic slots and their conversion ABI:
--   1. Each connected data-type instance (`Data tid inst`) tracks its own field
--      representations so distinct instantiations of a polymorphic container or
--      pair (e.g. `List Int` vs `List Word`, or `List IPair` vs `List WPair`)
--      do not collide on a single global `(tid, variant, field)` slot, while
--      values that meet through a shared binding, branch or `==` still unify
--      their instances and reject incompatible element kinds.
--   2. Non-exported polymorphic functions called with distinct argument
--      representations are cloned per representation signature. Expanding
--      polymorphic recursion is refused, rather than hidden behind an arbitrary
--      Core-size cap or an invalid "uniform" fallback. Checked generic graphs
--      use the typed pass's tagged fallback instead. Actual image admission
--      belongs to the selected target linker; hosted compiler cost is gated
--      by the compile-budget suite.
module Representation
  ( represent,
    representWith,
    representWithOptions,
    representWithOwnership,
    representWithCheckedLayouts,
    representWithStorage,
    representWithEvidence,
    representWithProductEvidence,
    RepresentationResult,
    Kind (..),
    primitiveShape,
  ) where

import Control.Monad (foldM, forM, forM_, mapAndUnzipM, replicateM_, unless, when, zipWithM_)
import Control.Monad.State.Strict
import Core.Syntax (Core (..), Name, Prog)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Arc.Uniform as UniformBoundary
import Representation.Types

data Ty
  = Var Int
  | Scalar Kind
  | Uniform
  | Text
  | Data Int Int
  deriving (Eq, Show)

data Storage = BoxedStorage | ScalarStorage Int deriving (Eq,Show)

-- A finite snapshot of an argument's representation graph. Labels come from
-- the finite source program (nominal types, constructor slots and scalar
-- kinds); back edges are nominal leaves, never inference-variable identities.
-- Homeomorphic embedding detects growing recursive instantiations without
-- imposing a code-size, clone-count or recursion-depth constant.
data RepTree = RepTree String [RepTree] deriving (Eq, Show)

embeds :: RepTree -> RepTree -> Bool
embeds a@(RepTree label xs) (RepTree label' ys) =
  (label == label' && length xs == length ys && and (zipWith embeds xs ys))
    || any (embeds a) ys

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
    activeInstances :: [(Name, Name, [RepTree])],
    declined :: [(Name, String)],
    checkedLayouts :: LayoutTable,
    layoutInstances :: M.Map String Ty,
    conversions :: M.Map String (Ty,Ty),
    storageChoices :: M.Map Int Storage
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
  Uniform -> "Uniform"
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
          choices<-gets storageChoices
          let a=M.lookup i1 choices;b=M.lookup i2 choices
          case (a,b) of
            (Just x,Just y) | x/=y->err "incompatible checked storage representations"
            _->pure ()
          let chosen=case b of Just _->b;_->a
          modify (\s -> s {dataSubs = M.insert i1 i2 (dataSubs s),
            storageChoices=maybe (storageChoices s) (\choice->M.insert i2 choice (storageChoices s)) chosen})
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
kind t = resolve t >>= \x->case x of
  Scalar k->pure k
  Data tid inst->do
    choice<-gets (M.lookup inst . storageChoices)
    case choice of
      Just (ScalarStorage variant)->field (tid,inst,variant,0) >>= kind
      _->pure Managed
  _->pure Managed

scalarInfo :: Ty -> G (Maybe (Int,Int))
scalarInfo t=resolve t >>= \x->case x of
  Data tid inst->do
    choice<-gets (M.lookup inst . storageChoices)
    pure (case choice of Just (ScalarStorage variant)->Just (tid,variant);_->Nothing)
  _->pure Nothing

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
    tagged = KnownValue UniformRep
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
          ++ [ ("$trmc.setTail", sh [AnyValue, AnyValue] u),
               ("==", sh [AnyValue, AnyValue] b),
               ("!=", sh [AnyValue, AnyValue] b),
               ("str", sh [AnyValue] s),
               ("print", sh [AnyValue] u),
               ("strcat", sh [s, s] s),
               ("String.len", sh [s] t),
               ("error", sh [s] AnyValue),
               ("intMax", sh [u] t),
               ("intMin", sh [u] t)
             ]
          ++ [("$uniform.boxAggregate",sh [AnyValue,s,KnownValue (DataRep 0x1fff0001)] tagged),
              ("$uniform.unboxAggregate",sh [tagged,s,KnownValue (DataRep 0x1fff0001)] AnyValue),
              ("$uniform.boxManaged",sh [AnyValue] tagged),
              ("$uniform.unboxManaged",sh [tagged] AnyValue),
              ("$uniform.unboxTagged",sh [tagged] t),
              ("$uniform.unboxText",sh [tagged] s),
              ("$uniform.unboxData",sh [tagged,t] AnyValue),
              ("$uniform.project",sh [tagged,t] tagged),
              ("$uniform.tagEq",sh [tagged,t,t] b)]
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
          ++ [("$uniform."++direction++name,shape)
              | (name,rep)<-[("Word",w),("Addr",a),("F64",d),("F32",f)],
                (direction,shape)<-[("box",sh [rep] tagged),("unbox",sh [tagged] rep)]]

repType :: Bool -> Rep -> G Ty
repType typeSpec = \case
  UniformRep -> pure Uniform
  ScalarRep k -> pure (Scalar k)
  TextRep -> pure Text
  DataRep tid -> freshData typeSpec tid
  LayoutRep key -> do
    existing <- gets (M.lookup key . layoutInstances)
    case existing of
      Just ty -> resolve ty
      Nothing -> do
        table <- gets checkedLayouts
        case M.lookup key table of
          Nothing -> err ("missing checked layout " ++ key)
          Just def -> do
            let (tid,variants)=layoutParts def
            ty <- freshData typeSpec tid
            inst <- dataInstance ty
            modify (\s -> s {layoutInstances = M.insert key ty (layoutInstances s),
              storageChoices=M.insert inst (maybe BoxedStorage (ScalarStorage . fst) (scalarLayout def)) (storageChoices s)})
            forM_ (M.toList variants) $ \(v, fs) ->
              forM_ (zip [0..] fs) $ \(i, known) -> do
                f <- field (tid, inst, v, i)
                maybe (pure ()) (\rep -> repType typeSpec rep >>= unify f) known
            pure ty

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
  do
    (p, ann, args, _, _, notes) <- representWithOwnership typeSpec pinned declarations input
    pure (p, ann, args, notes)

-- Ownership is separate from the one-word calling representation: Bool and
-- Unit use the managed/tagged ABI but are immortal. In particular, Scalar
-- Managed is not an immortality proof (it can also represent heap strings).
representWithOwnership :: Bool -> S.Set String -> M.Map String CallSignature -> Prog ->
  Either String (Prog, M.Map Core Kind, M.Map String [Kind], S.Set Core, M.Map String [Bool], [(String, String)])
representWithOwnership = representWithCheckedLayouts M.empty

representWithCheckedLayouts :: LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> Prog ->
  Either String (Prog, M.Map Core Kind, M.Map String [Kind], S.Set Core, M.Map String [Bool], [(String, String)])
representWithCheckedLayouts layouts typeSpec pinned declarations input =
  do (p,ann,args,immortals,immortalArgs,_,notes)<-representWithStorage layouts typeSpec pinned declarations input
     pure (p,ann,args,immortals,immortalArgs,notes)

representWithStorage :: LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> Prog ->
  Either String (Prog, M.Map Core Kind, M.Map String [Kind], S.Set Core, M.Map String [Bool], M.Map Core (Int,Int), [(String,String)])
representWithStorage=representWithEvidence M.empty

representWithEvidence :: M.Map String Rep -> LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> Prog ->
  Either String (Prog, M.Map Core Kind, M.Map String [Kind], S.Set Core, M.Map String [Bool], M.Map Core (Int,Int), [(String,String)])
representWithEvidence evidence layouts typeSpec pinned declarations input =
  fst <$> representWithProductEvidence 0 evidence layouts typeSpec pinned declarations input

type RepresentationResult = (Prog, M.Map Core Kind, M.Map String [Kind], S.Set Core, M.Map String [Bool], M.Map Core (Int,Int), [(String,String)])

representWithProductEvidence :: Int -> M.Map String Rep -> LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> Prog ->
  Either String (RepresentationResult, ProductEvidence)
representWithProductEvidence capacity evidence layouts typeSpec pinned declarations input = do
  mapM_ (layoutKind layouts) (M.keys layouts)
  evalStateT work (St 0 M.empty M.empty M.empty M.empty [] M.empty M.empty M.empty M.empty S.empty S.empty [] [] layouts M.empty M.empty M.empty)
  where
    -- Disabling cloning does not erase the distinction between a checked raw
    -- graph and a tagged generic graph. Conversion can coexist with rollback.
    separate=typeSpec || not (M.null layouts) || any uniformSignature (M.elems declarations)
    uniformSignature sc=let (ps,r)=signatureParts sc in Just UniformRep `elem` (r:ps)
    -- A checked declaration fixes a *parameter's* representation; the call
    -- sites then agree and the uniform entry serves them, so no clone is
    -- needed. The result representation never blocks cloning: a function whose
    -- parameters are representation-unknown is called at more than one
    -- representation, and that is exactly what a clone is for.
    hasConcreteDecl n = case M.lookup n declarations of
      Just ClosedSignature {} -> True
      Just (CallSignature ps _) -> not (null ps) && all (/= Nothing) ps
      Nothing -> False
    canClone n =
      typeSpec
        && S.notMember n pinned
        && n `notElem` ["main", "machineInterrupt"]
        && not (hasConcreteDecl n)
        && case M.lookup n input of
          Just (ps, _) -> not (null ps)
          Nothing -> False

    work = do
      -- An external entry cannot acquire an ABI from whichever internal call
      -- happens to be visited first. The current builtin boundary supports
      -- checked scalar/uniform representations. Aggregate export wrappers
      -- have already converted their public signatures to uniform slots.
      forM_ (S.toList pinned) $ \n ->
        when (n `notElem` ["main", "machineInterrupt"] && M.member n input) $
          case M.lookup n declarations of
            Just sc | let (ps,r) = signatureParts sc, all boundary (r:ps) -> pure ()
            _ -> err ("pinned boundary " ++ n ++ " requires a concrete checked representation; no uniform conversion is available")
      prog0 <- M.traverseWithKey (\_ (ps, b) -> do
        ns <- mapM (const freshName) ps
        b' <- rename (M.fromList (zip ps ns)) b
        pure (ns, b')) input
      sig0 <- traverse (\(ps, _) -> do
        as <- mapM (const fresh) ps
        r <- fresh
        pure (as, r)) prog0
      modify (\s -> s {progDefs = prog0, sigs = sig0})

      forM_ (M.toList declarations) $ \(n, sc) -> withContext ("checking the representation of "++n) $ do
        let (params, result) = signatureParts sc
        sMap <- gets sigs
        case M.lookup n sMap of
          Nothing -> err ("checked representation declaration has no function: " ++ n)
          Just (as, r) -> do
            unless (length as == length params) (err ("checked representation declaration changed physical arity: " ++ n))
            zipWithM_ (\a known -> maybe (pure ()) (\rep -> repType separate rep >>= unify a) known) as params
            maybe (pure ()) (\rep -> repType separate rep >>= unify r) result

      sMap0 <- gets sigs
      case M.lookup "machineInterrupt" sMap0 of
        Nothing -> pure ()
        Just (as, result) -> do
          unless (length as == 3) $ err "machineInterrupt requires cause, pc and trap-value Word arguments"
          mapM_ (`unify` Scalar RawWord) as
          d0 <- freshData separate 0
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

      realizeConversions
      finalProg <- gets progDefs
      finalSigs <- gets sigs
      ann <- gets marks >>= traverse kind
      args <- traverse (mapM kind . fst) finalSigs
      immortalMarks <- gets marks >>= traverse immortal
      immortalArgs <- traverse (mapM immortal . fst) finalSigs
      scalars <- gets marks >>= traverse scalarInfo
      decls <- gets (reverse . declined)
      products <- productEvidence finalSigs
      pure ((finalProg, ann, args, M.keysSet (M.filter id immortalMarks), immortalArgs, M.mapMaybe id scalars, decls), products)

    -- Inference-instance ids merely connect solved occurrences to their
    -- checked definitions. They never determine eligibility or ABI shape.
    productEvidence signatures
      | capacity < 1 = pure emptyProductEvidence
      | otherwise = do
          instances <- gets layoutInstances
          let shapes=productLayouts (min 8 capacity) layouts
          entries <- fmap concat $ forM (M.toList instances) $ \(key,ty) ->
            case M.lookup key shapes of
              Nothing -> pure []
              Just shape -> resolve ty >>= \case
                Data _ inst -> pure [(inst,shape)]
                _ -> err "checked product layout lost its nominal representation"
          if null entries then pure emptyProductEvidence else do
            table <- foldM (\acc (inst,shape) -> case M.lookup inst acc of
              Just other | other /= shape -> err "incompatible checked product value representations"
              _ -> pure (M.insert inst shape acc)) M.empty entries
            let evidenceFor ty = resolve ty >>= \case
                  Data _ inst -> pure (M.lookup inst table)
                  _ -> pure Nothing
            values <- gets marks >>= traverse evidenceFor
            arguments <- traverse (mapM evidenceFor . fst) signatures
            results <- traverse (evidenceFor . snd) signatures
            pure (ProductEvidence (M.mapMaybe id values) arguments results)

    -- A checked boxed layout is not yet a uniform conversion adapter.
    boundary (Just (LayoutRep key)) = maybe False ((/=Nothing) . scalarLayout) (M.lookup key layouts)
    boundary Nothing = False
    boundary _ = True

    immortal t = resolve t >>= \case
      d@(Data tid _) -> do
        scalar<-scalarInfo d
        pure (tid == 0 || tid == 1 || scalar/=Nothing)
      _ -> pure False

    freshName = do
      n <- freshId
      pure ("$rep." ++ show n)

    withContext label action=StateT $ \before->case runStateT action before of
      Left why->Left (why++"\n  while "++label)
      Right result->Right result

    hasProperty predicate seen ty=resolve ty >>= \t->case t of
      Data tid inst->do
        i<-resolveData inst
        if S.member (tid,i) seen then pure False else do
          fs<-gets fields
          or <$> mapM (hasProperty predicate (S.insert (tid,i) seen))
            [f | ((t',i',_,_),f)<-M.toList fs,t'==tid,i'==i]
      _->pure (predicate t)

    -- A uniform slot is an explicit conversion boundary, not an equation
    -- between a pointer and raw bits. Try ordinary unification transactionally
    -- first; a failed attempt must not constrain either graph.
    coerce expression actual expected
      | actual==expected=pure expression
      | otherwise=do
          before<-get
          case runStateT (unify actual expected) before of
            Right (_,after)->put after >> pure expression
            Left why->do
              sourceUniform<-hasProperty (==Uniform) S.empty actual
              targetUniform<-hasProperty (==Uniform) S.empty expected
              compatible<-uniformCompatible S.empty actual expected
              unless ((sourceUniform || targetUniform) && compatible) (lift (Left why))
              constructOrConvert expression actual expected

    markAs ty expression=do
      modify (\s->s {marks=M.insert expression ty (marks s)})
      pure expression

    -- Build a value directly in its destination field layout. Evaluate all
    -- source fields once, in order, before promoting any of them; allocating
    -- conversions must not move ahead of a later field's observable effect.
    constructOrConvert expression actual expected=case expression of
      CMk tid variant values->do
        source<-resolve actual;target<-resolve expected
        fs<-gets fields
        case (source,target) of
          (Data t i,Data u j) | tid==t && t==u->do
            let slots inst=mapM (\k->M.lookup (tid,inst,variant,k) fs) [0..length values-1]
            case (slots i,slots j) of
              (Just from,Just to)->do
                names<-mapM (const freshName) values
                vars<-sequence (zipWith markAs from (map CVar names))
                converted<-sequence (zipWith3 coerce vars from to)
                node<-markAs expected (CMk tid variant converted)
                foldM (\body (name,value)->markAs expected (CLet name value body)) node
                  (reverse (zip names values))
              _->defer
          _->defer
      CLet n a b->coerce b actual expected >>= markAs expected . CLet n a
      CIf c a b->do
        annotations<-gets marks
        a'<-coerce a (M.findWithDefault actual a annotations) expected
        b'<-coerce b (M.findWithDefault actual b annotations) expected
        markAs expected (CIf c a' b')
      _->defer
      where
        defer=do
          n<-freshId
          let marker="$uniform.coerce."++show n
              converted=CApp (CVar marker) expression
          modify (\s->s {conversions=M.insert marker (actual,expected) (conversions s)})
          markAs expected converted

    uniformCompatible seen a b=do
      x<-resolve a;y<-resolve b
      case (x,y) of
        _ | x==y->pure True
        (Uniform,_)->pure True
        (_,Uniform)->pure True
        (Var _,_)->pure True
        (_,Var _)->pure True
        (Text,Scalar Managed)->pure True
        (Scalar Managed,Text)->pure True
        (Data t i,Data u j) | t==u->do
          i'<-resolveData i;j'<-resolveData j
          let key=(t,i',j')
          if S.member key seen then pure True else do
            fs<-gets fields
            let slots instanceId=M.fromList [((v,k),f) | ((tid,inst,v,k),f)<-M.toList fs,tid==t,inst==instanceId]
            and <$> sequence (M.elems (M.intersectionWith (uniformCompatible (S.insert key seen)) (slots i') (slots j')))
        _->pure False

    -- Reify only after all calls/projections have supplied their field
    -- evidence. Unchanged managed subgraphs need no traversal or copying.
    conversionShape root=do
      (rep,(_,table))<-runStateT (visit root) (M.empty,M.empty)
      pure (rep,table)
      where
        visit ty=lift (resolve ty) >>= \t->case t of
          Scalar k->pure (ScalarRep k)
          Uniform->pure UniformRep
          Text->pure TextRep
          Var _->lift (err "unresolved representation at uniform boundary")
          Data tid inst->do
            if tid==0 || tid==1 then pure (DataRep tid) else do
              i<-lift (resolveData inst)
              seen<-gets fst
              case M.lookup (tid,i) seen of
                Just key->pure (LayoutRep key)
                Nothing->do
                  let key="node"++show (M.size seen)
                  modify (\(ns,ls)->(M.insert (tid,i) key ns,ls))
                  fs<-lift (gets fields)
                  evidence<-lift (gets checkedLayouts)
                  let observed=M.fromListWith max [(v,k+1) | ((t',i',v,k),_)<-M.toList fs,t'==tid,i'==i]
                      declared=M.unionsWith max [M.map length vs | def<-M.elems evidence,let (t',vs)=layoutParts def,t'==tid]
                      variants=M.unionWith max observed declared
                  vs<-mapM (\(v,arity)->do
                    members<-mapM (\k->case M.lookup (tid,i,v,k) fs of
                      Just member->Just <$> visit member
                      Nothing->lift (err "incomplete field evidence at uniform boundary")) [0..arity-1]
                    pure (v,members)) (M.toAscList variants)
                  choice<-lift (gets (M.lookup i . storageChoices))
                  def<-case choice of
                    Just (ScalarStorage variant)->case lookup variant vs of
                      Just [Just payload]->pure (ScalarLayoutDef tid variant payload)
                      _->lift (err "incomplete scalar field evidence at uniform boundary")
                    _->pure (LayoutDef tid (M.fromList vs))
                  modify (\(ns,ls)->(ns,M.insert key def ls))
                  pure (LayoutRep key)

    containsScalar seen ty=resolve ty >>= \t->case t of
      Data tid inst | S.notMember inst seen->do
        info<-scalarInfo t
        if info/=Nothing then pure True else do
          fs<-gets fields
          or <$> mapM (containsScalar (S.insert inst seen))
            [f | ((t',i',_,_),f)<-M.toList fs,t'==tid,i'==inst]
      _->pure False

    realizeConversions=do
      pending<-gets conversions
      oldMarks<-gets marks
      displays<-M.mapMaybe id . M.fromList <$> mapM (\(arg,ty)->do
        hasScalar<-containsScalar S.empty ty
        shape<-if hasScalar then Just <$> conversionShape ty else pure Nothing
        pure (arg,shape))
        [(arg,ty) | CApp (CVar op) arg<-M.keys oldMarks,op `elem` ["print","str"],Just ty<-[M.lookup arg oldMarks]]
      -- Most checked scalar programs need neither nominal formatting nor a
      -- boundary adapter. Preserve their graph without rebuilding every mark.
      unless (M.null pending && M.null displays) $ do
        plans<-traverse (\(a,b)->do x<-conversionShape a;y<-conversionShape b;pure (x,y,b)) pending
        modify (\s->s {marks=M.empty})
        let rewrite expr=case expr of
              CApp (CVar op) argument | op `elem` ["print","str"],Just (rep,table)<-M.lookup argument displays->do
                value<-rewrite argument
                let promoted=UniformBoundary.convert table "box" rep value
                annotate value Uniform promoted
                pure (CApp (CVar op) promoted)
              CApp (CVar name) argument | Just ((source,sourceTable),(target,targetTable),result)<-M.lookup name plans->do
                value<-rewrite argument
                let converted=UniformBoundary.convertChecked targetTable "unbox" target
                      (UniformBoundary.convert sourceTable "box" source value)
                annotate value result converted
                pure converted
              CApp f x->CApp <$> rewrite f <*> rewrite x
              CLet n a b->CLet n <$> rewrite a <*> rewrite b
              CIf c a b->CIf <$> rewrite c <*> rewrite a <*> rewrite b
              CMk t v fs->CMk t v <$> mapM rewrite fs
              CProj i x->CProj i <$> rewrite x
              CTagEq t v x->CTagEq t v <$> rewrite x
              CLam ps b->CLam ps <$> rewrite b
              _->pure expr
            annotate original result expr | expr==original=pure ()
            annotate original result expr=do
              ty<-case expr of
                CStr _->pure Text
                CInt _->pure (Scalar Managed)
                CMk tid _ fs->mapM_ (annotate original result) fs >> pure (Data tid 0)
                CApp {}->case spine expr of
                  (CVar name,args)->do
                    mapM_ (annotate original result) args
                    pure (if "$uniform.box" `isPrefixOf` name then Uniform else result)
                  _->err "invalid generated uniform conversion"
                _->err "unexpected generated uniform value"
              modify (\s->s {marks=M.insert expr ty (marks s)})
        rewrittenMarks<-mapM (\(e,t)->do e'<-rewrite e;pure (e',t)) (M.toList oldMarks)
        p<-gets progDefs
        p'<-traverse (\(ps,b)->(,) ps <$> rewrite b) p
        modify (\s->s {progDefs=p',marks=marks s `M.union` M.fromList rewrittenMarks})

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
            b'' <- withContext ("lowering "++n) $ do
              (b', t) <- infer (M.fromList (zip ps as)) b
              coerce b' t r
            modify
              ( \s ->
                  s
                    { progDefs = M.insert n (ps, b'') (progDefs s),
                      inferredFns = S.insert n (inferredFns s),
                      activeFns = S.delete n (activeFns s)
                    }
              )
          _ -> pure ()

    repKey seen t = do
      r <- resolve t
      case r of
        Scalar k -> pure [kindTag k]
        Uniform -> pure "u"
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
              storage<-scalarInfo r
              pure ("D" ++ show tid ++ (if storage==Nothing then "b" else "s") ++ "[" ++ intercalate "," sub ++ "]")

    repTree seen t = do
      r <- resolve t
      case r of
        Scalar k -> pure (RepTree [kindTag k] [])
        Uniform -> pure (RepTree "u" [])
        Text -> pure (RepTree "s" [])
        Var _ -> pure (RepTree "t" [])
        Data tid inst -> do
          inst' <- resolveData inst
          storage<-scalarInfo r
          let label = "D" ++ show tid ++ (if storage==Nothing then "b" else "s")
          if S.member inst' seen
            then pure (RepTree label [])
            else do
              fs <- gets fields
              children <- mapM (\(v, i, ty) -> do
                child <- repTree (S.insert inst' seen) ty
                pure (RepTree (show v ++ ":" ++ show i) [child]))
                [(v, i, ty) | ((t', i', v, i), ty) <- M.toList fs, t' == tid, i' == inst']
              pure (RepTree label children)

    inferInstance origin target actual = do
      previous <- gets activeInstances
      trees <- mapM (repTree S.empty) actual
      modify (\s -> s {activeInstances = (origin, target, trees) : previous})
      inferFunction target
      modify (\s -> s {activeInstances = previous})

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
                d <- freshData separate tid
                pure (e, d)
              _ -> do
                (target, _, r) <- apply n [] []
                pure (CVar target, r)
        CLet n a b -> do
          (a', t) <- infer env a
          (b', tb) <- infer (M.insert n t env) b
          pure (CLet n a' b', tb)
        CIf c a b -> do
          (c', tc) <- infer env c
          d1 <- freshData separate 1
          condition <- coerce c' tc d1
          (a', ta) <- infer env a
          (b', tb) <- infer env b
          aUniform<-hasProperty (==Uniform) S.empty ta
          bUniform<-hasProperty (==Uniform) S.empty tb
          if aUniform && not bUniform
            then do converted<-coerce a' ta tb;pure (CIf condition converted b',tb)
            else do converted<-coerce b' tb ta;pure (CIf condition a' converted,ta)
        CMk tid v fs -> do
          (fs', ftys) <- mapAndUnzipM (infer env) fs
          d <- freshData separate tid
          inst <- dataInstance d
          forM_ (zip [0 ..] ftys) $ \(i, fty) -> do
            b <- field (tid, inst, v, i)
            unify fty b
          pure (CMk tid v fs', d)
        CTagEq tid v x -> do
          (x', t) <- infer env x
          rt<-resolve t
          d1 <- freshData separate 1
          if rt==Uniform then do
            tag<-markAs (Scalar Managed) (CInt (toInteger tid))
            variant<-markAs (Scalar Managed) (CInt (toInteger v))
            pure (foldl CApp (CVar "$uniform.tagEq") [x',tag,variant],d1)
          else do
            d<-freshData separate tid
            unify t d
            pure (CTagEq tid v x',d1)
        CProj i x -> do
          (x', a) <- infer env x
          ra <- resolve a
          if ra==Uniform then do
            index<-markAs (Scalar Managed) (CInt (toInteger i))
            pure (foldl CApp (CVar "$uniform.project") [x',index],Uniform)
          else do
            b <- fresh
            case ra of
              Data tid inst -> do
                inst' <- resolveData inst
                fs <- gets fields
                let candidates = [v | ((t', i', _, i''), v) <- M.toList fs, t' == tid, i' == inst', i'' == i]
                mapM_ (unify b) candidates
              _ -> pure ()
            modify (\s -> s {projections = (a, i, b) : projections s})
            pure (CProj i x', b)
        -- An open-row update dispatches over several nominal record shapes.
        -- Establish its tagged result at each branch before their unrelated
        -- native layouts meet. Lets retain their original strict evaluation.
        CApp (CVar marker) (CIf c a b)
          | M.notMember marker env,M.lookup marker evidence==Just UniformRep ->
              infer env (CIf c (CApp (CVar marker) a) (CApp (CVar marker) b))
        CApp (CVar marker) (CLet n a b)
          | M.notMember marker env,M.lookup marker evidence==Just UniformRep ->
              infer env (CLet n a (CApp (CVar marker) b))
        CApp (CVar marker) value | M.notMember marker env,Just rep<-M.lookup marker evidence->do
          -- A tagged constructor owns tagged fields. Push the requirement
          -- into nested update dispatches too, before native alternatives join.
          let input=case (rep,value) of
                (UniformRep,CMk tid variant fields)->CMk tid variant [CApp (CVar marker) field | field<-fields]
                _->value
          (value',actual)<-infer env input
          expected<-repType separate rep
          converted<-coerce value' actual expected
          pure (converted,expected)
        CApp {} ->
          let (f, as) = spine e
           in case f of
                CVar n | M.notMember n env -> do
                  (as', actualTys) <- mapAndUnzipM (infer env) as
                  names<-mapM (const freshName) as'
                  vars<-sequence (zipWith markAs actualTys (map CVar names))
                  (target, converted, r) <- apply n vars actualTys
                  if converted==vars
                    then do
                      modify (\s->s {marks=foldr M.delete (marks s) vars})
                      pure (foldl CApp (CVar target) as',r)
                    else do
                      -- Boundary checks/boxing run after source argument
                      -- evaluation, including effects in later arguments.
                      invocation<-markAs r (foldl CApp (CVar target) converted)
                      body<-foldM (\b (name,value)->markAs r (CLet name value b)) invocation
                        (reverse (zip names as'))
                      pure (body,r)
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
              converted <- sequence (zipWith3 coerce actualExprs actual expected)
              inferFunction n
              pure (n, converted, result)
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
                  inferInstance n n actual
                  pure (n, actualExprs, result)
                Just key0
                  | key == key0 -> do
                      zipWithM_ unify actual expected
                      inferFunction n
                      pure (n, actualExprs, result)
                  | Just target <- M.lookup (n, key) cMap -> do
                      sMap' <- gets sigs
                      let (expT, resT) = sMap' M.! target
                      zipWithM_ unify actual expT
                      inferFunction target
                      pure (target, actualExprs, resT)
                  | otherwise -> do
                      (target,result)<-instantiateClone n key actual
                      pure (target,actualExprs,result)
        Nothing | "$sym." `isPrefixOf` n -> do
          unless (null actual) $ err ("partial/over-application of " ++ n ++ " is not supported yet")
          pure (n, [], Scalar RawAddr)
        Nothing -> case primitiveShape n of
          Nothing -> err ("unsupported primitive or function value: " ++ n)
          Just (PrimitiveShape params result) -> do
            unless (length actual == length params) $
              err ("partial/over-application of " ++ n ++ " is not supported yet")
            anyT <- fresh
            let ty AnyValue = pure anyT
                ty (KnownValue rep) = repType separate rep
            expected <- mapM ty params
            resT <- ty result
            converted <- sequence (zipWith3 coerce actualExprs actual expected)
            pure (n, converted, resT)

    instantiateClone n key actual = do
      active <- gets activeInstances
      reused <- reuseActive [target | (origin, target, _) <- active, origin == n]
      case reused of
        Just answer -> pure answer
        Nothing -> newClone n key actual
      where
        -- A recursive list accumulator can expose more constructor fields
        -- than its first call did, without changing its representation. Try
        -- the active equation first, transactionally: a failed unification
        -- must not leak partial field/variable bindings into a new clone.
        reuseActive [] = pure Nothing
        reuseActive (target : rest) = do
          before <- get
          let (expected, result) = sigs before M.! target
          case runStateT (zipWithM_ unify actual expected) before of
            Left _ -> reuseActive rest
            Right (_, after) -> do
              put after {cloneMap = M.insert (n, key) target (cloneMap after)}
              pure (Just (target, result))

    newClone n key actual = do
      let (psOrig, bodyOrig) = input M.! n
      trees <- mapM (repTree S.empty) actual
      active <- gets activeInstances
      when (any (\(origin, _, earlier) -> origin == n && and (zipWith embeds earlier trees)) active) $
        err ("expanding recursive type specialization of " ++ n
          ++ "; a finite representation graph is required (no uniform conversion is available)")
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
      -- Checked output evidence is a contract on every instantiation, not
      -- only on the first one. (A concrete result does not prevent cloning.)
      case M.lookup n declarations of
        Just sc -> do
          let (params, result) = signatureParts sc
          zipWithM_ (\a known -> maybe (pure ()) (\rep -> repType separate rep >>= unify a) known) asT params
          maybe (pure ()) (\rep -> repType separate rep >>= unify rT) result
        Nothing -> pure ()
      modify
        ( \s ->
            s
              { progDefs = M.insert target (ns, b') (progDefs s),
                sigs = M.insert target (asT, rT) (sigs s),
                cloneMap = M.insert (n, key) target (cloneMap s)
              }
        )
      zipWithM_ unify actual asT
      inferInstance n target actual
      pure (target, rT)

    spine = go []
      where
        go as (CApp f x) = go (x : as) f
        go as f = (f, as)
