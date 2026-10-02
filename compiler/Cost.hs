{-# LANGUAGE LambdaCase #-}

-- Cost.hs -- symbolic resource equations over the Core every unit is
-- generated from (docs/2026-10-02-RESOURCE-BOUNDS.md, stage 1).
--
-- Every function gets two upper bounds in its own parameters:
--
--   work  f   abstract operations: each arithmetic/compare/projection/
--             tag test, each call, each allocation is one unit
--   alloc f   bytes requested from the allocator: a constructor cell is
--             8 (header) + 8 per field, exactly what runtime/fpr.h lays
--             out; the allocator's own block preheader and rounding are
--             the target manifest's business (stage 3)
--
-- The transfer function is one case per Core construct.  Recursion is
-- bounded by the frontend's VERIFIED measures only (Safety.measureCheck):
-- a measured group costs (measure/step + 1) x the largest per-call body
-- in the group; an unmeasured recursive function is the opaque term
-- w(f) for both quantities.  A call through a function-valued PARAMETER
-- is the variable `work p` / `alloc p` until the caller supplies the
-- argument.  A primitive without a declared cost is w(prim).  Nothing is
-- guessed: every unknown stays visible in the equation.
--
-- Sizes: an Int parameter is its value; a parameter descended on
-- structurally is `len p`.  Arguments to callees substitute into the
-- callee's equation when they are linear in the caller's parameters;
-- anything else is the opaque `?`.
module Cost (Cost (..), CostEq (..), Declared (..), Verdict (..), costProgram, declaredBounds, checkBounds, checkBoundsWith, renderVerdict, substCoefs, coefsIn, resolvePrims, evalConst, omegas, prettyCost, prettyIn, renderReport, hasOmega) where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (intercalate, nub, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import Data.Ratio (denominator, numerator, (%))
import FPRISC (Core (..), Name, Prog, SExpr (..), STop (..))
import Safety (Measure (..), MeasureKind (..))

data Cost
  = CN Integer -- a constant
  | CP Name -- a parameter's value (Int) in the function under analysis
  | CLen Name -- a parameter's length (structural descent)
  | CW Name -- the work of a function-valued parameter, applied once
  | CA Name -- the alloc of a function-valued parameter, applied once
  | CO String -- opaque w(name): unverified recursion, an undeclared primitive, an unknown argument
  | CK Name -- a named coefficient in a DECLARED bound, bound by a target manifest (omega in `omega * n`)
  | CAdd [Cost]
  | CMul [Cost]
  | CMax [Cost]
  | CDivC Cost Integer -- ceiling division by a positive constant
  deriving (Eq, Ord, Show)

-- work, alloc (bytes requested), live (bytes resident at the peak: under
-- the pool model everything allocated stays until a boundary, so live is
-- alloc except inside Sys.arena and a Sys.loopWith step, which are torn
-- down), and for each persistent loop the body costs of ONE step
data CostEq = CostEq {ceWork :: Cost, ceAlloc :: Cost, ceLive :: Cost, ceSteps :: [(Cost, Cost, Cost)]} deriving (Eq, Show)

data Declared = Declared {dWork :: Maybe Cost, dAlloc :: Maybe Cost, dLive :: Maybe Cost, dSize :: Maybe Cost} deriving (Eq, Show)

--------------------------------------------------------------------------------
-- the algebra
--------------------------------------------------------------------------------

-- Bottom-up, each node once: the smart constructors below take children
-- that are ALREADY simplified and never call simp again.  (A first
-- version re-simplified subtrees at every level while distributing sums
-- into maxes, which was exponential in the nesting depth and did not
-- finish on examples/todo.fpr.)
simp :: Cost -> Cost
simp = \case
  CAdd xs -> mkAdd (map simp xs)
  CMul xs -> mkMul (map simp xs)
  CMax xs -> mkMax (map simp xs)
  CDivC e k -> mkDiv (simp e) k
  c -> c

isN :: Cost -> Bool
isN CN {} = True
isN _ = False

mkAdd :: [Cost] -> Cost
mkAdd xs
  -- a max as the only non-constant term of a sum: push the constant into
  -- the arms, so nested max(a, max(b, c) + 2) + 2 flattens to one max.
  -- Only the sole-max case: distributing several maxes multiplies arms.
  | [CMax arms] <- rest0, k /= 0 = mkMax [mkAdd [arm, CN k] | arm <- arms]
  | otherwise = case (rest, k) of
      ([], _) -> CN k
      ([r], 0) -> r
      _ -> CAdd (rest ++ [CN k | k /= 0])
  where
    ys = concatMap unAdd xs
    k = sum [n | CN n <- ys]
    rest0 = filter (not . isN) ys
    -- like terms: 3 copies of w(strcat) print as 3·w(strcat)
    coef = \case
      CMul (CN c : t) -> (c, case t of [u] -> u; _ -> CMul t)
      y -> (1, y)
    grouped = M.toList (M.fromListWith (+) [(b, c) | y <- rest0, let (c, b) = coef y])
    rest = [if c == 1 then b else CMul [CN c, b] | (b, c) <- grouped, c /= 0]
    unAdd (CAdd ys') = ys'
    unAdd y = [y]

mkMul :: [Cost] -> Cost
mkMul xs
  | k == 0 = CN 0
  | otherwise = case (rest, k) of
      ([], _) -> CN k
      ([r], 1) -> r
      _ -> CMul ([CN k | k /= 1] ++ rest)
  where
    ys = concatMap unMul xs
    k = product [n | CN n <- ys]
    rest = filter (not . isN) ys
    unMul (CMul ys') = ys'
    unMul y = [y]

mkMax :: [Cost] -> Cost
mkMax xs = case rest ++ kmax of
  [] -> CN 0
  [r] -> r
  zs -> CMax zs
  where
    ys0 = nub (sort (concatMap unMax xs))
    ks = [n | CN n <- ys0]
    -- arms that differ only in their constant keep the largest one:
    -- max(x + 44, x + 45) is x + 45
    split = \case
      CAdd zs -> (sort [z | z <- zs, not (isN z)], sum [n | CN n <- zs])
      y -> ([y], 0)
    byBase = M.toList (M.fromListWith max [split y | y <- ys0, not (isN y)])
    rest = [case (b, k) of ([t], 0) -> t; _ -> CAdd (b ++ [CN k | k /= 0]) | (b, k) <- byBase]
    -- every cost here is nonnegative, so a constant arm never wins
    -- against an arm whose own constant offset is at least as large
    kmax = [CN (maximum ks) | not (null ks), null rest || maximum ks > maximum (0 : map offset rest)]
    offset = \case
      CAdd zs -> sum [n | CN n <- zs]
      CN n -> n
      _ -> 0
    unMax (CMax ys') = ys'
    unMax y = [y]

mkDiv :: Cost -> Integer -> Cost
mkDiv e k = case e of
  CN n -> CN ((n + k - 1) `div` k)
  _ -> if k == 1 then e else CDivC e k

hasOmega :: Cost -> Bool
hasOmega = \case
  CO _ -> True
  CAdd xs -> any hasOmega xs
  CMul xs -> any hasOmega xs
  CMax xs -> any hasOmega xs
  CDivC e _ -> hasOmega e
  _ -> False

omegas :: Cost -> [String]
omegas = nub . go
  where
    go = \case
      CO s -> [s]
      CAdd xs -> concatMap go xs
      CMul xs -> concatMap go xs
      CMax xs -> concatMap go xs
      CDivC e _ -> go e
      _ -> []

-- substitute a callee's parameter symbols (value, length, work, alloc)
substC :: M.Map Name Cost -> M.Map Name Cost -> M.Map Name Cost -> M.Map Name Cost -> Cost -> Cost
substC vals lens works allocs = go
  where
    go = \case
      CP p -> M.findWithDefault (CO "?") p vals
      CLen p -> M.findWithDefault (CO "?") p lens
      CW p -> M.findWithDefault (CO "?") p works
      CA p -> M.findWithDefault (CO "?") p allocs
      CAdd xs -> CAdd (map go xs)
      CMul xs -> CMul (map go xs)
      CMax xs -> CMax (map go xs)
      CDivC e k -> CDivC (go e) k
      c -> c

-- a cost whose own parameter symbols cannot be named from here (a
-- partner in a mutual group, or a function passed as a value and applied
-- to arguments we never see): every parameter symbol becomes `?`
opaqueParams :: Cost -> Cost
opaqueParams = substC M.empty M.empty M.empty M.empty

mentionsParams :: Cost -> Bool
mentionsParams = \case
  CP _ -> True
  CLen _ -> True
  CW _ -> True
  CA _ -> True
  CAdd xs -> any mentionsParams xs
  CMul xs -> any mentionsParams xs
  CMax xs -> any mentionsParams xs
  CDivC e _ -> mentionsParams e
  _ -> False

prettyCost :: Cost -> String
prettyCost = pp . simp

pp :: Cost -> String
pp c = case c of
  CN n -> show n
  CP p -> p
  CLen p -> "len " ++ p
  CW p -> "work " ++ p
  CA p -> "alloc " ++ p
  CO s -> "ω(" ++ s ++ ")"
  CK k -> k
  CAdd xs -> intercalate " + " (map term xs)
  CMul xs -> intercalate "·" (map factor xs)
  CMax xs -> "max(" ++ intercalate ", " (map pp xs) ++ ")"
  CDivC e k -> "⌈" ++ pp e ++ "/" ++ show k ++ "⌉"
  where
    term x = case x of
      CN n | n < 0 -> "(" ++ show n ++ ")"
      _ -> pp x
    factor x = case x of
      CAdd _ -> "(" ++ pp x ++ ")"
      CN n | n < 0 -> "(" ++ show n ++ ")"
      _ -> pp x

--------------------------------------------------------------------------------
-- the pass
--------------------------------------------------------------------------------

-- primitives with a declared cost, given the LENGTHS of their arguments:
-- (work, alloc bytes).  Read off runtime/runtime.c: a string carries its
-- length (strlen, charAt are O(1)); strcat copies both and asks for
-- 16 + len a + len b (sizeof str_t + bytes); substr is bounded by its
-- source.  Anything applied that is neither a program global, a local,
-- nor here is w(name): `str` renders any value, `print` is I/O.
primCostOf :: Name -> [Cost] -> Maybe (Cost, Cost)
primCostOf g lens
  | g `elem` ["+", "-", "*", "/", "%", "<", "<=", ">", ">=", "==", "!=", "and", "or", "not", "and2", "or2", "neg"] = unit
  | g `elem` ["Word." ++ w | w <- ["fromInt", "toInt", "and", "or", "xor", "add", "sub", "not", "shl", "shr", "mask", "eq", "bitSet", "bitClear", "bitTest"]] = unit
  | g `elem` ["error", "drop"] = unit
  | g == "keep" = Just (CN 0, CN 0)
  | g `elem` ["strlen", "String.len", "charAt"] = unit
  | g == "chr" = Just (CN 1, CN 17)
  | g == "strcat", [a, b] <- lens = Just (CAdd [CN 1, a, b], CAdd [CN 16, a, b])
  | g == "substr", (a : _) <- lens = Just (CAdd [CN 1, a], CAdd [CN 16, a])
  | g == "parseInt", [a] <- lens = Just (CAdd [CN 1, a], CN 0)
  | otherwise = Nothing
  where
    unit = Just (CN 1, CN 0)

-- the cell a constructor with n fields asks the allocator for (runtime/fpr.h)
cellBytes :: Int -> Integer
cellBytes 0 = 0 -- nullary constructors are statics (fpr_true, fpr_false, fpr_unit, Nil)
cellBytes n = 8 + 8 * fromIntegral n

-- | Every function's equations, in its own Core parameter names, plus the
-- surface names to print them with (first clause's plain variables).
costProgram ::
  M.Map Name Measure -> -- Safety's verified measures, by (qualified) function name
  M.Map Name Declared -> -- declared bounds over Core parameter names
  Prog ->
  M.Map Name (CostEq, CostEq) -- (derived, effective): callers see the DECLARED bound where there is one
costProgram measures declared prog = M.mapWithKey (\n e -> (e, effective n e)) final
  where
    effective n e@(CostEq w a l _) = case M.lookup n declared of
      Just d -> e {ceWork = fromMaybe w (dWork d), ceAlloc = fromMaybe a (dAlloc d), ceLive = fromMaybe l (dLive d)}
      Nothing -> e
    -- the declared size of g's result, an assumption callers substitute
    sizeOf g = M.lookup g declared >>= dSize
    -- what a CALLER substitutes for g: its declaration if it has one
    seen done g = effective g <$> M.lookup g done
    globals = M.keysSet prog
    calleesOf body = S.toList (S.fromList [g | g <- freeGlobals body])
    freeGlobals = go S.empty
      where
        go bound = \case
          CVar v | not (S.member v bound), S.member v globals -> [v]
          CVar _ -> []
          CInt _ -> []
          CStr _ -> []
          CApp a b -> go bound a ++ go bound b
          CLam ps b -> go (bound `S.union` S.fromList ps) b
          CLet x a b -> go bound a ++ go (S.insert x bound) b
          CIf c t e -> go bound c ++ go bound t ++ go bound e
          CMk _ _ fs -> concatMap (go bound) fs
          CTagEq _ _ e -> go bound e
          CProj _ e -> go bound e
          CErr _ -> []
    sccs = stronglyConnComp [(n, n, calleesOf body) | (n, (_, body)) <- M.toList prog]
    -- callees first: stronglyConnComp returns reverse topological order
    final = foldl step M.empty sccs
    step done = \case
      AcyclicSCC n
        | selfCalls n -> recursiveGroup done [n]
        | otherwise -> M.insert n (plain done S.empty n) done
      CyclicSCC ns -> recursiveGroup done ns
    selfCalls n = n `elem` calleesOf (snd (prog M.! n))

    -- a function whose calls into `grp` cost one unit (the call-count
    -- factor is applied by the caller of this helper)
    plain done grp n =
      let (ps, body) = prog M.! n
          sub = M.fromList [(p, CP p) | p <- ps]
          R w a l steps = costE done grp (M.fromList [(p, p) | p <- ps]) sub body
       in CostEq (simp w) (simp a) (simp l) [(simp x, simp y, simp z) | (x, y, z) <- steps]

    recursiveGroup done ns =
      case mapM (\n -> (,) n <$> measureFor n) ns of
        Just ms ->
          let grp = S.fromList ns
              bodies = M.fromList [(n, plain done grp n) | n <- ns]
              perCall n =
                let CostEq w a l _ = bodies M.! n
                    partners = [bodies M.! g | g <- ns, g /= n]
                 in ( CMax (w : [opaqueParams (ceWork b) | b <- partners]),
                      CMax (a : [opaqueParams (ceAlloc b) | b <- partners]),
                      CMax (l : [opaqueParams (ceLive b) | b <- partners])
                    )
              eqFor (n, (mc, step)) =
                let calls = CAdd [CDivC mc step, CN 1]
                    (w, a, l) = perCall n
                 in (n, CostEq (simp (CMul [calls, w])) (simp (CMul [calls, a])) (simp (CMul [calls, l])) (ceSteps (bodies M.! n)))
           in foldr (\(n, e) acc -> M.insert n e acc) done (map eqFor ms)
        Nothing -> foldr (\n acc -> M.insert n (opaqueEq n) acc) done ns
    opaqueEq n = CostEq (CO n) (CO n) (CO n) []

    -- the measure as a cost over this function's CORE parameter names
    measureFor n = do
      m <- M.lookup n measures
      let (ps, _) = prog M.! n
          ren = M.fromList (zip (mParams m) ps)
          core x = M.findWithDefault x x ren
      case mKind m of
        MStructural x -> Just (CLen (core x), mStep m)
        MLinear cs k0 -> Just (CAdd ([CMul [CN c, CP (core x)] | (x, c) <- M.toList cs, c /= 0] ++ [CN k0]), mStep m)

    -- (work, alloc, live, per-step loop costs) of an expression
    costE :: M.Map Name CostEq -> S.Set Name -> M.Map Name Name -> M.Map Name Cost -> Core -> R
    costE done grp params sub = go
      where
        -- the clause lowering binds each pattern variable to its argument
        -- (`let f = a1_7`): both names stand for the parameter
        paramOf v = M.lookup v params
        zero = R (CN 0) (CN 0) (CN 0) []
        -- allocation stays in the pool: live follows alloc
        alloc w a = R w a a []
        plus (R w1 a1 l1 s1) (R w2 a2 l2 s2) = R (CAdd [w1, w2]) (CAdd [a1, a2]) (CAdd [l1, l2]) (s1 ++ s2)
        sumR = foldr plus zero
        branch (R w1 a1 l1 s1) (R w2 a2 l2 s2) = R (CMax [w1, w2]) (CMax [a1, a2]) (CMax [l1, l2]) (s1 ++ s2)
        go e = case e of
          CVar v
            | S.member v globals -> -- a global as a value: a closure cell
                let ar = length (fst (prog M.! v)) in alloc (CN 1) (CN (cellBytes (max 1 ar)))
            | otherwise -> zero
          CInt _ -> zero
          CStr _ -> zero
          CErr _ -> zero
          CLam _ b -> go b -- should not survive lifting; cost the body once
          CLet x a b ->
            let ra = go a
                sub' = M.insert x (fromMaybe (CO "?") (symOf a)) sub
                params' = case a of
                  CVar v | Just p <- paramOf v -> M.insert x p params
                  _ -> params
             in plus ra (costE done grp params' sub' b)
          CIf c t f -> plus (alloc (CN 1) (CN 0)) (plus (go c) (branch (go t) (go f)))
          CMk _ _ fs -> plus (alloc (CN 1) (CN (cellBytes (length fs)))) (sumR (map go fs))
          CTagEq _ _ x -> plus (alloc (CN 1) (CN 0)) (go x)
          CProj _ x -> plus (alloc (CN 1) (CN 0)) (go x)
          CApp {} -> app (spine e [])

        spine (CApp f a) acc = spine f (a : acc)
        spine h acc = (h, acc)

        app (h, args) =
          let rargs = sumR (map go args)
           in case h of
                CVar g
                  | S.member g grp ->
                      -- a call within the recursive group: one unit; the
                      -- call-count factor multiplies in above
                      plus (alloc (CN 1) (CN 0)) rargs
                  | S.member g globals ->
                      let (ps, _) = prog M.! g
                          ar = length ps
                          CostEq gw ga gl _ = fromMaybe (opaqueEq g) (seen done g)
                       in if length args < ar
                            then -- partial application: a closure cell, no body yet
                              plus (alloc (CN 1) (CN (cellBytes (1 + length args)))) rargs
                            else
                              let vals = M.fromList [(p, fromMaybe (CO "?") (symOf a)) | (p, a) <- zip ps args]
                                  lens = M.fromList [(p, lenOf a) | (p, a) <- zip ps args]
                                  works = M.fromList [(p, fnWork a) | (p, a) <- zip ps args]
                                  allocs = M.fromList [(p, fnAlloc a) | (p, a) <- zip ps args]
                                  inst = substC vals lens works allocs
                                  extra = length args - ar -- over-application: one apply each
                               in plus (R (CAdd [CN (1 + fromIntegral extra), inst gw]) (inst ga) (inst gl) []) rargs
                  -- Sys.arena g: g's allocations live only until the arena is
                  -- torn down; the caller's pool gets the closure and a copy
                  -- of the result (a size the pass does not know)
                  | g == "Sys.arena", [f] <- args ->
                      let fw = fnWork f
                          fa = fnAlloc f
                       in plus (R (CAdd [CN 2, fw]) (CAdd [CN 24, CO "?len"]) (CAdd [fa, CN 24, CO "?len"]) []) rargs
                  -- Sys.loopWith v s step: a PERSISTENT loop.  Its total work is
                  -- not bounded by anything in the program (it runs until the
                  -- step says stop), so it is the opaque loop; what IS bounded is
                  -- one step, reported separately.  Each step is an arena: live
                  -- is one step's allocation plus the state held at most twice.
                  | g == "Sys.loopWith", [_, _, step] <- args ->
                      let sw = fnWork step
                          sa = fnAlloc step
                       in plus (R (CO "loop:Sys.loopWith") (CO "?len") (CAdd [sa, CMul [CN 2, CO "?len"]]) [(sw, sa, sa)]) rargs
                  | Just (pw, pa) <- primCostOf g (map lenOf args) -> plus (alloc pw pa) rargs
                  | Just p <- paramOf g -> plus (R (CAdd [CN 1, CW p]) (CA p) (CA p) []) rargs
                  | otherwise -> plus (alloc (CAdd [CN 1, CO g]) (CO g)) rargs -- an undeclared primitive
                _ -> plus (go h) (plus (alloc (CAdd [CN 1, CO "?"]) (CO "?")) rargs)

        -- the Int-linear fragment of an argument, over the caller's parameters
        symOf = \case
          CInt k -> Just (CN k)
          CVar v
            | Just p <- paramOf v -> Just (CP p)
            | Just c <- M.lookup v sub, not (hasOmega c) -> Just c
          CProj i (CVar v) | Just p <- paramOf v -> Just (CP (p ++ ".#" ++ show i)) -- an Int field of a parameter
          CApp (CApp (CVar "+") a) b -> (\x y -> CAdd [x, y]) <$> symOf a <*> symOf b
          CApp (CApp (CVar "-") a) b -> (\x y -> CAdd [x, CMul [CN (-1), y]]) <$> symOf a <*> symOf b
          CApp (CApp (CVar "*") (CInt k)) b -> (\y -> CMul [CN k, y]) <$> symOf b
          CApp (CApp (CVar "*") a) (CInt k) -> (\x -> CMul [CN k, x]) <$> symOf a
          _ -> Nothing
        -- the length of an argument: a parameter's own length, or unknown
        lenOf a = case a of
          CVar v | Just p <- paramOf v -> CLen p
          CVar v | Just c <- M.lookup v sub, isSize c -> lenOfSym c -- a let-bound field of a parameter
          CProj i (CVar v) | Just p <- paramOf v -> CLen (p ++ ".#" ++ show i) -- a field of a parameter: its length
          CStr str -> CN (fromIntegral (length str))
          CMk _ _ [] -> CN 0 -- Nil
          CMk _ _ [_, rest] -> CAdd [CN 1, lenOf rest] -- a cons cell: a literal list
          _ -> case spine a [] of
            -- constructors are globals whose body is the cell: a literal
            -- list is Cons applied to an element and the rest
            (CVar c, [_, rest]) | isCon c 2 -> CAdd [CN 1, lenOf rest]
            (CVar c, []) | isCon c 0 -> CN 0
            -- a call to a function with a declared result size: substitute
            (CVar g, gargs)
              | Just sz <- sizeOf g,
                Just (ps, _) <- M.lookup g prog,
                length gargs == length ps ->
                  substC
                    (M.fromList [(p, fromMaybe (CO "?") (symOf x)) | (p, x) <- zip ps gargs])
                    (M.fromList [(p, lenOf x) | (p, x) <- zip ps gargs])
                    M.empty
                    M.empty
                    sz
            _ -> CO "?len" -- the length of a computed value (a rendered string, a built list)
        isSize = \case
          CP _ -> True
          _ -> False
        lenOfSym = \case
          CP p -> CLen p
          c -> c
        isCon c ar = case M.lookup c prog of
          Just (ps, CMk _ _ fs) -> length ps == ar && length fs == ar
          _ -> False
        -- the per-application cost of a function-valued argument
        fnWork a = case spine a [] of
          (CVar g, []) | Just p <- paramOf g -> CW p
          (CVar g, _) | S.member g globals -> opaqueParams (ceWork (fromMaybe (opaqueEq g) (seen done g)))
          _ -> CO "?"
        fnAlloc a = case spine a [] of
          (CVar g, []) | Just p <- paramOf g -> CA p
          (CVar g, _) | S.member g globals -> opaqueParams (ceAlloc (fromMaybe (opaqueEq g) (seen done g)))
          _ -> CO "?"

-- the four results of costing an expression
data R = R Cost Cost Cost [(Cost, Cost, Cost)]

-- | A cost of function n, printed in n's surface parameter names.
prettyIn :: M.Map Name [Name] -> Prog -> Name -> Cost -> String
prettyIn surfaceNames prog n c =
  let ren = M.fromList (zip (fst (M.findWithDefault ([], CErr "") n prog)) (M.findWithDefault [] n surfaceNames))
   in prettyCost (renameC ren c)

renameC :: M.Map Name Name -> Cost -> Cost
renameC ren = go
  where
    r p = let (root, path) = break (== '.') p in M.findWithDefault root root ren ++ path
    go = \case
      CP p -> CP (r p)
      CLen p -> CLen (r p)
      CW p -> CW (r p)
      CA p -> CA (r p)
      CAdd xs -> CAdd (map go xs)
      CMul xs -> CMul (map go xs)
      CMax xs -> CMax (map go xs)
      CDivC e k -> CDivC (go e) k
      c -> c

-- | The report for a set of functions: equations rendered in surface
-- parameter names, with the opaque terms each depends on.
renderReport :: M.Map Name [Name] -> Prog -> M.Map Name CostEq -> S.Set Name -> [Name] -> [String]
renderReport surfaceNames prog eqs liveDeclared names =
  concat
    [ [ pad n ++ "  work  <= " ++ prettyCost (rename w),
        pad "" ++ "  alloc <= " ++ prettyCost (rename a) ++ " bytes"
      ]
        ++ [pad "" ++ "  live  <= " ++ prettyCost (rename l) ++ " bytes" | simp l /= simp a || S.member n liveDeclared]
        ++ [pad "" ++ "  per step (Sys.loopWith): work <= " ++ prettyCost (rename sw) ++ ", alloc <= " ++ prettyCost (rename sa) ++ " bytes" | (sw, sa, _) <- steps]
        ++ [pad "" ++ "  opaque: " ++ intercalate ", " os | let os = nub (omegas w ++ omegas a ++ omegas l), not (null os)]
      | n <- names,
        Just (CostEq w a l steps) <- [M.lookup n eqs],
        let ren = M.fromList (zip (fst (M.findWithDefault ([], CErr "") n prog)) (M.findWithDefault [] n surfaceNames))
            rename = renameC ren
    ]
  where
    width = maximum (8 : map length names)
    pad s = "  " ++ s ++ replicate (width - length s) ' '

--------------------------------------------------------------------------------
-- declared bounds (stage 2)
--------------------------------------------------------------------------------

-- | The bounds written in signatures, as costs over the function's CORE
-- parameter names (surface names matched by position with the first
-- clause), plus the errors for anything a bound may not say.
declaredBounds :: S.Set Name -> M.Map Name [Name] -> Prog -> [STop] -> (M.Map Name Declared, [String])
declaredBounds coefs surface prog tops = (M.fromList [(n, b) | (n, Right b) <- converted], concat [es | (_, Left es) <- converted])
  where
    sigs = [(n, [(k, e) | Just (k, e) <- pres, k `elem` ["$work", "$alloc", "$live", "$size"]]) | TSig n _ pres <- tops]
    converted = [(n, convert n bs) | (n, bs) <- sigs, not (null bs)]
    convert n bs = case M.lookup n prog of
      Nothing -> Left [n ++ ": a resource bound on a signature with no definition is not supported yet (declare the primitive's cost in the compiler's table)"]
      Just (ps, _) ->
        let ren = M.fromList (zip (M.findWithDefault [] n surface) ps)
            one (k, e) = (,) k <$> toCost coefs n ren e
            rs = map one bs
            errs = concat [es | Left es <- rs]
            oks = [(k, c) | Right (k, c) <- rs]
            pick k = case [c | (k', c) <- oks, k' == k] of
              [] -> Nothing
              cs -> Just (simp (CMax cs)) -- several bounds of one kind: the tightest wins only if all hold; keep the max, the check below sees each
         in if null errs then Right (Declared (pick "$work") (pick "$alloc") (pick "$live") (pick "$size")) else Left errs

-- the bound language: integer literals, parameters, `len p`, `work p`,
-- `alloc p` of a function-valued parameter, +, * and max
toCost :: S.Set Name -> Name -> M.Map Name Name -> SExpr -> Either [String] Cost
toCost coefs fn ren = go
  where
    param v = case M.lookup v ren of
      Just p -> Right p
      Nothing -> Left [fn ++ ": the bound names `" ++ v ++ "`, which is not a parameter of " ++ fn ++ (if S.null coefs then " -- a named coefficient needs a target manifest (--manifest=FILE with `coefficient " ++ v ++ " <n>`)" else " nor a coefficient of the manifest (" ++ intercalate ", " (S.toList coefs) ++ ")")]
    go = \case
      SMark _ e -> go e
      SInt k -> Right (CN k)
      SVar v
        | M.member v ren -> CP <$> param v
        | S.member v coefs -> Right (CK v)
        | otherwise -> CP <$> param v
      SApp (SVar "len") (SVar v) -> CLen <$> param v
      SApp (SVar "len") (SProj (SVar v) _) -> Left [fn ++ ": `len " ++ v ++ ".field` -- the size of a record field is not yet nameable in a bound (the pass knows the field by position); bound the length as a parameter instead"]
      SApp (SVar "work") (SVar v) -> CW <$> param v
      SApp (SVar "alloc") (SVar v) -> CA <$> param v
      SBin "+" a b -> (\x y -> CAdd [x, y]) <$> go a <*> go b
      SBin "-" a b -> (\x y -> CAdd [x, CMul [CN (-1), y]]) <$> go a <*> go b
      SBin "*" a b -> (\x y -> CMul [x, y]) <$> go a <*> go b
      SApp (SApp (SVar "max") a) b -> (\x y -> CMax [x, y]) <$> go a <*> go b
      e -> Left [fn ++ ": the bound uses `" ++ take 40 (show e) ++ "`; a bound is built from integers, parameters, len p, work p, alloc p, +, -, * and max"]

data Verdict
  = Proven
  | Over String -- the monomial whose derived coefficient exceeds the declared one
  | Unproved [String] -- the opaque terms the derived cost depends on
  deriving (Eq, Show)

-- | derived <= declared, for all nonnegative values of the parameters and
-- sizes: every monomial's derived coefficient is at most the declared one.
-- A max on the derived side must hold arm by arm; a ceiling division
-- ⌈e/k⌉ is bounded by e/k + 1 (rational coefficients).
checkBounds :: Cost -> Cost -> Verdict
checkBounds = checkBoundsWith id

checkBoundsWith :: (Cost -> Cost) -> Cost -> Cost -> Verdict
checkBoundsWith rename derived declared =
  case [o | arm <- arms (simp derived), o <- omegasOf arm] of
    os@(_ : _) | not (all (`M.member` declP) (map (\o -> [CO o]) os)) -> Unproved (nub os)
    _ ->
      let declP = polyOf (simp declared)
          failing =
            [ monomial m ++ ": derived " ++ showR d ++ ", declared " ++ showR (M.findWithDefault 0 m declP)
              | arm <- arms (simp derived),
                (m, d) <- M.toList (polyOf arm),
                d > M.findWithDefault 0 m declP
            ]
       in case failing of
            [] -> Proven
            (f : _) -> Over f
  where
    declP = polyOf (simp declared)
    arms (CMax xs) = concatMap arms xs
    arms c = [c]
    omegasOf = omegas
    monomial [] = "constant"
    monomial as = intercalate "·" (map (pp . rename) as)
    showR r = if denominator r == 1 then show (numerator r) else show (numerator r) ++ "/" ++ show (denominator r)

-- a cost as a polynomial: monomial (sorted atoms) -> rational coefficient
polyOf :: Cost -> M.Map [Cost] Rational
polyOf = \case
  CN n -> M.singleton [] (fromIntegral n)
  CAdd xs -> M.unionsWith (+) (map polyOf xs)
  CMul xs -> foldr mulP (M.singleton [] 1) (map polyOf xs)
  CMax xs -> M.unionsWith max (map polyOf xs) -- an upper bound of a max: coefficient-wise max
  CDivC e k -> M.unionWith (+) (M.map (/ fromIntegral k) (polyOf e)) (M.singleton [] 1)
  atom -> M.singleton [atom] 1
  where
    mulP a b = M.fromListWith (+) [(sort (ma ++ mb), ca * cb) | (ma, ca) <- M.toList a, (mb, cb) <- M.toList b]

renderVerdict :: Verdict -> String
renderVerdict = \case
  Proven -> "PROVEN"
  Over m -> "OVER (" ++ m ++ ")"
  Unproved os -> "UNPROVED (opaque: " ++ intercalate ", " os ++ ")"

_unusedRatio :: Rational
_unusedRatio = 1 % 1

-- | A declared bound's named coefficients, bound by the manifest.
substCoefs :: M.Map Name Integer -> Cost -> Cost
substCoefs ks = go
  where
    go = \case
      CK k | Just n <- M.lookup k ks -> CN n
      CAdd xs -> CAdd (map go xs)
      CMul xs -> CMul (map go xs)
      CMax xs -> CMax (map go xs)
      CDivC e k -> CDivC (go e) k
      c -> c

coefsIn :: Cost -> [Name]
coefsIn = nub . go
  where
    go = \case
      CK k -> [k]
      CAdd xs -> concatMap go xs
      CMul xs -> concatMap go xs
      CMax xs -> concatMap go xs
      CDivC e _ -> go e
      _ -> []

-- | Opaque primitives the manifest prices: w(print) becomes a number.
resolvePrims :: (Name -> Maybe Integer) -> Cost -> Cost
resolvePrims price = go
  where
    go = \case
      CO g | Just n <- price g -> CN n
      CAdd xs -> CAdd (map go xs)
      CMul xs -> CMul (map go xs)
      CMax xs -> CMax (map go xs)
      CDivC e k -> CDivC (go e) k
      c -> c

-- | A cost with no parameters, sizes or opaque terms left: the number.
evalConst :: Cost -> Maybe Integer
evalConst c = case simp c of
  CN n -> Just n
  _ -> Nothing
