{-# LANGUAGE LambdaCase #-}
-- Codegen.Interval: difference-bound facts from dominating comparisons,
-- arithmetic steps, non-negative producers, join-block intersections, and
-- monotone loop induction parameters (docs/2026-10-26-PERFORMANCE-PLAN.md
-- step 4.4; docs/2026-11-03-BUILTIN-TYPE-SPEC-AND-INTERVAL.md).
--
-- A comparison's edge fact x - y <= c is known at every block the edge's
-- target dominates when every path there crossed the edge, or when every
-- incoming edge of an acyclic join establishes a bound on x - y.
-- Completed arithmetic steps (v = x + k, v = x - k) contribute exact
-- difference facts (v - x <= k and x - v <= -k) to strictly dominated
-- instructions and blocks without circularly justifying their own overflow
-- check. Non-negative producers (OStrLen, non-negative BAnd masks) and
-- monotone loop induction parameters supply lower and upper bounds.
module Codegen.Interval (discharge) where

import Codegen.IR
import Codegen.ControlFlow
import Data.List (foldl')
import Data.Maybe (catMaybes)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- a fact (a, b, c): a - b <= c holds
type Fact = (VId, VId, Integer)

negateCmp :: CmpOp -> CmpOp
negateCmp = \case Lt -> Ge; Le -> Gt; Gt -> Le; Ge -> Lt; Eq -> Ne; Ne -> Eq

factsOf :: CmpOp -> VId -> VId -> [Fact]
factsOf o x y = case o of
  Lt -> [(x, y, -1)]
  Le -> [(x, y, 0)]
  Gt -> [(y, x, -1)]
  Ge -> [(y, x, 0)]
  Eq -> [(x, y, 0), (y, x, 0)]
  Ne -> []

discharge :: Width -> Fn -> Fn
discharge width fn
  | not changed = fn
  | otherwise = sweep rewritten
  where
    (lo, hi) = intBounds width
    flow = analyze fn
    doms = dominators flow
    liveBlocks = reachable flow
    byId = M.fromList [(bId b, b) | b <- fnBlocks fn]
    instrs = [i | b <- fnBlocks fn, S.member (bId b) liveBlocks, i <- bInstrs b]
    rawDefs = M.fromList [(v, op) | Instr (Just (v, _)) op <- instrs]
    -- Single-edge block parameters (such as splitEntryValues copies) denote
    -- the exact value passed on that unique dominating edge.
    inEdgesMap = M.fromListWith (++)
      [ (target, [(bId b, args)])
      | b <- fnBlocks fn
      , S.member (bId b) liveBlocks
      , (target, args) <- termSuccs (bTerm b) ]
    paramAliases = M.fromList
      [ (param, arg)
      | b <- fnBlocks fn
      , bId b /= fnEntry fn
      , Just [(p, args)] <- [M.lookup (bId b) inEdgesMap]
      , p /= bId b
      , S.member p (M.findWithDefault S.empty (bId b) doms)
      , ((param, _), arg) <- zip (bParams b) args ]
    resolveParam v = case M.lookup v paramAliases of
      Just w | w /= v -> resolveParam w
      _ -> v
    -- A pure operation repeated across blocks is the same value: resolve
    -- every such definition to one representative so a comparison's fact
    -- reaches an operation whose operand was untagged or projected again.
    shareable op = case op of
      OConstInt {} -> True; ONullary {} -> True; OBits {} -> True
      OAddress {} -> True; OIndex {} -> True; OIndexByte {} -> True
      OField {} -> True; OTag {} -> True; OUntag {} -> True
      OTruth {} -> True; OBoolOf {} -> True; ONot {} -> True; OIsInt {} -> True
      OTagTest {} -> True; OVariantTest {} -> True
      OSymbol {} -> True; OFunValue {} -> True; OArithU {} -> True; OBit {} -> True; OCmp {} -> True
      _ -> False
    normOp = mapOpUses resolveParam
    reps = M.fromListWith (\a _ -> a) [(normOp op, v) | Instr (Just (v, _)) op <- instrs, shareable op]
    repOf = M.fromList [(v, r) | Instr (Just (v, _)) op <- instrs, shareable op, Just r <- [M.lookup (normOp op) reps]]
    resolve v =
      let v' = resolveParam v
       in M.findWithDefault v' v' repOf
    cmps = M.fromList [(resolve v, (o, resolve a, resolve b)) | Instr (Just (v, TPred)) (OCmp o a b) <- instrs]
    consts = M.fromList [(resolve v, n) | Instr (Just (v, TInt)) (OConstInt n) <- instrs]
    -- Direct producer bounds: constants, string byte lengths (>= 0), and
    -- bitwise AND with a non-negative constant mask (in 0..mask).
    producerBounds :: M.Map VId (Integer, Integer)
    producerBounds = M.fromListWith (\(l1, u1) (l2, u2) -> (max l1 l2, min u1 u2)) $ concat
      [ case op of
          OConstInt n -> [(resolve v, (n, n))]
          OStrLen _ -> [(resolve v, (0, hi))]
          OBit BAnd a b
            | Just m <- M.lookup (resolve b) consts, m >= 0 -> [(resolve v, (0, min hi m))]
            | Just m <- M.lookup (resolve a) consts, m >= 0 -> [(resolve v, (0, min hi m))]
          _ -> []
      | Instr (Just (v, TInt)) op <- instrs ]
    -- Difference facts established after an arithmetic instruction completes
    -- without trapping: v = x + k => v - x <= k and x - v <= -k.
    instrFacts :: Instr -> [Fact]
    instrFacts = \case
      Instr (Just (v, TInt)) (OArith o x y) -> stepFacts o v x y
      Instr (Just (v, TInt)) (OArithU o x y) -> stepFacts o v x y
      _ -> []
    stepFacts o v x y =
      let rv = resolve v; rx = resolve x; ry = resolve y
       in case o of
            Add
              | Just k <- M.lookup ry consts, rv /= rx -> [(rv, rx, k), (rx, rv, negate k)]
              | Just k <- M.lookup rx consts, rv /= ry -> [(rv, ry, k), (ry, rv, negate k)]
            Sub
              | Just k <- M.lookup ry consts, rv /= rx -> [(rv, rx, negate k), (rx, rv, k)]
            _ -> []
    blockInstrFacts :: M.Map BId [Fact]
    blockInstrFacts = M.fromList [(bId b, concatMap instrFacts (bInstrs b)) | b <- fnBlocks fn]
    edgeFacts = M.fromListWith (++)
      [ ((bId b, target), facts)
      | b <- fnBlocks fn
      , S.member (bId b) liveBlocks
      , TCondBr p yes _ no _ <- [bTerm b]
      -- A single predecessor BLOCK does not imply a single incoming EDGE:
      -- when both outcomes converge here, neither condition is established.
      , yes /= no
      , Just (o, x, y) <- [M.lookup (resolve p) cmps]
      , (target, o') <- [(yes, o), (no, negateCmp o)]
      , let facts = factsOf o' x y
      , not (null facts) ]
    -- Single-incoming-edge facts and strictly-dominating instruction facts.
    singleEdgeFacts s = case M.findWithDefault [] s inEdgesMap of
      [(p, _)] -> M.findWithDefault [] (p, s) edgeFacts
      _ -> []
    baseBlockFacts :: M.Map BId [Fact]
    baseBlockFacts = M.fromList
      [ (bid, edgeEntered ++ domInstrEntered)
      | b <- fnBlocks fn
      , let bid = bId b
      , let domSet = M.findWithDefault S.empty bid doms
      , let edgeEntered = concat [singleEdgeFacts s | s <- S.toList domSet]
      , let domInstrEntered = concat [M.findWithDefault [] s blockInstrFacts | s <- S.toList domSet, s /= bid] ]
    -- One-step transitive closure so join intersection sees chained bounds
    -- such as (i <= v1 - 1 && v1 <= n) alongside direct (i <= n - 1).
    closeOnce :: [Fact] -> [Fact]
    closeOnce fs =
      let m0 = M.fromListWith min [((a, b), c) | (a, b, c) <- fs, a /= b]
          m1 = M.fromListWith min
            [ ((a, c), k1 + k2)
            | ((a, b), k1) <- M.toList m0
            , ((b', c), k2) <- M.toList m0
            , b == b' && a /= c ]
       in [ (a, b, c) | ((a, b), c) <- M.toList (M.unionWith min m0 m1) ]
    endFactsOf p = M.findWithDefault [] p baseBlockFacts ++ M.findWithDefault [] p blockInstrFacts
    outFactsOnEdge p s = closeOnce (endFactsOf p ++ M.findWithDefault [] (p, s) edgeFacts)
    -- Multi-predecessor acyclic join facts: a bound (a - b <= c_i) established
    -- on every incoming edge to s holds with max_i c_i at s.
    joinOwnFacts :: M.Map BId [Fact]
    joinOwnFacts = M.fromList
      [ (bid, common)
      | b <- fnBlocks fn
      , let bid = bId b
      , bid /= fnEntry fn
      , let edges = M.findWithDefault [] bid inEdgesMap
      , length edges >= 2
      , all (\(p, _) -> S.notMember bid (M.findWithDefault S.empty p doms)) edges
      , let edgeMaps = [M.fromListWith min [((x, y), c) | (x, y, c) <- outFactsOnEdge p bid] | (p, _) <- edges]
      , let common = case edgeMaps of
              m : ms -> [(x, y, c) | ((x, y), c) <- M.toList (foldl' (M.intersectionWith max) m ms)]
              [] -> [] ]
    preLoopFacts :: M.Map BId [Fact]
    preLoopFacts = M.fromList
      [ (bid, M.findWithDefault [] bid baseBlockFacts ++ concat [M.findWithDefault [] s joinOwnFacts | s <- S.toList (M.findWithDefault S.empty bid doms)])
      | b <- fnBlocks fn, let bid = bId b ]
    -- Bounds under a given fact set and optional extra lower/upper maps.
    ubWith extraUB fs = go S.empty
      where
        go seen x = minimum' (catMaybes (direct : extra : Just hi : map step toward))
          where
            direct = snd <$> M.lookup x producerBounds
            extra = M.lookup x extraUB
            toward = [(v, c) | (a, v, c) <- fs, a == x]
            step (v, c) = if S.member v seen then Nothing else (+ c) <$> go (S.insert x seen) v
    lbWith extraLB fs = go S.empty
      where
        go seen x = maximum' (catMaybes (direct : extra : Just lo : map step toward))
          where
            direct = fst <$> M.lookup x producerBounds
            extra = M.lookup x extraLB
            toward = [(v, c) | (v, b, c) <- fs, b == x]
            step (v, c) = if S.member v seen then Nothing else subtract c <$> go (S.insert x seen) v
    minimum' xs = if null xs then Nothing else Just (minimum xs)
    maximum' xs = if null xs then Nothing else Just (maximum xs)
    diffUBWith extraLB extraUB fs a b =
      minimum' (catMaybes (walk S.empty a : [Just (u - l) | Just u <- [ubWith extraUB fs a], Just l <- [lbWith extraLB fs b]]))
      where
        walk seen x
          | x == b = Just 0
          | S.member x seen = Nothing
          | otherwise = minimum' [c + d | (src, dst, c) <- fs, src == x, Just d <- [walk (S.insert x seen) dst]]
    leq :: Maybe Integer -> Integer -> Bool
    leq (Just n) c = n <= c
    leq Nothing _ = False
    -- Natural-loop / self-loop monotone induction bounds at header h:
    -- when every back-edge step is non-decreasing (r >= u), u >= entry arg;
    -- when every back-edge step is non-increasing (r <= u), u <= entry arg.
    loopHeaderResults :: M.Map BId ([Fact], M.Map VId Integer, M.Map VId Integer)
    loopHeaderResults = M.fromList
      [ (hid, (concat fss, M.unions lbs, M.unions ubs))
      | h <- fnBlocks fn
      , let hid = bId h
      , hid /= fnEntry fn
      , S.member hid liveBlocks
      , let edges = M.findWithDefault [] hid inEdgesMap
      , let (backEdges, entryEdges) = spanPartition (\(p, _) -> S.member hid (M.findWithDefault S.empty p doms)) edges
      , not (null backEdges) && not (null entryEdges)
      , let results = [inductParam h entryEdges backEdges idx param | (idx, param) <- zip [0 ..] (bParams h)]
      , let fss = [f | (f, _, _) <- results]
      , let lbs = [l | (_, l, _) <- results]
      , let ubs = [u | (_, _, u) <- results] ]
    spanPartition p xs = ([x | x <- xs, p x], [x | x <- xs, not (p x)])
    inductParam h entryEdges backEdges idx (param, paramTy) = case loopIntVar of
      Nothing -> ([], M.empty, M.empty)
      Just u ->
        let backInts = [(latch, argInt u (args !! idx)) | (latch, args) <- backEdges]
            entryInts = [(e, argInt u (args !! idx)) | (e, args) <- entryEdges]
            latchFacts l = M.findWithDefault [] l preLoopFacts ++ M.findWithDefault [] l blockInstrFacts
            nonDecreasing = all (\(l, mr) -> case mr of
              Just r -> r == u || leq (diffUBWith M.empty M.empty (latchFacts l) u r) 0
              Nothing -> False) backInts
            nonIncreasing = all (\(l, mr) -> case mr of
              Just r -> r == u || leq (diffUBWith M.empty M.empty (latchFacts l) r u) 0
              Nothing -> False) backInts
            relLB = case entryInts of
              [(_, Just a0)] | nonDecreasing && a0 /= u -> [(a0, u, 0)]
              _ -> []
            relUB = case entryInts of
              [(_, Just a0)] | nonIncreasing && a0 /= u -> [(u, a0, 0)]
              _ -> []
            entryLBs = [l | (e, Just ae) <- entryInts, Just l <- [lbWith M.empty (outFactsOnEdge e (bId h)) ae]]
            entryUBs = [u' | (e, Just ae) <- entryInts, Just u' <- [ubWith M.empty (outFactsOnEdge e (bId h)) ae]]
            extraLB = if nonDecreasing && length entryLBs == length entryInts
                        then M.singleton u (minimum entryLBs) else M.empty
            extraUB = if nonIncreasing && length entryUBs == length entryInts
                        then M.singleton u (maximum entryUBs) else M.empty
         in (relLB ++ relUB, extraLB, extraUB)
      where
        loopIntVar = case paramTy of
          TInt -> Just (resolve param)
          TVal -> case [resolve w | Instr (Just (w, TInt)) (OUntag p') <- bInstrs h, p' == param] of
            w : _ -> Just w
            [] -> Nothing
          _ -> Nothing
        argInt u arg = case paramTy of
          TInt -> Just (resolve arg)
          TVal
            | arg == param -> Just u
            | Just (OTag x) <- M.lookup arg rawDefs -> Just (resolve x)
            | otherwise -> Nothing
          _ -> Nothing
    blockFacts :: M.Map BId ([Fact], M.Map VId Integer, M.Map VId Integer)
    blockFacts = M.fromList
      [ (bid, (base ++ loopFs, loopLB, loopUB))
      | b <- fnBlocks fn
      , let bid = bId b
      , let domSet = M.findWithDefault S.empty bid doms
      , let base = M.findWithDefault [] bid preLoopFacts
      , let loopFs = concat [fs | s <- S.toList domSet, Just (fs, _, _) <- [M.lookup s loopHeaderResults]]
      , let loopLB = M.unionsWith max [l | s <- S.toList domSet, Just (_, l, _) <- [M.lookup s loopHeaderResults]]
      , let loopUB = M.unionsWith min [u | s <- S.toList domSet, Just (_, _, u) <- [M.lookup s loopHeaderResults]] ]
    factsAt d = M.findWithDefault ([], M.empty, M.empty) d blockFacts
    cmpHolds extraLB extraUB fs o a b = case o of
      Lt -> leq (diffUBWith extraLB extraUB fs (resolve a) (resolve b)) (-1)
      Le -> leq (diffUBWith extraLB extraUB fs (resolve a) (resolve b)) 0
      Gt -> leq (diffUBWith extraLB extraUB fs (resolve b) (resolve a)) (-1)
      Ge -> leq (diffUBWith extraLB extraUB fs (resolve b) (resolve a)) 0
      Eq -> leq (diffUBWith extraLB extraUB fs (resolve a) (resolve b)) 0
         && leq (diffUBWith extraLB extraUB fs (resolve b) (resolve a)) 0
      Ne -> leq (diffUBWith extraLB extraUB fs (resolve a) (resolve b)) (-1)
         || leq (diffUBWith extraLB extraUB fs (resolve b) (resolve a)) (-1)
    -- the no-overflow proof for x + k / x - k: one side is the domain's,
    -- the other must come from the facts
    fitsAdd extraLB extraUB fs x k
      | k > 0 = maybe False (\u -> u + k <= hi) (ubWith extraUB fs x)
      | k < 0 = maybe False (\l -> l + k >= lo) (lbWith extraLB fs x)
      | otherwise = True
    arithProof extraLB extraUB fs o x y = case o of
      Add -> case (M.lookup (resolve x) consts, M.lookup (resolve y) consts) of
        (_, Just k) -> fitsAdd extraLB extraUB fs (resolve x) k
        (Just k, _) -> fitsAdd extraLB extraUB fs (resolve y) k
        _ -> False
      Sub | Just k <- M.lookup (resolve y) consts -> fitsAdd extraLB extraUB fs (resolve x) (negate k)
      _ -> False
    -- Walk instructions top-down so a checked arithmetic instruction is
    -- proven only from facts established BEFORE it, then contributes its
    -- post-fact (v = x +/- k) to subsequent instructions and the terminator.
    rewrite b = (bInstrs' /= bInstrs b || term' /= bTerm b, b {bInstrs = bInstrs', bTerm = term'})
      where
        (fs0, extraLB, extraUB) = factsAt (bId b)
        (fsEnd, revInstrs) = foldl' stepInstr (fs0, []) (bInstrs b)
        bInstrs' = reverse revInstrs
        stepInstr (fs, acc) i =
          let i' = case i of
                Instr (Just (v, TInt)) (OArith o x y)
                  | o `elem` [Add, Sub], arithProof extraLB extraUB fs o x y ->
                      Instr (Just (v, TInt)) (OArithU o x y)
                _ -> i
           in (fs ++ instrFacts i', i' : acc)
        term' = case bTerm b of
          TCondBr p yes ys no ns
            | Just (o, a, b') <- M.lookup (resolve p) cmps
            , cmpHolds extraLB extraUB fsEnd o a b' -> TBr yes ys
            | Just (o, a, b') <- M.lookup (resolve p) cmps
            , cmpHolds extraLB extraUB fsEnd (negateCmp o) a b' -> TBr no ns
          t -> t
    results = map rewrite (fnBlocks fn)
    changed = any fst results
    rewritten = fn {fnBlocks = map snd results}
    -- threading a branch can orphan its untaken arm's blocks
    sweep f =
      let live = reachable (analyze f)
          kept = [b | b <- fnBlocks f, S.member (bId b) live]
       in if length kept == length (fnBlocks f) then f else sweep f {fnBlocks = kept}
