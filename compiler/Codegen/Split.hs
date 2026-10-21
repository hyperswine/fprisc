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
-- predecessor edge comes from the entry block, each entry value that the
-- region B dominates carries across a call becomes a new parameter of B,
-- passed on that edge, and the uses inside that region are renamed.
-- Values the region does not carry across a call are left alone: a split
-- would only add a copy (measured: every-value splitting made a self loop
-- 23% slower, docs/2026-10-22-TYPED-IR-FIB.md).  The entry's own uses and
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
            -- only values the region carries across a call: those are the
            -- ones the allocator must otherwise keep in a callee-saved
            -- register from the entry on (splitting the rest only adds
            -- copies, a loop's turn among them)
            crossing = crossingIn f region
            moving = [(v, t) | (v, t) <- M.toList entryDefs, S.member v crossing]
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
-- the values used after a call-like operation inside the region: later in
-- the same block, or in a block of the region reachable from it
crossingIn :: Fn -> S.Set BId -> S.Set VId
crossingIn f region = S.fromList (concat [afterCall b ++ concatMap blockUses (reachFrom b) | b <- inRegion, hasCall b])
  where
    inRegion = [b | b <- fnBlocks f, S.member (bId b) region]
    byId = M.fromList [(bId b, b) | b <- fnBlocks f]
    hasCall b = any (\(Instr _ op) -> callLike op) (bInstrs b)
    afterCall b = concat [opUses op | Instr _ op <- drop 1 (dropWhile (\(Instr _ o) -> not (callLike o)) (bInstrs b))] ++ termUses (bTerm b)
    reachFrom b = go S.empty [t | (t, _) <- termSuccs (bTerm b)]
      where
        go _ [] = []
        go seen (t : ts)
          | S.member t seen || not (S.member t region) = go seen ts
          | otherwise = case M.lookup t byId of
              Just tb -> tb : go (S.insert t seen) ([u | (u, _) <- termSuccs (bTerm tb)] ++ ts)
              Nothing -> go seen ts

-- an operation the native selection turns into a call that clobbers the
-- caller-saved registers on its common path
callLike :: Op -> Bool
callLike op = case op of
  OStrLen _ -> True
  OCharAt _ _ -> True
  _ -> opEffect op `elem` [AnyEffect, RuntimeCall]

blockUses :: Block -> [VId]
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
