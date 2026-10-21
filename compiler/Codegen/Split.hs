{-# LANGUAGE LambdaCase #-}
-- Codegen.Split: give the entry block's successors their own copies of the
-- entry values they use (FPR_TYPED_IR_SPLIT_ENTRY,
-- docs/2026-10-22-TYPED-IR-FIB.md).
--
-- The M3 allocator keeps one interval per value.  A parameter that one arm
-- of the entry's branch carries across calls and the other arm only
-- returns (fib: `n < 2` returns n, the other arm calls fib twice) is then a
-- call-crossing value everywhere, so it sits in a callee-saved register
-- from the entry on and both arms pay its save and restore.  This pass
-- splits such values at the entry's branch: for every block B whose only
-- predecessor edge comes from the entry block, each entry value used in
-- the region B dominates becomes a new parameter of B, passed on that edge,
-- and the uses inside that region are renamed.  The entry's own uses and
-- every block outside those regions keep the original value.
--
-- It changes no operation and moves nothing: block arguments are the
-- IR's parallel copies, so evaluation order, traps and effects are the
-- input's.  The result is a verified function (a verifier refusal is a
-- compiler error), and the reference evaluator's results, traps and event
-- order are checked unchanged (tests/TypedIR.hs).
module Codegen.Split (splitEntryValues) where

import Codegen.IR
import qualified Data.Map.Strict as M
import qualified Data.Set as S

splitEntryValues :: Fn -> Fn
splitEntryValues fn = case [b | b <- fnBlocks fn, bId b == fnEntry fn] of
  [entry] -> foldl (splitChild entry) fn children
    where
      entryDefs = M.fromList (blockDefs entry)
      -- edges by target, counted per occurrence (a condbr to one block twice is two)
      predCount = M.fromListWith (+) [(t, 1 :: Int) | b <- fnBlocks fn, (t, _) <- termSuccs (bTerm b)]
      children =
        [ t | (t, _) <- termSuccs (bTerm entry), t /= fnEntry fn, M.lookup t predCount == Just 1 ]
      doms = dominators fn
      splitChild e f child =
        let region = S.fromList [bId b | b <- fnBlocks f, S.member child (M.findWithDefault S.empty (bId b) doms)]
            used = S.fromList [v | b <- fnBlocks f, S.member (bId b) region, v <- blockUses b]
            moving = [(v, t) | (v, t) <- M.toList entryDefs, S.member v used]
            next0 = 1 + maximum (0 : [n | b <- fnBlocks f, (VId n, _) <- blockDefs b])
            fresh = M.fromList (zip (map fst moving) (map VId [next0 ..]))
            rename v = M.findWithDefault v v fresh
            rewrite b
              | bId b == bId e = b {bTerm = passOn (bTerm b)}
              | bId b == child = (renamed b) {bParams = bParams b ++ [(fresh M.! v, t) | (v, t) <- moving]}
              | S.member (bId b) region = renamed b
              | otherwise = b
            renamed b = b {bInstrs = [Instr d (mapOpUses rename op) | Instr d op <- bInstrs b], bTerm = mapTermUses rename (bTerm b)}
            extra = map fst moving
            passOn = \case
              TBr t as | t == child -> TBr t (as ++ extra)
              TCondBr c t as el bs ->
                TCondBr c t (if t == child then as ++ extra else as) el (if el == child then bs ++ extra else bs)
              term -> term
         in if null moving then f else f {fnBlocks = map rewrite (fnBlocks f)}
  _ -> fn
  where
    blockUses b = concat [opUses op | Instr _ op <- bInstrs b] ++ termUses (bTerm b)

-- every block's dominator set (itself included)
dominators :: Fn -> M.Map BId (S.Set BId)
dominators fn = go start
  where
    ids = map bId (fnBlocks fn)
    allIds = S.fromList ids
    preds = M.fromListWith (++) [(t, [bId b]) | b <- fnBlocks fn, (t, _) <- termSuccs (bTerm b)]
    start = M.fromList [(i, if i == fnEntry fn then S.singleton i else allIds) | i <- ids]
    step dm = M.mapWithKey (\i d -> if i == fnEntry fn then d else
      case M.findWithDefault [] i preds of
        [] -> S.singleton i -- unreachable: dominated by nothing else
        ps -> S.insert i (foldr1 S.intersection [M.findWithDefault allIds p dm | p <- ps])) dm
    go dm = let dm' = step dm in if dm' == dm then dm else go dm'
