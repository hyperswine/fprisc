{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
module Core.Opt.Vector (vecSpec, pipelinePlan, nestPipelines,nestPipelinesWithImports, specUsesFloat, arithClosure, planCapKinds) where
import Core.Syntax
import Core.Utils
import Core.Primitives
import Core.Analysis.FusionSafety
import Core.Opt.Vector.Plan
import KernelKinds (Kind(..), signature)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Graph (SCC(..), stronglyConnComp)
import Data.List (foldl')
import Data.Maybe (fromMaybe, isJust)

-- The existing runtime value-ABI arity ceiling (fpr.h FPR_ARGSPILL).
spillCells :: Int
spillCells = 56

-- A bounded, same-element-kind scalar pipeline. Entry arguments are flattened
-- outermost-first, just like source evaluation; stages execute innermost-first.
-- Captures and seed must already be values, so let nesting cannot move effects.
pipelinePlan :: Prog -> (String -> Bool) -> Core -> Maybe (SpecPlan,[Core])
pipelinePlan prog local expr = do
  (stages,args,kinds,acc,vector) <- collect True 0 expr
  -- Start with genuinely mixed, filtering pipelines. Keep map-only chains
  -- (including map/fold) on their existing SIMD/worker paths.
  let ops=[op | (op,_,_,_)<-stages]
  if length stages < 2 || length stages > 16 || length args > 7 ||
     Filter `notElem` ops || not (any (`elem` [Map,Fold]) ops)
    then Nothing else Just ()
  let elems=[last ks | (_,_,_,ks)<-stages]
  element <- case elems of k:rest | k/=KB && all (==k) rest -> Just k; _ -> Nothing
  let names=[f | (_,f,_,_)<-stages]
  cl <- arithClosure prog names
  if S.size cl > 64 || not (all (fusionSafe prog) names) ||
     not (acyclic cl) then Nothing else Just ()
  let pipeline=PipePlan [(op,f,slots) | (op,f,slots,_)<-stages] element acc
      result=maybe element snd acc
      plan=SpecPlan (FusedPipeline pipeline) (head names) True cl Nothing Nothing Nothing
             (case result of KD->Just Float64; KS->Just Float32; _->Nothing)
             (length args) (Just (kinds++[element],result))
  pure (plan,args++[vector])
  where
    primitive op = not (local op) && M.notMember op prog
    value (CVar n) = local n
    value (CInt _) = True
    value (CMk 1 _ []) = True
    value e = isJust (floatLitBits e)
    callback count fe = do
      (CVar f,caps) <- Just (spineOf fe)
      (ps,b) <- M.lookup f prog
      if local f || length ps/=length caps+count || length ps>8 || not (all value caps)
        then Nothing else Just ()
      sig <- signature prog ps b
      pure (f,caps,sig)
    collect top offset e = case spineOf e of
      (CVar op,[fe,z,v]) | top, op=="Vec.fold", primitive op -> do
        (f,caps,(ks,out)) <- callback 2 fe
        let n=length caps; ak=ks!!n
        if not (value z) || ak/=out || out==KB then Nothing else Just ()
        (ss,as,ts,_,input) <- collect False (offset+n+1) v
        pure (ss++[(Fold,f,[offset..offset+n-1],ks)],caps++[z]++as,
              take n ks++[ak]++ts,Just (offset+n,ak),input)
      (CVar op,[fe,v]) | op `elem` ["Vec.map","Vec.filter"], primitive op -> do
        (f,caps,(ks,out)) <- callback 1 fe
        let n=length caps; short=if op=="Vec.map" then Map else Filter
        if (short==Map && (last ks/=out || out==KB)) ||
           (short==Filter && out/=KB) then Nothing else Just ()
        (ss,as,ts,acc,input) <- collect False (offset+n) v
        pure (ss++[(short,f,[offset..offset+n-1],ks)],caps++as,take n ks++ts,acc,input)
      _ -> Just ([],[],[],Nothing,e)
    -- Cyclic callback graphs can change divergence-versus-failure behavior
    -- when passes interleave. Start with finite arithmetic callbacks only.
    acyclic cl = all isAcyclic (stronglyConnComp
      [(f,f,S.toList calls) | f<-S.toList cl, let (ps,b)=prog M.! f,
                            let calls=fromMaybe S.empty (bodyOK prog (S.fromList ps) b)])
    isAcyclic (AcyclicSCC _) = True
    isAcyclic _ = False

-- Only adjacent, single-consumer lets are nested; a successfully planned
-- pipeline proves that moved captures/seed are already values. Bindings remain
-- lexical, and a retained intermediate prevents this rewrite.
nestPipelines :: Prog -> Prog
nestPipelines=nestPipelinesWithImports M.empty
nestPipelinesWithImports :: Prog -> Prog -> Prog
nestPipelinesWithImports imports prog = M.map (\(ps,b)->(ps,go (S.fromList ps) b)) prog
  where
    go bound e = join bound $ case e of
      CLet n a b -> CLet n (go bound a) (go (S.insert n bound) b)
      CApp a b -> CApp (go bound a) (go bound b)
      CIf c a b -> CIf (go bound c) (go bound a) (go bound b)
      CMk t v xs -> CMk t v (map (go bound) xs)
      CTagEq t v x -> CTagEq t v (go bound x)
      CProj k x -> CProj k (go bound x)
      _ -> e
    join bound e@(CLet x producer body) =
      let replace consumer = case spineOf consumer of
            (CVar op,args) | op `elem` ["Vec.map","Vec.filter","Vec.fold"],
              not (null args), all (not . elem x . freeVars) (init args) -> do
                input <- if last args==CVar x then Just producer else replace (last args)
                pure (foldl' CApp (CVar op) (init args++[input]))
            _ -> Nothing
          plug consumer = do
            candidate <- replace consumer
            _ <- pipelinePlan (prog `M.union` imports) (`S.member` bound) candidate
            pure candidate
      in case body of
        CLet y consumer rest | x `notElem` freeVars rest, Just candidate<-plug consumer ->
          go bound (CLet y candidate rest)
        _ | Just candidate<-plug body -> go bound candidate
        _ -> e
    join _ e = e

vecSpec :: Bool -> Prog -> (String -> Bool) -> Core -> Maybe (SpecPlan, [Core])
vecSpec fusion prog isLocal e = do
  (p,args) <- case if fusion then pipelinePlan prog isLocal e else Nothing of
    Just plan -> Just plan
    Nothing -> vecSpecRaw fusion prog isLocal e
  typed <- typePlan prog p
  pure (typed,args)

-- The soft-float switch covers column kernels as well as scalar primitives.
-- A comparison can return Bool/Int while still consuming floats; record maps
-- can mix integer and floating fields. Inspect inputs and the whole closure,
-- not just the result representation, before requesting an unboxed clone.
specUsesFloat :: Prog -> SpecPlan -> Bool
specUsesFloat prog p =
  isJust (spFloat p) || isJust (floatWidthOf prog (spClosure p))
    || any floating (maybe [] (:[]) (spKinds p)
                    ++ maybe [] (maybe [] id . mvKinds) (spMv p))
  where
    floating (ks,k) = any (\t -> t == KD || t == KS) (k:ks)

-- Each raw argument has its own kind. Record maps retain their field plans;
-- mapAs retains the ordinary tagged callback ABI, rather than guessing kinds.
typePlan :: Prog -> SpecPlan -> Maybe SpecPlan
typePlan prog p
  | Just _ <- pipelineOf p = Just p
  | Just mp <- spMv p = do
      sigs <- mapM (\(_, (ps,b)) -> signature prog ps b) (mvFields mp)
      if any (\(ks,out) -> KB `elem` (out:ks)) sigs then Nothing else Just ()
      let reads = [(col,k) | (((ms,cs),_), (ks,_)) <- zip (mvFields mp) sigs,
                            (col,k) <- zip cs (drop (length ms) ks)]
          outputs = zip [0..] (map snd sigs)
      if all (\(col,k) -> all (\(c,t) -> c /= col || t == k) reads) outputs then Just () else Nothing
      pure p {spMv=Just mp {mvKinds=Just sigs}}
  | LayoutMap _ <- spOp p = Just p
  | otherwise = do
      (ps,b) <- case spSoa p of
        Just (_,ps,b,_) -> Just (ps,b)
        Nothing -> M.lookup (spFn p) prog
      sig@(ks,out) <- signature prog ps b
      let foldOp = spOp p == ScalarOp Fold || wfoldG p /= Nothing
          args = drop (spCaps p) ks
      pure () -- Bool captures have a checked boxed-to-raw entry path
      if foldOp then case args of
        acc:_ | acc == out, out /= KB -> Just ()
        _ -> Nothing
      else if spOp p `elem` [ScalarOp Filter,RecordFilter] then
        if out == KB then Just () else Nothing
      else if args == [out] && out /= KB then Just () else Nothing
      if any (== KB) args then Nothing else Just ()
      pure p {spKinds=Just sig, spFloat=case out of KD -> Just Float64; KS -> Just Float32; _ -> Nothing}

vecSpecRaw :: Bool -> Prog -> (String -> Bool) -> Core -> Maybe (SpecPlan,[Core])
vecSpecRaw fusion prog isLocal e = case spineOf e of
  (CVar "Vec.mapAs", [CStr layout, fe, v])
    | (CVar f, caps) <- spineOf fe,
      okOp "Vec.mapAs", okFn f (length caps + 1), length caps + 1 <= 8 ->
        Just (SpecPlan (LayoutMap layout) f False S.empty Nothing Nothing Nothing Nothing (length caps) Nothing, caps ++ [v])
  (CVar "Vec.map", [fe, v])
    | (CVar f, [capE]) <- spineOf fe,
      okOp "Vec.map",
      okFn f 2,
      Just mp <- soaDualMap prog f (capShapeOf capE) -> do
        cl <- arithClosure prog [fn | (_, (_, b)) <- mvFields mp, fn <- S.toList (calleesOf prog b)]
        Just (SpecPlan RecordMap f False cl Nothing Nothing (Just mp) Nothing 0 Nothing, [capE, v])
  (CVar "Vec.map", [CVar f, v])
    | okOp "Vec.map",
      okFn f 1,
      Just mp <- soaDualMap0 prog f -> do
        cl <- arithClosure prog [fn | (_, (_, b)) <- mvFields mp, fn <- S.toList (calleesOf prog b)]
        -- capture-free record->record map: same in-place column loop,
        -- with a dead capture slot (a0 = tagged 0, never dereferenced:
        -- ms is empty for every field, so nothing loads off s8)
        Just (SpecPlan RecordMap f False cl Nothing Nothing (Just mp) Nothing 0 Nothing, [CInt 0, v])
  (CVar "Vec.map", [CVar f, v]) | okOp "Vec.map", okFn f 1 -> plan Map f [v]
  (CVar "Vec.filter", [CVar f, v])
    | okOp "Vec.filter", okFn f 1, Just pl <- planSpec prog Filter f -> Just (pl, [v])
  -- a predicate over a RECORD element: the column-compaction kernel
  (CVar "Vec.filter", [CVar f, v])
    | okOp "Vec.filter",
      okFn f 1,
      Just (ks, ps, b, tv, cl) <- soaDualPred prog f ->
        Just (SpecPlan RecordFilter f False cl (Just (ks, ps, b, tv)) Nothing Nothing Nothing 0 Nothing, [v])
  -- scalar captures: Vec.map (affine a b) v, Vec.filter (above k) v.  The
  -- captures ride ahead of the vector in the kernel's argument list; the
  -- element function's arity is captures + 1 and fits the 8 registers.
  (CVar "Vec.map", [fe, v])
    | (CVar f, caps@(_ : _)) <- spineOf fe,
      okOp "Vec.map",
      okFn f (length caps + 1),
      length caps + 1 <= 8 ->
        (,caps ++ [v]) <$> planSpecCaps prog Map f (length caps)
  (CVar "Vec.filter", [fe, v])
    | (CVar f, caps@(_ : _)) <- spineOf fe,
      okOp "Vec.filter",
      okFn f (length caps + 1),
      length caps + 1 <= 8 ->
        (,caps ++ [v]) <$> planSpecCaps prog Filter f (length caps)
  -- WRITE-BACK FOLD: Vec.fold f z (Vec.map g v) fuses into ONE pass
  -- that stores g(el) back into the column AND folds f over it -- the
  -- map's writes stay program-visible through the returned vector, so
  -- this is the fusion the map/map rewrite could never express (2026-08-25-VEC.md
  -- open item 1).  Scalar int tier only in v1; anything else falls
  -- through to the plain fold plan below, whose map argument then
  -- specializes on its own.
  (CVar "Vec.fold", [CVar f, z, me])
    | fusion, (CVar "Vec.map", [CVar g, v]) <- spineOf me,
      okOp "Vec.fold",
      not (isLocal "Vec.map"),
      okFn f 2,
      okFn g 1,
      fusionSafe prog f,
      fusionSafe prog g, -- a fold step and a map step interleave per element
      Just clf <- arithClosure prog [f],
      Just clg <- arithClosure prog [g],
      floatWidthOf prog clf == Nothing,
      floatWidthOf prog clg == Nothing ->
        Just (SpecPlan (WritebackFold g) f True (clf `S.union` clg) Nothing Nothing Nothing Nothing 0 Nothing, [z, v])
  (CVar "Vec.fold", [fe, z, v])
    | (CVar f, caps@(_ : _)) <- spineOf fe,
      okOp "Vec.fold", okFn f (length caps + 2), length caps + 2 <= 8 ->
        let k = length caps in (,caps ++ [z,v]) <$> case planSpecCaps prog Fold f k of
          Just p -> Just p
          Nothing -> do
            (ks,ps,b,tv,cl) <- soaDualCaps prog f k
            Just (SpecPlan (ScalarOp Fold) f False cl (Just (ks,ps,b,tv)) Nothing Nothing Nothing k Nothing)
  (CVar "Vec.fold", [CVar f, z, v]) | okOp "Vec.fold", okFn f 2 -> plan Fold f [z, v]
  _ -> Nothing
  where
    okOp h = not (isLocal h) && M.notMember h prog
    okFn f n = not (isLocal f) && maybe False ((== n) . length . fst) (M.lookup f prog)
    plan op f args = (,args) <$> planSpec prog op f

calleesOf :: Prog -> Core -> S.Set String
calleesOf prog = go
  where
    go e = case spineOf e of
      (CVar h, args@(_ : _)) | M.member h prog -> S.insert h (S.unions (map go args))
      _ -> case e of
        CApp a b -> go a `S.union` go b
        CLet _ a b -> go a `S.union` go b
        CIf c t f' -> S.unions [go c, go t, go f']
        CMk _ _ fs -> S.unions (map go fs)
        CTagEq _ _ x -> go x
        CProj _ x -> go x
        _ -> S.empty

planSpec :: Prog -> ElementOp -> String -> Maybe SpecPlan
planSpec prog Fold f =
  let scal = arithClosure prog [f]
      fw = floatWidthOf prog (maybe S.empty id scal)
      soa = soaDual prog f
      rvv = if isSumFn prog f then Just RvvFoldSum else Nothing
   in if scal == Nothing && soa == Nothing
        then Nothing
        else
          Just
            SpecPlan
              { spOp = ScalarOp Fold,
                spFn = f,
                spScalar = scal /= Nothing,
                spClosure = S.unions [maybe S.empty id scal, maybe S.empty (\(_, _, _, _, cl) -> cl) soa],
                spSoa = (\(ks, ps, b, tv, _) -> (ks, ps, b, tv)) <$> soa,
                spRvv = if fw == Nothing then rvv else Nothing,
                spMv = Nothing,
                spFloat = fw,
                spCaps = 0,
                spKinds = Nothing
              }
planSpec prog op f = planSpecCaps prog op f 0

-- a map/filter plan whose element function takes k scalar captures
-- ahead of the element.  Float closures decline: a raw float capture
-- carries no tag to check, so the entry guard could not tell it from
-- a pointer.
planSpecCaps :: Prog -> ElementOp -> String -> Int -> Maybe SpecPlan
planSpecCaps prog op f k = do
  cl <- arithClosure prog [f]
  let rvv = case M.lookup f prog of
        Just ([p], body) | op == Map, k == 0, Just b <- straightLine [p] body -> Just (RvvMap p b)
        _ -> Nothing
  let fw = floatWidthOf prog cl
  pure () -- captures are validated individually by typePlan
   -- RVV lanes are integer vadd/vmul in this pass, so a float
   -- closure takes the scalar float loop, not the vector one
  Just (SpecPlan (ScalarOp op) f True cl Nothing (if fw == Nothing then rvv else Nothing) Nothing fw k Nothing)

-- the closed arithmetic call graph rooted at the given functions;
-- Nothing if anything outside the unboxable fragment is reachable
arithClosure :: Prog -> [String] -> Maybe (S.Set String)
arithClosure prog = go S.empty
  where
    go acc [] = Just acc
    go acc (n : rest)
      | S.member n acc = go acc rest
      | otherwise = do
          (ps, body) <- M.lookup n prog
          calls <- bodyOK prog (S.fromList ps) body
          go (S.insert n acc) (S.toList calls ++ rest)

-- checks one body against the unboxable fragment; returns callees
bodyOK :: Prog -> S.Set String -> Core -> Maybe (S.Set String)
bodyOK prog = ok
  where
    ok env e
      | Just _ <- floatLitBits e = Just S.empty -- a folded float literal
    ok env e = case spineOf e of
      (CVar h, args@(_ : _))
        | h `elem` uPrims || h `elem` fPrims,
          Just 2 <- lookup h primArities,
          length args == 2 ->
            S.unions <$> mapM (ok env) args
        | Just (ps, _) <- M.lookup h prog,
          not (S.member h env),
          length ps == length args ->
            S.insert h . S.unions <$> mapM (ok env) args
      _ -> case e of
        CVar n | S.member n env -> Just S.empty
        CInt _ -> Just S.empty
        CMk 1 _ [] -> Just S.empty -- True/False literals
        CTagEq 1 _ x -> ok env x -- Bool tag test on a raw 0/1
        CIf c t f -> S.unions <$> sequence [ok env c, ok env t, ok env f]
        CLet x a b -> S.union <$> ok env a <*> ok (S.insert x env) b
        CErr _ -> Just S.empty -- dead case arms
        _ -> Nothing

planCapKinds :: SpecPlan -> [Kind]
planCapKinds p = maybe (replicate (spCaps p) KI) (take (spCaps p) . fst) (spKinds p)

-- does this closure compute in floats (and at which width)?  Decided
-- from the bodies, which is also what picks the loop's rep guard.
floatWidthOf :: Prog -> S.Set String -> Maybe FloatWidth
floatWidthOf prog names =
  case [w | w <- [Float64, Float32], any (usesW w) (S.toList names)] of
    (w : _) -> Just w
    [] -> Nothing
  where
    usesW w n = maybe False (goB w . snd) (M.lookup n prog)
    goB w e = case spineOf e of
      (CVar h, args) | h `elem` fPrimsOf w -> True
                     | otherwise -> any (goB w) args
      _ -> case e of
        CIf c t f -> goB w c || goB w t || goB w f
        CLet _ a b -> goB w a || goB w b
        _ -> False

-- inline trivial re-lets (the desugarer's  let a = a1_0 in ...)
peel :: Core -> Core
peel (CLet x (CVar y) b) = peel (subst x y b)
peel e = e

subst :: String -> String -> Core -> Core
subst x y = go
  where
    go (CVar n) = CVar (if n == x then y else n)
    go (CApp a b) = CApp (go a) (go b)
    go (CLet n a b) = CLet n (go a) (if n == x then b else go b)
    go (CIf c t f) = CIf (go c) (go t) (go f)
    go (CMk t v fs) = CMk t v (map go fs)
    go (CTagEq t v e) = CTagEq t v (go e)
    go (CProj k e) = CProj k (go e)
    go e = e

-- is f literally \a b -> a + b (mod trivial lets / arg order)?
isSumFn :: Prog -> String -> Bool
isSumFn prog f = case M.lookup f prog of
  Just ([a, b], body) -> case spineOf (peel body) of
    (CVar "+", [CVar x, CVar y]) -> (x == a && y == b) || (x == b && y == a)
    _ -> False
  _ -> False

-- straight-line +/-/* expression over the param: RVV-mappable
straightLine :: [String] -> Core -> Maybe Core
straightLine ps body0 = body0 <$ chk (S.fromList ps) (peel body0)
  where
    chk env e = case spineOf e of
      (CVar h, [a, b]) | h `elem` ["+", "-", "*"] -> chk env a >> chk env b
      _ -> case e of
        CVar n | S.member n env -> Just ()
        CInt _ -> Just ()
        CLet x a b -> chk env a >> chk (S.insert x env) b
        _ -> Nothing

-- fold-over-SoA dualization: rewrite  CProj k (CVar el)  to a fresh
-- column variable; the loop feeds those from per-column cursors and the
-- tuple is never built.  Returns (used columns, ufn params, body, extra
-- arithmetic closure needed by calls inside the body).
soaDual :: Prog -> String -> Maybe ([Int], [String], Core, (Int, Int), S.Set String)
soaDual prog f = soaDualCaps prog f 0

soaDualCaps :: Prog -> String -> Int -> Maybe ([Int], [String], Core, (Int, Int), S.Set String)
soaDualCaps prog f k = do
  (params, body0) <- M.lookup f prog
  [acc,el] <- Just (drop k params)
  let caps = take k params
  -- the desugarer re-lets params and the case scrutinee; peelDeep
  -- exposes projections as CProj k (CVar el) and the shape test as
  -- CTagEq tid var (CVar el)
  (body', (ks, tvs)) <- runDual el (peelDeep body0)
  tv <- case S.toList (S.fromList tvs) of
    [one] -> Just one -- exactly one shape test: the required eltid/elvar
    -- NO shape test but real column reads: projField bound each field
    -- against a UNIQUE candidate shape and emitted a bare CProj, no
    -- CTagEq -- the generic body is exactly as unchecked, so the dual
    -- may run guarded only by ncols/kinds ((-1,-1) = skip the
    -- eltid/elvar compare).  This is what un-declines NAMED record
    -- folds: their row-polymorphic bodies never carry a dispatch chain.
    [] | not (null ks) -> Just (-1, -1)
    _ -> Nothing -- conflicting shape tests: bail
  if null ks || S.size (S.fromList ks) + k + 1 > 8 + spillCells || acc == el -- accumulator/captures plus used columns, with hart spills after a7
    then Nothing
    else do
      let cols = S.toAscList (S.fromList ks)
          cvars = ["$c" ++ show k | k <- cols]
      calls <- bodyOK prog (S.fromList (caps ++ acc : cvars)) body'
      cl <- arithClosure prog (S.toList calls)
      -- The raw ABI receives separately typed accumulator and columns.
      pure () -- typePlan supplies accumulator/capture/column kinds
      Just (cols, caps ++ acc : cvars, body', tv, cl)
  where
    -- peel trivial alias-lets at every depth (not just the spine)
    peelDeep e = case peel e of
      CApp a b -> CApp (peelDeep a) (peelDeep b)
      CLet x a b -> CLet x (peelDeep a) (peelDeep b)
      CIf c t f' -> CIf (peelDeep c) (peelDeep t) (peelDeep f')
      CMk t v fs -> CMk t v (map peelDeep fs)
      CTagEq t v x -> CTagEq t v (peelDeep x)
      CProj k x -> CProj k (peelDeep x)
      e' -> e'
    runDual el = go
      where
        go (CProj k (CVar v)) | v == el = Just (CVar ("$c" ++ show k), ([k], []))
        -- a shape test on the element: statically true under the spec
        -- guard (which checks the vector's eltid/elvar), so it rewrites
        -- to True -- and RECORDS the tid/var the guard must check
        go (CTagEq t v (CVar x)) | x == el = Just (CMk 1 1 [], ([], [(t, v)]))
        go (CVar n) | n == el = Nothing -- el escapes: cannot dualize
        go e@(CVar _) = Just (e, mempty)
        go e@(CInt _) = Just (e, mempty)
        go e@(CStr _) = Just (e, mempty)
        go (CApp a b) = app2 CApp a b
        go (CLet x a b) | x /= el = app2 (CLet x) a b
        go (CIf c t f') = do (c', k1) <- go c; (t', k2) <- go t; (f'', k3) <- go f'; Just (CIf c' t' f'', k1 <> k2 <> k3)
        go (CTagEq t v e) = do (e', ks') <- go e; Just (CTagEq t v e', ks')
        go e@(CErr _) = Just (e, mempty)
        go (CMk t v fs) = do rs <- mapM go fs; Just (CMk t v (map fst rs), mconcat (map snd rs))
        go _ = Nothing
        app2 c a b = do (a', k1) <- go a; (b', k2) <- go b; Just (c a' b', k1 <> k2)

-- record FILTER dualization: a 1-ary predicate over a record element,
-- rewritten like soaDual so the loop feeds it the used columns and the
-- row is never built.  Returns (used cols, params, body, eltid/elvar,
-- closure).  Helpers taking the whole element are inlined first, so
-- `keep r = total r > 10` dualizes.
soaDualPred :: Prog -> String -> Maybe ([Int], [String], Core, (Int, Int), S.Set String)
soaDualPred prog f = do
  ([el], body0) <- M.lookup f prog
  let body1 = peelDeepC (inl (8 :: Int) (peelDeepC body0))
      inl 0 e = e
      inl d e = case spineOf e of
        (CVar h, args@(_ : _))
          | h /= f,
            Just (ps, hb) <- M.lookup h prog,
            length ps == length args,
            any (mentions el) args ->
              inl (d - 1) (peelDeepC (foldr (\(p, a) acc -> substE p a acc) hb (zip ps args)))
        _ -> case e of
          CApp a b -> CApp (inl d a) (inl d b)
          CLet x a b -> CLet x (inl d a) (inl d b)
          CIf c t e' -> CIf (inl d c) (inl d t) (inl d e')
          CTagEq t v x -> CTagEq t v (inl d x)
          CProj k x -> CProj k (inl d x)
          other -> other
      mentions v e = v `elem` freeVars e
  (body', (ks, tvs)) <- go el body1
  tv <- case S.toList (S.fromList tvs) of
    [one] -> Just one
    [] | not (null ks) -> Just (-1, -1)
    _ -> Nothing
  if null ks || S.size (S.fromList ks) > 8 + spillCells -- columns past the eighth ride the hart spill cells
    then Nothing
    else do
      let cols = S.toAscList (S.fromList ks)
          cvars = ["$c" ++ show k | k <- cols]
      calls <- bodyOK prog (S.fromList cvars) body'
      cl <- arithClosure prog (S.toList calls)
      -- a float predicate would need float column loads: not in this kernel
      if floatWidthOf prog cl /= Nothing || usesFloat body' then Nothing else Just ()
      Just (cols, cvars, body', tv, cl)
  where
    usesFloat e = case spineOf e of
      (CVar h, args) | h `elem` fPrims -> True
                     | otherwise -> any usesFloat args
      _ -> case e of
        CIf c t f' -> any usesFloat [c, t, f']
        CLet _ a b -> usesFloat a || usesFloat b
        _ -> False
    go el = g
      where
        g (CProj k (CVar v)) | v == el = Just (CVar ("$c" ++ show k), ([k], []))
        g (CTagEq t v (CVar x)) | x == el = Just (CMk 1 1 [], ([], [(t, v)]))
        g (CVar n) | n == el = Nothing -- the row escapes: cannot dualize
        g e@(CVar _) = Just (e, mempty)
        g e@(CInt _) = Just (e, mempty)
        g e@(CErr _) = Just (e, mempty)
        g (CApp a b) = app2 CApp a b
        g (CLet x a b) | x /= el = app2 (CLet x) a b
        g (CIf c t f') = do (c', k1) <- g c; (t', k2) <- g t; (f'', k3) <- g f'; Just (CIf c' t' f'', k1 <> k2 <> k3)
        g (CTagEq t v e) = do (e', ks') <- g e; Just (CTagEq t v e', ks')
        g e@(CMk 1 _ []) = Just (e, mempty) -- True / False
        g _ = Nothing
        app2 c a b = do (a', k1) <- g a; (b', k2) <- g b; Just (c a' b', k1 <> k2)

-- map-over-SoA with one captured record: dualize
--   f cap el = <inline everything> = Mk etid evar [e0..e_{n-1}]
-- into one unboxed fn PER OUTPUT FIELD whose params are the used
-- captured-record fields ($m<j>) then the used element columns
-- ($c<k>).  The loop runs IN PLACE: same shape in and out, results
-- buffered per element before the stores.
-- capture-free variant: a 1-ary record->record map runs through the
-- SAME dual with a phantom capture name nothing can reference (the
-- desugarer never emits "$"-prefixed user names), so ms comes back
-- empty for every field and the emitter's capture loads vanish.
-- a captured record's shape, when the call site constructs it: the element
-- fn's projections of the capture may be shape dispatches (another record
-- type carries the same field name), and only the capture's own arm is right
capShapeOf :: Core -> Maybe (Int, Int)
capShapeOf = \case
  CMk t v (_ : _) -> Just (t, v)
  _ -> Nothing

soaDualMap0 :: Prog -> String -> Maybe MvPlan
soaDualMap0 prog h = do
  ([el], body0) <- M.lookup h prog
  case body0 of
    -- a fuseVec composite: h el = f (g el).  Compose the two duals
    -- directly -- g's output field k IS f's input column k (records
    -- construct and project in the same sorted-field order), so f's
    -- $c_k references substitute with g's field-k dual bodies.  No
    -- normalization of the inlined mess, no emitter change.
    CApp (CVar f) (CApp (CVar g) (CVar e')) | e' == el ->
      composePlans <$> soaDualMap0 prog g <*> soaDualMap0 prog f
    _ -> soaDualMapOn prog h "$nocap" el Nothing body0

soaDualMap :: Prog -> String -> Maybe (Int, Int) -> Maybe MvPlan
soaDualMap prog h capShape = do
  ([cap, el], body0) <- M.lookup h prog
  case body0 of
    -- captured composites (one side only, by fuseVec construction):
    -- outer-captured  h c el = f c (g el)
    CApp (CApp (CVar f) (CVar c')) (CApp (CVar g) (CVar e'))
      | c' == cap, e' == el ->
          composePlans <$> soaDualMap0 prog g <*> soaDualMap prog f capShape
    -- inner-captured  h c el = f (g c el)
    CApp (CVar f) (CApp (CApp (CVar g) (CVar c')) (CVar e'))
      | c' == cap, e' == el ->
          composePlans <$> soaDualMap prog g capShape <*> soaDualMap0 prog f
    _ -> soaDualMapOn prog h cap el capShape body0

-- compose per-field duals: for each of f's output fields, replace its
-- element-column reads ($c_k) with g's field-k body.  Placeholder
-- rename first so g's own $c/$m names never collide with the ones
-- being replaced.  Exactly one side carries $m captures (fuseVec
-- skips both-captured), so the merged capture set is that side's.
composePlans :: MvPlan -> MvPlan -> MvPlan
composePlans gp fp =
  MvPlan (mvTid gp) (length fields') Nothing fields'
  where
    gduals = mvFields gp
    fields' =
      [ composed | ((fms, fks), (_, fbody)) <- mvFields fp,
        let renamed = foldr (\k b -> substE ("$c" ++ show k) (CVar ("$X" ++ show k)) b) fbody fks
            plugged = foldr plug renamed fks
            plug k b
              | k < length gduals, ((_, _), (_, gb)) <- gduals !! k =
                  substE ("$X" ++ show k) gb b
              | otherwise = substE ("$X" ++ show k) (CVar ("$c" ++ show k)) b
            ms' = S.toAscList (S.fromList (fms ++ concat [gms | k <- fks, k < length gduals, let ((gms, _), _) = gduals !! k]))
            ks' = S.toAscList (S.fromList (concat [gks | k <- fks, k < length gduals, let ((_, gks), _) = gduals !! k]))
            ps' = ["$m" ++ show j | j <- ms'] ++ ["$c" ++ show k | k <- ks']
            composed = ((ms', ks'), (ps', plugged))
      ]

soaDualMapOn :: Prog -> String -> String -> String -> Maybe (Int, Int) -> Core -> Maybe MvPlan
soaDualMapOn prog f cap el capShape body0 = do
  -- peel alias lets again AFTER inlining: a helper taking the whole
  -- element (`total r`) inlines to `let r' = el in ..`, and an unpeeled
  -- alias reads as the element escaping
  let body1 = peelDeepC (inlineSat (8 :: Int) (peelDeepC body0))
  (tv, fs) <- strip cap el Nothing body1
  let n = length fs
  if n == 0 then Nothing else Just () -- any width: cursors and results are frame slots
  duals <- mapM (dualField tv cap el) fs
  Just (MvPlan tv n Nothing duals)
  where
    inlineSat 0 e = e
    inlineSat d e = case spineOf e of
      (CVar h, args@(_ : _))
        | h /= f,
          Just (ps, hb) <- M.lookup h prog,
          length ps == length args ->
            inlineSat (d - 1) (peelDeepC (foldr (\(p, a) acc -> substE p a acc) hb (zip ps args)))
      _ -> case e of
        CApp a b -> CApp (inlineSat d a) (inlineSat d b)
        CLet x a b -> CLet x (inlineSat d a) (inlineSat d b)
        CIf c t e' -> CIf (inlineSat d c) (inlineSat d t) (inlineSat d e')
        CMk t v xs -> CMk t v (map (inlineSat d) xs)
        CTagEq t v x -> CTagEq t v (inlineSat d x)
        CProj k x -> CProj k (inlineSat d x)
        other -> other
    -- walk down to the record construction, consuming shape tests.  A
    -- shape test on the element is a DISPATCH the desugarer emits when
    -- several record shapes could be meant (`{ r | f0 = .. }` with two
    -- shapes carrying f0): the first arm is only right for vectors of
    -- that first shape.  The kernel never materializes the row, so it
    -- cannot run the dispatch; it takes the arm only when it is the sole
    -- candidate (the else branch is the error arm), and declines
    -- otherwise -- the generic tier runs bump on real rows.  Taking the
    -- first arm regardless planned a two-field kernel for a four-field
    -- vector (tests/base/vecwide.fpr, found 2026-10-03).
    strip cap el tv e = case e of
      CIf (CTagEq t v (CVar x)) th rest
        | x == el, soleCandidate rest -> strip cap el (tv `orKeep` Just (t, v)) th
        | x == el -> Nothing
        -- a dispatch on the CAPTURE: its arm when the call site built the
        -- record (capShapeOf), the sole arm otherwise, else decline
        | x == cap, Just sh <- capShape -> strip cap el tv (if (t, v) == sh then th else rest)
        | x == cap, soleCandidate rest -> strip cap el tv th
        | x == cap -> Nothing
      CLet x a b -> strip cap el tv (substE x a b)
      CMk t v fs' -> do
        (et, ev) <- tv `orKeep` Just (t, v) -- untested el: require Mk matches nothing... use Mk's own only if tested
        if (et, ev) == (t, v) then Just ((et, ev), fs') else Nothing
      _ -> Nothing
    orKeep (Just x) _ = Just x
    orKeep Nothing y = y
    soleCandidate = \case
      CErr _ -> True
      _ -> False
    dualField tv cap el e0 = do
      (e1, (ms, ks)) <- go e0
      let ms' = S.toAscList (S.fromList ms)
          ks' = S.toAscList (S.fromList ks)
          ps = ["$m" ++ show j | j <- ms'] ++ ["$c" ++ show k | k <- ks']
      if length ps > 8 + spillCells then Nothing else Just () -- args 8+ ride the hart spill cells
      _ <- bodyOK prog (S.fromList ps) e1
      Just ((ms', ks'), (ps, e1))
      where
        go e = case e of
          CProj k (CVar v)
            | v == el -> Just (CVar ("$c" ++ show k), ([], [k]))
            | v == cap -> Just (CVar ("$m" ++ show k), ([k], []))
          CVar v | v == el || v == cap -> Nothing -- escapes
          -- a shape DISPATCH on the element inside a field (`p.x` when
          -- several record shapes carry x): only the arm of the element's
          -- own shape is this kernel's; the other arms project another
          -- record's columns.  Taking the first arm regardless read a
          -- four-field record's column index on a two-field vector
          -- (found 2026-10-16: a second record type declared in the
          -- module, and the kernel read a frame slot as a cursor).
          CIf (CTagEq t v (CVar x)) th rest
            | x == el -> go (if (t, v) == tv then th else rest)
            | x == cap, Just sh <- capShape -> go (if (t, v) == sh then th else rest)
            | x == cap, soleCandidate rest -> go th
            | x == cap -> Nothing -- another record carries this field: the arm is unknown
          CTagEq t v (CVar x)
            | x == el -> Just (CMk 1 (if (t, v) == tv then 1 else 0) [], ([], []))
            | x == cap, Just sh <- capShape -> Just (CMk 1 (if (t, v) == sh then 1 else 0) [], ([], []))
            | x == cap -> Nothing
          CApp a b -> ap2 CApp a b
          CLet x a b | x /= el, x /= cap -> ap2 (CLet x) a b
          CIf c t e' -> do (c', k1) <- go c; (t', k2) <- go t; (e'', k3) <- go e'; Just (CIf c' t' e'', k1 <> k2 <> k3)
          CTagEq t v x -> do (x', ks') <- go x; Just (CTagEq t v x', ks')
          CMk {} -> Nothing -- nested construction inside a field: bail
          e'@(CVar _) -> Just (e', mempty)
          e'@(CInt _) -> Just (e', mempty)
          e'@(CStr _) -> Just (e', mempty)
          e'@(CErr _) -> Just (e', mempty)
          _ -> Nothing
        ap2 c a b = do (a', k1) <- go a; (b', k2) <- go b; Just (c a' b', k1 <> k2)

-- capture-naive expression substitution: sound here because the
-- desugarer's names are globally fresh
substE :: String -> Core -> Core -> Core
substE x v = go
  where
    go (CVar n) = if n == x then v else CVar n
    go (CApp a b) = CApp (go a) (go b)
    go (CLet n a b) = CLet n (go a) (if n == x then b else go b)
    go (CIf c t f') = CIf (go c) (go t) (go f')
    go (CMk t v' fs) = CMk t v' (map go fs)
    go (CTagEq t v' e) = CTagEq t v' (go e)
    go (CProj k e) = CProj k (go e)
    go e = e

peelDeepC :: Core -> Core
peelDeepC e = case peel e of
  CApp a b -> CApp (peelDeepC a) (peelDeepC b)
  CLet x a b -> CLet x (peelDeepC a) (peelDeepC b)
  CIf c t f' -> CIf (peelDeepC c) (peelDeepC t) (peelDeepC f')
  CMk t v fs -> CMk t v (map peelDeepC fs)
  CTagEq t v x -> CTagEq t v (peelDeepC x)
  CProj k x -> CProj k (peelDeepC x)
  e' -> e'

