{-# LANGUAGE LambdaCase #-}
-- Codegen.Interval: difference-bound facts from dominating comparisons
-- (docs/2026-10-26-PERFORMANCE-PLAN.md step 4.4). A comparison's edge
-- fact x - y <= c is known at every block the edge's target dominates,
-- when the target has no other predecessor: every path there crossed
-- the edge. Together with the domain bounds of TInt (every value fits
-- its width), one fact discharges real checks:
--
--   * `i < n` dominating `i + 1`: i <= n - 1 <= maxInt - 1, so the add
--     cannot overflow — OArith becomes OArithU and the fit check (and
--     its slow path) leaves the loop;
--   * a guard whose predicate a dominating comparison already decides
--     (an inline read's bounds test under a dominating range test, a
--     constant index) is threaded to its taken arm, its fallback
--     becoming unreachable.
--
-- Every removal is a proof in this domain, not a pattern: the rewriter
-- only fires on a derived bound, and the result re-verifies like every
-- Simplify pass. What the domain cannot see it keeps: accumulator adds
-- (no bound), indices not related to a length by a dominating guard,
-- and the initial values of a recursive function's parameters (a
-- caller's facts are the precondition checker's, compiler/Precond.hs).
module Codegen.Interval (discharge) where

import Codegen.IR
import Codegen.ControlFlow
import Data.Maybe (catMaybes)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- a fact (a, b, c): a - b <= c holds at the block entry
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
    instrs = [i | b <- fnBlocks fn, i <- bInstrs b]
    -- a pure operation repeated across blocks is the same value
    -- (share-pure-in-block stops at the block edge): resolve every such
    -- definition to one representative so a comparison's fact reaches an
    -- add whose operand was untagged again in a later block
    shareable op = case op of
      OConstInt {} -> True; ONullary {} -> True; OBits {} -> True
      OAddress {} -> True; OIndex {} -> True; OIndexByte {} -> True
      OTag {} -> True; OUntag {} -> True; OBoolOf {} -> True; ONot {} -> True; OIsInt {} -> True
      OSymbol {} -> True; OFunValue {} -> True; OBit {} -> True; OCmp {} -> True
      _ -> False
    reps = M.fromListWith (\a _ -> a) [(op, v) | Instr (Just (v, _)) op <- instrs, shareable op]
    repOf = M.fromList [(v, r) | Instr (Just (v, _)) op <- instrs, shareable op, Just r <- [M.lookup op reps]]
    resolve v = M.findWithDefault v v repOf
    cmps = M.fromList [(resolve v, (o, resolve a, resolve b)) | Instr (Just (v, TPred)) (OCmp o a b) <- instrs]
    consts = M.fromList [(resolve v, n) | Instr (Just (v, TInt)) (OConstInt n) <- instrs]
    flow = analyze fn
    doms = dominators flow
    singlePred s = case S.toList (M.findWithDefault S.empty s (predecessors flow)) of
      [p] -> Just p
      _ -> Nothing
    -- the facts entering each block: from a dominating single-predecessor
    -- edge whose source branches on a comparison
    blockFacts :: M.Map BId [Fact]
    blockFacts = M.fromList
      [ (bId b, facts)
      | b <- fnBlocks fn
      , let entered = [ facts
                      | s <- S.toList (M.findWithDefault S.empty (bId b) doms)
                      , Just p <- [singlePred s]
                      , Just facts <- [M.lookup (p, s) edgeFacts] ]
      , let facts = concat entered ]
    edgeFacts = M.fromListWith (++)
      [ ((bId b, target), facts)
      | b <- fnBlocks fn
      , TCondBr p yes _ no _ <- [bTerm b]
      , Just (o, x, y) <- [M.lookup (resolve p) cmps]
      , (target, o') <- [(yes, o), (no, negateCmp o)]
      , let facts = factsOf o' x y
      , not (null facts) ]
    factsAt d = M.findWithDefault [] d blockFacts
    -- bounds of a value under a fact set; a cycle (impossible in SSA, but
    -- the recursion is through facts) is no bound
    ub fs = go S.empty
      where
        go seen x = minimum' (catMaybes (constant : Just hi : map step toward))
          where
            constant = M.lookup x consts
            toward = [(v, c) | (a, v, c) <- fs, a == x]
            step (v, c) = if S.member v seen then Nothing else (+ c) <$> go (S.insert x seen) v
    lb fs = go S.empty
      where
        go seen x = maximum' (catMaybes (constant : Just lo : map step toward))
          where
            constant = M.lookup x consts
            toward = [(v, c) | (v, b, c) <- fs, b == x]
            step (v, c) = if S.member v seen then Nothing else subtract c <$> go (S.insert x seen) v
    minimum' xs = if null xs then Nothing else Just (minimum xs)
    maximum' xs = if null xs then Nothing else Just (maximum xs)
    diffUB fs a b = minimum' ([c | (a', b', c) <- fs, a' == a, b' == b]
                              ++ [u - l | Just u <- [ub fs a], Just l <- [lb fs b]])
    leq :: Maybe Integer -> Integer -> Bool
    leq (Just n) c = n <= c
    leq Nothing _ = False
    cmpHolds fs o a b = case o of
      Lt -> leq (diffUB fs (resolve a) (resolve b)) (-1)
      Le -> leq (diffUB fs (resolve a) (resolve b)) 0
      Gt -> leq (diffUB fs (resolve b) (resolve a)) (-1)
      Ge -> leq (diffUB fs (resolve b) (resolve a)) 0
      Eq -> leq (diffUB fs (resolve a) (resolve b)) 0 && leq (diffUB fs (resolve b) (resolve a)) 0
      Ne -> leq (diffUB fs (resolve a) (resolve b)) (-1) || leq (diffUB fs (resolve b) (resolve a)) (-1)
    -- the no-overflow proof for x + k / x - k: one side is the domain's,
    -- the other must come from the facts
    fitsAdd fs x k
      | k > 0 = maybe False (\u -> u + k <= hi) (ub fs x) -- x >= lo already: x + k > lo
      | k < 0 = maybe False (\l -> l + k >= lo) (lb fs x)
      | otherwise = True
    arithProof fs o x y = case o of
      Add -> case (M.lookup (resolve x) consts, M.lookup (resolve y) consts) of
        (_, Just k) -> fitsAdd fs (resolve x) k
        (Just k, _) -> fitsAdd fs (resolve y) k
        _ -> False
      Sub | Just k <- M.lookup (resolve y) consts -> fitsAdd fs (resolve x) (negate k)
      _ -> False
    rewrite b = (bInstrs' /= bInstrs b || term' /= bTerm b, b {bInstrs = bInstrs', bTerm = term'})
      where
        fs = factsAt (bId b)
        bInstrs' = map instr (bInstrs b)
        instr (Instr (Just (v, TInt)) (OArith o x y))
          | o `elem` [Add, Sub], arithProof fs o x y = Instr (Just (v, TInt)) (OArithU o x y)
        instr i = i
        term' = case bTerm b of
          TCondBr p yes ys no ns
            | Just (o, a, b') <- M.lookup (resolve p) cmps
            , cmpHolds fs o a b' -> TBr yes ys
            | Just (o, a, b') <- M.lookup (resolve p) cmps
            , cmpHolds fs (negateCmp o) a b' -> TBr no ns
          t -> t
    results = map rewrite (fnBlocks fn)
    changed = any fst results
    rewritten = fn {fnBlocks = map snd results}
    -- threading a branch can orphan its untaken arm's blocks
    sweep f =
      let live = reachable (analyze f)
          kept = [b | b <- fnBlocks f, S.member (bId b) live]
       in if length kept == length (fnBlocks f) then f else sweep f {fnBlocks = kept}
