{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

-- Sol/JitCore.hs -- the backend-independent half of the JIT tier:
-- which Core bodies are compilable (the pure arithmetic fragment), the
-- closure gather + join-point saturation, and the Julia-style per-
-- callsite type inference (JI exact int / JD inexact f64 / JW
-- ambiguous / JB bottom).  Nothing here knows how code is emitted; the
-- hand-rolled backends (Sol/HandJIT.hs, Sol/KIR.hs) consume the typed
-- closure this module produces.  It was carved out of the former
-- LLVM tier verbatim so the accepted fragment and the typing rules are
-- unchanged by the backend swap.
module Sol.JitCore
  ( JTy (..), VKey, joinT, promoT, tyChar, isF, numPrims,
    simpCore, gatherFns, jitOK, jitOKVec, satJoins, prepClosure, checkAll,
    tyExpr, tyExprV, inferSigs, splitMkR,
  ) where

import qualified Sol.Bytecode as B
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Sol.Lang (Core (..), Name, Prog)

-- JB is the inference-only bottom: the type of an in-flight recursive
-- return before the fixpoint converges (and of code that never returns).
-- It is the identity for joins and promotions, so optimistic iteration
-- reaches the LEAST fixed point -- without it, a recursive call would
-- poison `join` into JW and stick there.
data JTy = JB | JI | JD | JW deriving (Eq, Show, Ord)

joinT :: JTy -> JTy -> JTy
joinT a b | a == b = a
joinT JB t = t
joinT t JB = t
joinT _ _ = JW

tyChar :: JTy -> Char
tyChar JB = '_'
tyChar JI = 'i'
tyChar JD = 'd'
tyChar JW = 'w'

isF :: JTy -> Bool
isF t = t == JD || t == JW

-- the Numeric HAL prims the typed tier compiles as LLVM intrinsics:
-- (name, arity, arg promotion target, result type)
numPrims :: M.Map Name (Int, JTy)
numPrims =
  M.fromList
    [ ("Num.div", (2, JD)), -- fdiv, always inexact
      ("Num.sqrt", (1, JD)), -- llvm.sqrt.f64
      ("Num.floor", (1, JI)), -- llvm.floor.f64 + fptosi
      ("Num.round", (1, JI)) -- llvm.rint.f64 (nearest-even = Haskell round) + fptosi
    ]

-- ---- JITtability: arithmetic-only Core, closed over other such fns --------

-- Exhaustive bool matches desugar as
--   CIf (CTagEq bool True s) a (CIf (CTagEq bool False s) b (CErr "no match"))
-- The CErr tail is unreachable: when the inner CIf runs, the outer test already failed, so the complementary test must hold. Strip it, so `case c of True -> a | False -> b` is JITtable. Non-bool case tails (reachable) keep their CErr and stay interpreter-only.
simpCore :: Core -> Core
simpCore = go
  where
    go = \case
      CIf (CTagEq 1 v s) t (CErr _) -> go t `seq` goIf v s t
      CIf c t e -> CIf (go c) (go t) (go e)
      CApp a b -> CApp (go a) (go b)
      CLet x a b -> CLet x (go a) (go b)
      CMk t v fs -> CMk t v (map go fs)
      CTagEq t v e -> CTagEq t v (go e)
      CProj i e -> CProj i (go e)
      CLam ps e -> CLam ps (go e)
      other -> other
    goIf _ _ t = go t

-- transitive closure of top-level functions called from `root`
gatherFns :: Prog -> Name -> Maybe (M.Map Name ([Name], Core))
gatherFns prog root = go M.empty [root]
  where
    go acc [] = Just acc
    go acc (n : rest)
      | M.member n acc = go acc rest
      | otherwise = case M.lookup n prog of
          Nothing -> Nothing
          Just (ps, b) -> go (M.insert n (ps, b) acc) (rest ++ calledFns ps b)
    calledFns ps b = nub [g | g <- callsIn b, g `notElem` ps, M.member g prog]
    callsIn = \case
      CVar v -> [v]
      CApp a b -> callsIn a ++ callsIn b
      CLet x a b -> callsIn a ++ filter (/= x) (callsIn b)
      CIf c t e -> callsIn c ++ callsIn t ++ callsIn e
      CMk _ _ fs -> concatMap callsIn fs
      CTagEq _ _ e -> callsIn e
      CProj _ e -> callsIn e
      CLam ps e -> filter (`notElem` ps) (callsIn e)
      _ -> []

-- can this Core body run as pure i64 arithmetic?
jitOK :: M.Map Name Int -> [Name] -> Core -> Bool
jitOK fnAr = ok
  where
    ok locals = \case
      CInt _ -> True
      -- a refusal by name inside a kernel: compiles to a TRAP (the fuel
      -- cell is poisoned and the VM panics on return), so guards that
      -- `error` out no longer demote the whole scheme to the interpreter
      CApp (CVar "error") (CStr _) -> True
      CVar v -> v `elem` locals || M.lookup v fnAr == Just 0
      CLet x a b -> ok locals a && ok (x : locals) b
      CIf c t e -> ok locals c && ok locals t && ok locals e
      CTagEq 1 v e | v <= 1 -> ok locals e -- bool test: (e != 0) / (e == 0)
      e@CApp {} ->
        let (h, args) = B.spine e
         in case h of
              CVar g
                -- float-literal splices: the parser's exact shape only
                | g == "f64frombits", [CInt _, CInt _] <- args -> True
                | g == "f32frombits", [CInt _] <- args -> True
                | g `notElem` locals, M.member g B.arithOps, length args == 2 -> all (ok locals) args
                | g `notElem` locals, Just (npAr, _) <- M.lookup g numPrims, npAr == length args -> all (ok locals) args
                | g `notElem` locals, Just ar <- M.lookup g fnAr, ar == length args -> all (ok locals) args
              _ -> False
      _ -> False -- strings, data construction, lambdas, errors: interpreter's job

-- clause compilation introduces JOIN POINTS: `CLet j (f a1 .. ak) body`
-- binds a PARTIAL application that later saturates as `j extra..` — the
-- guard-fallback shape. The JIT has no closures, but when every use of j
-- saturates f, the binding inlines away into direct saturated calls.
-- Compiler-generated argument names are unique, so substitution is
-- capture-safe here.
satJoins :: M.Map Name Int -> Core -> Core
satJoins fnAr = go S.empty
  where
    go bs e = case e of
      CLet x a b
        | (CVar g, as) <- B.spine a,
          not (S.member g bs),
          Just ar <- M.lookup g fnAr,
          ar > length as,
          let miss = ar - length as,
          satOnly x miss b ->
            go bs (inline x (foldl CApp (CVar g) (map (go bs) as)) miss b)
      CLet x a b -> CLet x (go bs a) (go (S.insert x bs) b)
      ap@CApp {} ->
        let (h, as) = B.spine ap
         in foldl CApp (go bs h) (map (go bs) as)
      CIf c t el -> CIf (go bs c) (go bs t) (go bs el)
      CMk t v fs -> CMk t v (map (go bs) fs)
      CTagEq t v s -> CTagEq t v (go bs s)
      CProj i s -> CProj i (go bs s)
      CLam ps b -> CLam ps (go (foldr S.insert bs ps) b)
      other -> other
    -- every occurrence of x is the head of a spine with exactly `miss` args
    satOnly x miss = chk
      where
        chk = \case
          CVar v -> v /= x
          ap@CApp {} ->
            let (h, as) = B.spine ap
             in (case h of CVar v | v == x -> length as == miss; _ -> chk h) && all chk as
          CLet y a b -> chk a && (y == x || chk b)
          CIf c t el -> chk c && chk t && chk el
          CMk _ _ fs -> all chk fs
          CTagEq _ _ s -> chk s
          CProj _ s -> chk s
          CLam ps b -> x `elem` ps || chk b
          _ -> True
    inline x a miss = rw
      where
        rw = \case
          ap@CApp {} ->
            let (h, as) = B.spine ap
             in case h of
                  CVar v | v == x, length as == miss -> foldl CApp a (map rw as)
                  _ -> foldl CApp (rw h) (map rw as)
          CLet y r b -> CLet y (rw r) (if y == x then b else rw b)
          CIf c t el -> CIf (rw c) (rw t) (rw el)
          CMk t v fs -> CMk t v (map rw fs)
          CTagEq t v s -> CTagEq t v (rw s)
          CProj i s -> CProj i (rw s)
          CLam ps b -> CLam ps (if x `elem` ps then b else rw b)
          other -> other

-- simplify + saturate the whole closure (arities come from the closure itself)
prepClosure :: M.Map Name ([Name], Core) -> M.Map Name ([Name], Core)
prepClosure cl =
  let ars = M.map (length . fst) cl
   in M.map (fmap (satJoins ars . simpCore)) cl

checkAll :: M.Map Name ([Name], Core) -> Maybe (M.Map Name ([Name], Core))
checkAll cl =
  let ars = M.map (length . fst) cl
   in if all (uncurry (jitOK ars)) (M.elems cl) then Just cl else Nothing

-- ---- type inference (the "Julia-style" pass) --------------------------------
--
-- Per-CALLSITE specialization: a helper called with (JD, JI) and with
-- (JI, JI) becomes two LLVM functions. Variants are keyed by argument
-- types; return types live in a table iterated to a fixpoint (missing
-- entries read as JI — the optimistic bottom — and the recomputation is
-- capped, bailing on the pathological case). Inference returns Nothing
-- when a construct can't be compiled faithfully: `/` over int-ambiguous
-- (JW) operands, or a non-JI value in a boolean position.

type VKey = (Name, [JTy])

-- arithmetic result type: JD is contagious and definite; JW is contagious
-- and ambiguous; JI only survives a pure-int pair. NOT joinT: JD+JI is
-- definitely inexact (JD), while joinT would say "either" (JW).
promoT :: JTy -> JTy -> JTy
promoT JB t = t
promoT t JB = t
promoT a b
  | a == JD || b == JD = JD
  | a == JW || b == JW = JW
  | otherwise = JI

-- type one Core body; collects demanded callee variants
tyExpr :: M.Map VKey JTy -> M.Map Name ([Name], Core) -> M.Map Name JTy -> Core -> Maybe (JTy, [VKey])
tyExpr sigs cl = goT
  where
    goT env e = case e of
      CInt _ -> Just (JI, [])
      CApp (CVar "error") (CStr _) -> Just (JB, []) -- bottom: joins with anything
      CVar v -> case M.lookup v env of
        Just t -> Just (t, [])
        Nothing
          | M.member v cl -> Just (M.findWithDefault JB (v, []) sigs, [(v, [])])
          | otherwise -> Nothing
      CLet x a b -> do
        (ta, d1) <- goT env a
        (tb, d2) <- goT (M.insert x ta env) b
        pure (tb, d1 ++ d2)
      CIf c t e2 -> do
        (tc, d0) <- goT env c
        if isF tc
          then Nothing -- a non-int in boolean position: interpreter's job
          else do
            (tt, d1) <- goT env t
            (te, d2) <- goT env e2
            pure (joinT tt te, d0 ++ d1 ++ d2)
      CTagEq 1 _ s -> do
        (ts, d) <- goT env s
        if isF ts then Nothing else pure (JI, d)
      ap@CApp {} ->
        let (h, args) = B.spine ap
         in case h of
              CVar g
                -- the shared grammar's float-literal splices: a JD constant
                -- in the typed tier (so a literal in a hot fn does NOT
                -- demote it to the interpreter).  Literal halves only --
                -- the parser is the sole producer; anything else bails.
                | g == "f64frombits", [CInt _, CInt _] <- args,
                  not (M.member g env) -> Just (JD, [])
                | g == "f32frombits", [CInt _] <- args,
                  not (M.member g env) -> Just (JD, [])
                | Just op <- M.lookup g B.arithOps,
                  [x, y] <- args,
                  not (M.member g env) -> do
                    (tx, d1) <- goT env x
                    (ty, d2) <- goT env y
                    rt <- arithTy op tx ty
                    pure (rt, d1 ++ d2)
                | Just (_, ret) <- M.lookup g numPrims,
                  not (M.member g env) -> do
                    ds <- mapM (goT env) args
                    pure (ret, concatMap snd ds)
                | not (M.member g env),
                  M.member g cl -> do
                    ds <- mapM (goT env) args
                    let ats = map fst ds
                        k = (g, ats)
                    pure (M.findWithDefault JB k sigs, k : concatMap snd ds)
              _ -> Nothing
      _ -> Nothing

    arithTy op tx ty = case op of
      B.ODiv -> case promoT tx ty of
        JW -> Nothing -- quot or true division? undecidable: bail
        t -> Just t
      B.OAdd -> Just (promoT tx ty)
      B.OSub -> Just (promoT tx ty)
      B.OMul -> Just (promoT tx ty)
      _ -> Just JI -- comparisons reify as i64 bools

-- like tyExpr, but the root of a vec dual: the element param (and its
-- let-aliases) types by COLUMN KIND — CProj k -> colTys !! k
tyExprV :: M.Map VKey JTy -> M.Map Name ([Name], Core) -> Bool -> [JTy] -> S.Set Name -> M.Map Name JTy -> Core -> Maybe (JTy, [VKey])
tyExprV sigs cl scalar colTys es0 env0 e0 = goV es0 env0 e0
  where
    goV es env e = case e of
      CApp (CVar "error") (CStr _) -> Just (JB, [])
      CVar v | S.member v es -> if scalar then Just (head colTys, []) else Nothing
      CProj k (CVar v) | S.member v es -> Just (colTys !! k, [])
      CLet x (CVar v) b | S.member v es -> goV (S.insert x es) env b
      CLet x a b -> do
        (ta, d1) <- goV es env a
        (tb, d2) <- goV (S.delete x es) (M.insert x ta env) b
        pure (tb, d1 ++ d2)
      CIf c t e2 -> do
        (tc, d0) <- goV es env c
        if isF tc
          then Nothing
          else do
            (tt, d1) <- goV es env t
            (te, d2) <- goV es env e2
            pure (joinT tt te, d0 ++ d1 ++ d2)
      CTagEq 1 _ s -> do
        (ts, d) <- goV es env s
        if isF ts then Nothing else pure (JI, d)
      ap@CApp {} ->
        let (h, args) = B.spine ap
         in case h of
              CVar g
                -- the shared grammar's float-literal splices: a JD constant
                -- in the typed tier (so a literal in a hot fn does NOT
                -- demote it to the interpreter).  Literal halves only --
                -- the parser is the sole producer; anything else bails.
                | g == "f64frombits", [CInt _, CInt _] <- args,
                  not (M.member g env) -> Just (JD, [])
                | g == "f32frombits", [CInt _] <- args,
                  not (M.member g env) -> Just (JD, [])
                | Just op <- M.lookup g B.arithOps,
                  [x, y] <- args,
                  not (M.member g env),
                  not (S.member g es) -> do
                    (tx, d1) <- goV es env x
                    (ty, d2) <- goV es env y
                    rt <- arithTyV op tx ty
                    pure (rt, d1 ++ d2)
                | Just (_, ret) <- M.lookup g numPrims,
                  not (M.member g env),
                  not (S.member g es) -> do
                    ds <- mapM (goV es env) args
                    pure (ret, concatMap snd ds)
                | not (M.member g env),
                  not (S.member g es),
                  M.member g cl -> do
                    ds <- mapM (goV es env) args
                    let ats = map fst ds
                        k = (g, ats)
                    pure (M.findWithDefault JB k sigs, k : concatMap snd ds)
              _ -> Nothing
      -- delegate the shared leaves
      _ -> tyExpr sigs cl env e
    arithTyV op tx ty = case op of
      B.ODiv -> case promoT tx ty of JW -> Nothing; t -> Just t
      B.OAdd -> Just (promoT tx ty)
      B.OSub -> Just (promoT tx ty)
      B.OMul -> Just (promoT tx ty)
      _ -> Just JI

-- fixpoint over all demanded HELPER variants, seeded by the root body's
-- demands. rootTy types the root itself (list roots use tyExpr; vec roots
-- use tyExprV via the closure passed in).
inferSigs :: M.Map Name ([Name], Core) -> (M.Map VKey JTy -> Maybe (JTy, [VKey])) -> Maybe (M.Map VKey JTy, JTy)
inferSigs cl rootTy = go 0 M.empty
  where
    go :: Int -> M.Map VKey JTy -> Maybe (M.Map VKey JTy, JTy)
    go round sigs
      | round > 32 = Nothing -- non-converging (shouldn't happen); bail
      | otherwise = do
          (rt, rdemands) <- rootTy sigs
          -- EVERY known variant re-settles each round: a depth>=2 variant
          -- whose callees refined must recompute (and may demand NEW
          -- variants as its argument types sharpen)
          (sigs', changed) <- settle sigs (nub (rdemands ++ M.keys sigs)) False
          if changed then go (round + 1) sigs' else pure (sigs', rt)
    -- process a worklist of variants: (re)type each, recording changes and
    -- newly demanded variants
    settle sigs [] changed = Just (sigs, changed)
    settle sigs (k@(n, ats) : rest) changed = do
      (ps, body) <- M.lookup n cl
      if length ps /= length ats
        then Nothing
        else do
          (rt, ds) <- tyExpr sigs cl (M.fromList (zip ps ats)) body
          let old = M.findWithDefault JB k sigs
              sigs' = M.insert k rt sigs
              newKs = [d | d <- nub ds, not (M.member d sigs')]
          settle (M.insert k rt sigs') (rest ++ newKs) (changed || rt /= old || not (M.member k sigs))

-- can this body run as a dual over the given layout? The elem param — or any
-- let-alias of it (the clause compiler rebinds params: CLet p (CVar a1_k)) —
-- may ONLY appear as CProj onto an UNBOXED column (i64/f64 SoA) or bare
-- (scalar unboxed).
jitOKVec :: M.Map Name Int -> Bool -> [Bool] -> Name -> [Name] -> Core -> Bool
jitOKVec fnAr scalar loadable elemP0 locals0 = ok (S.singleton elemP0) locals0
  where
    ok es locals = \case
      CInt _ -> True
      CApp (CVar "error") (CStr _) -> True
      CVar v | S.member v es -> scalar && loadable == [True]
      CVar v -> v `elem` locals || M.lookup v fnAr == Just 0
      CProj k (CVar v) | S.member v es -> not scalar && k < length loadable && loadable !! k
      CLet x (CVar v) b | S.member v es -> ok (S.insert x es) locals b -- alias
      CLet x a b -> ok es locals a && ok (S.delete x es) (x : locals) b
      CIf c t e -> ok es locals c && ok es locals t && ok es locals e
      CTagEq 1 v e | v <= 1 -> ok es locals e -- bool test as int compare
      e@CApp {} ->
        let (h, args) = B.spine e
         in case h of
              CVar g
                -- float-literal splices: admissible in exactly the shape
                -- the parser emits (typed JD, emitted as an f64 constant)
                | g == "f64frombits", [CInt _, CInt _] <- args -> True
                | g == "f32frombits", [CInt _] <- args -> True
                | not (S.member g es), g `notElem` locals, M.member g B.arithOps, length args == 2 -> all (ok es locals) args
                | not (S.member g es), g `notElem` locals, Just (npAr, _) <- M.lookup g numPrims, npAr == length args -> all (ok es locals) args
                | not (S.member g es), g `notElem` locals, Just ar <- M.lookup g fnAr, ar == length args -> all (ok es locals) args
              _ -> False
      _ -> False

splitMkR :: Core -> Maybe ([(Name, Core)], Int, Int, [Core])
splitMkR = go []
  where
    go acc (CLet x v b) = go ((x, v) : acc) b
    go acc (CMk t v fs) | not (null fs) = Just (reverse acc, t, v, fs)
    go _ _ = Nothing
