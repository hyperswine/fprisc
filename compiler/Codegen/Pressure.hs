{-# LANGUAGE LambdaCase #-}
-- Codegen.Pressure: a register-pressure model over the typed native IR, for
-- passes that lengthen live ranges (Codegen.LoopOptimize) to ask whether the
-- target's registers can hold the result before they change anything.
--
-- The model counts, per register class, the values live at each point of a
-- set of blocks (a loop), and separately those live ACROSS an operation that
-- may call: the allocator (Codegen.Allocate) must place those in the
-- scheduler-preserved (callee-saved) budget or in a frame slot, so that
-- budget is the binding one in any loop with a tick or a slow path.
--
-- It is a model, not the allocator: classes are guessed from types and
-- operations (an F64 operation's result is a float register when the
-- target has a float bank), and liveness is exact on IR values, which the
-- allocator's segments (Codegen.Liveness) approximate per block.  Callers
-- use it to refuse a change that makes a loop need more registers than
-- the target has where it needed no more before.
module Codegen.Pressure
  ( Pressure (..), loopPressure, fitsBudget, mayCall,
  ) where

import Codegen.IR
import Codegen.Policy (RegisterBudget (..))
import Data.List (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- the maxima over the points of the measured blocks
data Pressure = Pressure
  { prGpr :: Int, -- integer values live at once
    prFpr :: Int, -- float values live at once (0 on a target without a float bank: they count as integer)
    prGprAcross :: Int, -- integer values live across a possible call
    prFprAcross :: Int
  }
  deriving (Eq, Show)

-- An operation the backends may expand into a call: a runtime entry, a
-- generated call, the fuel tick or stack check, an allocation, or a checked
-- operation whose failure path calls the runtime.  `inlineFloats` says
-- whether F64 arithmetic is inline (Policy.polFloatInline).
mayCall :: Bool -> Op -> Bool
mayCall inlineFloats = \case
  OConstInt {} -> False; OHartCell {} -> False; ORegionRoom {} -> False
  ONullary {} -> False; OString {} -> False; OBoxedFloat {} -> False
  OAddress {} -> False; OIndex {} -> False; OLoad {} -> False; OLoadByte {} -> False
  OStore {} -> False; OField {} -> False; OTag {} -> False; OUntag {} -> False
  OBoolOf {} -> False; OTruth {} -> False; ONot {} -> False; OIsInt {} -> False
  OTagTest {} -> False; OSymbol {} -> False; OFunValue {} -> False
  OBit {} -> False; OCmp {} -> False; OBits {} -> False
  ORvvVlMax {} -> False; ORvvLanes {} -> False; ORvvSumLoaded {} -> False
  OFloatBin {} -> not inlineFloats; OFloatCmp {} -> not inlineFloats
  OFloatTree {} -> not inlineFloats; OFloatCmpTree {} -> not inlineFloats
  OFloat32Bin {} -> not inlineFloats; OFloat32Cmp {} -> not inlineFloats
  OFloat32Tree {} -> not inlineFloats; OFloat32CmpTree {} -> not inlineFloats
  _ -> True

floatOp :: Op -> Bool
floatOp = \case
  OFloatBin {} -> True; OFloatTree {} -> True; OFloat32Bin {} -> True; OFloat32Tree {} -> True
  OBits {} -> True
  _ -> False

-- the pressure inside the given blocks of a function
loopPressure :: RegisterBudget -> Bool -> Fn -> S.Set BId -> Pressure
loopPressure budget inlineFloats fn members =
  foldl' visit (Pressure 0 0 0 0) [b | b <- fnBlocks fn, S.member (bId b) members]
  where
    hasFloats = rbFprAll budget > 0
    classes = M.fromList ([(v, hasFloats && t == TF64) | b <- fnBlocks fn, (v, t) <- bParams b]
      ++ [(v, hasFloats && (t == TF64 || floatOp op)) | b <- fnBlocks fn, Instr (Just (v, t)) op <- bInstrs b])
    isFloat v = M.findWithDefault False v classes
    count vs = let (f, g) = S.partition isFloat vs in (S.size g, S.size f)
    params b = S.fromList (map fst (bParams b))
    -- block live-in sets by the usual backward fixpoint; a terminator's
    -- arguments are uses in its block, a target's parameters are defined
    -- at the target's entry
    transfer out b =
      let tailLive = S.union out (S.fromList (termUses (bTerm b)))
          inner = foldr (\(Instr d op) live -> S.union (S.fromList (opUses op)) (maybe live (\(v, _) -> S.delete v live) d)) tailLive (bInstrs b)
       in inner S.\\ params b
    liveOut ins b = S.unions [M.findWithDefault S.empty t ins | (t, _) <- termSuccs (bTerm b)]
    fixpoint ins =
      let next = M.fromList [(bId b, transfer (liveOut ins b) b) | b <- fnBlocks fn]
       in if next == ins then ins else fixpoint next
    ins0 = fixpoint (M.fromList [(bId b, S.empty) | b <- fnBlocks fn])
    -- walk one block backwards, recording each point
    visit acc b =
      let out = S.union (liveOut ins0 b) (S.fromList (termUses (bTerm b)))
          step (live, p) (Instr d op) =
            let born = maybe S.empty (S.singleton . fst) d
                after = live S.\\ born
                (g, f) = count live
                (ga, fa) = if mayCall inlineFloats op then count after else (0, 0)
                p' = Pressure (max (prGpr p) g) (max (prFpr p) f) (max (prGprAcross p) ga) (max (prFprAcross p) fa)
             in (S.union (S.fromList (opUses op)) after, p')
          (entry, acc') = foldl' step (out, acc) (reverse (bInstrs b))
          (g0, f0) = count (S.union entry (params b))
       in acc' {prGpr = max (prGpr acc') g0, prFpr = max (prFpr acc') f0}

-- The pressure fits the target's registers: everything live across a call
-- fits the preserved budget of its class, and everything live at once fits
-- the whole class.  Floats count as integer values on a target without a
-- float bank.
fitsBudget :: RegisterBudget -> Pressure -> Bool
fitsBudget b p =
  prGprAcross p <= rbGprAcross b && prGpr p <= rbGprAll b
    && prFprAcross p <= rbFprAcross b && prFpr p <= rbFprAll b
