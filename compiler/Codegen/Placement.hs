-- Codegen.Placement: where a function's obligations to the runtime sit.
--
-- An FP-RISC function owes the scheduler a fuel tick per entry and the
-- stack a headroom check per frame; Codegen.Lower emits both at the entry,
-- and an inlined callee brings its entry tick with it (Inline.hs,
-- Core.Typed.Inline). This module is the one place that moves or removes
-- such obligations. It runs inside lowering, after Codegen.LoopForm and
-- before the evaluator/simplifier boundary, so the evaluator's oracle and
-- the backends see the same ticks and Codegen.Simplify keeps its rule that
-- it never touches one (docs/2026-11-07-CHECK-PLACEMENT-AND-TYPED-LOWERING.md,
-- change 1, slice 1).
--
-- One decision lives here today, the batched fuel tick (until 7 November
-- 2026 Core.Opt.Ticks on erased Core; FPR_NO_TICK_BATCH=1 rolls it back).
-- A recursive function, one with a natural loop or a direct call to
-- itself, keeps the ticks that make every cycle tick: its entry's, and the
-- ones LoopForm leaves on the back edges of a formed loop. The ticks of the
-- callees inlined into its body go when the body is bounded. Every
-- iteration and every activation still charges one unit, and the work
-- between two ticks stays bounded by the body: an inlined callee is
-- non-recursive, and a call that was not inlined ticks at its own entry.
-- A non-recursive function keeps every tick, so fuel still counts calls.
module Codegen.Placement (placeTicks, tickBodyBound) where

import Codegen.ControlFlow
import Codegen.IR
import Codegen.Policy
import qualified Data.Set as S

-- The body bound the batched tick had on Core (Core.Opt.Ticks, 1024 Core
-- nodes, the scalar workers' bound), now in IR instructions and
-- terminators: a larger body keeps its inlined ticks and the work between
-- two ticks with them.
tickBodyBound :: Int
tickBodyBound = 1024

placeTicks :: Policy -> Fn -> Fn
placeTicks policy fn
  | not (polFuel policy && polTickBatch policy) = fn
  -- nothing to place: no tick beyond the entry's (the CFG analysis below is
  -- paid only by functions that inlined a callee)
  | not (any (\b -> any isTick (drop (if bId b == fnEntry fn then length (takeWhile isCheck (bInstrs b)) else 0) (bInstrs b))) blocks) = fn
  -- Lower's only loops are self tail calls (a jump to the entry) and the
  -- loops LoopForm makes of them; the CFG analysis is paid only when one of
  -- those shapes, or a direct self call, is present
  | not (selfCall || jumpsToEntry || polEarlyLoops policy) = fn
  | not recursive || size > tickBodyBound = fn
  | all stillTicks loops = fn {fnBlocks = stripped}
  | otherwise = fn
  where
    blocks = fnBlocks fn
    loops = naturalLoops fn (analyze fn)
    jumpsToEntry = or [target == fnEntry fn | b <- blocks, (target, _) <- termSuccs (bTerm b)]
    self c = calleeName c == fnName fn
    callees op = case op of OCall c _ -> [c]; OCallProduct c _ -> [c]; _ -> []
    selfCall = or ([self c | b <- blocks, Instr _ op <- bInstrs b, c <- callees op]
                   ++ [self c | b <- blocks, TTailCall c _ <- [bTerm b]])
    recursive = not (null loops) || selfCall
    size = sum [length (bInstrs b) + 1 | b <- blocks]
    isTick (Instr _ OSafepoint) = True
    isTick _ = False
    isCheck (Instr _ op) = op == OStackCheck || op == OSafepoint
    -- the back edges LoopForm ticks: those of a loop whose header is not
    -- the entry (a loop through the entry ticks in the entry's prefix)
    latches = S.unions [loopLatches l | l <- loops, loopHeader l /= fnEntry fn]
    -- the positions a block keeps: the entry's leading checks, a latch's
    -- closing tick
    structural b
      | bId b == fnEntry fn = S.fromList [0 .. length (takeWhile isCheck (bInstrs b)) - 1]
      | S.member (bId b) latches, not (null (bInstrs b)), isTick (last (bInstrs b)) = S.singleton (length (bInstrs b) - 1)
      | otherwise = S.empty
    strip b = b {bInstrs = [i | (k, i) <- zip [0 :: Int ..] (bInstrs b), not (isTick i) || S.member k (structural b)]}
    stripped = map strip blocks
    -- the contract after the strip: every cycle still contains a tick
    stillTicks l = or [charges op | b <- stripped, S.member (bId b) (loopBlocks l), Instr _ op <- bInstrs b]
    charges op = case op of OSafepoint -> True; OSafepointN n -> n > 0; _ -> False
