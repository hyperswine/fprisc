{-# LANGUAGE LambdaCase #-}
-- Codegen.Place: conservative placement of the selected stream
-- (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md, M2: "conservative spill
-- placement to establish correctness").
--
-- Every virtual register gets a frame slot of its own and lives there.
-- Around each instruction, its uses are loaded into registers that
-- satisfy their constraints and its definitions are stored back; no value
-- is in a register between two instructions, so nothing is live across a
-- call, a safepoint or a stack-segment change and no clobber can reach a
-- value.  The placement honours the constraint vocabulary exactly: a fixed
-- operand is loaded into its register, a tied definition reuses its use's
-- register, an unconstrained operand takes a scratch register the target
-- provides, never one the instruction names implicitly or clobbers.
--
-- The loads and stores a target supplies must not touch the flags: an
-- instruction that reads flags is placed right after the one that wrote
-- them with only these loads and stores between (checked here).
module Codegen.Place (Placement (..), placeInSlots) where

import Codegen.Frame
import Codegen.Selected
import Control.Monad (unless)
import Data.List (nub, (\\))
import qualified Data.Map.Strict as M

data Placement = Placement
  { plScratch :: RegClass -> [Phys], -- scratch registers, in preference order
    plLoad :: Phys -> FrameRef -> SInstr, -- register <- slot; flags untouched
    plStore :: Phys -> FrameRef -> SInstr, -- slot <- register; flags untouched
    plSlot :: VReg -> FrameObj -- the slot a virtual register gets (size, class, root status)
  }

-- the placed function (no OV operands remain) and the frame objects it needs
placeInSlots :: Placement -> SFn -> Either String (SFn, [FrameObj])
placeInSlots pl fn = do
  let vregs = nub (sfParams fn ++ concat [map fst (instrVRegs i) | I i <- sfBody fn])
      slots = M.fromList [(v, plSlot pl v) | v <- vregs]
      slotOf v = foRef (slots M.! v)
  body <- concat <$> mapM (place slotOf) (sfBody fn)
  pure (fn {sfBody = body}, [slots M.! v | v <- vregs])
  where
    place _ (ILabel l) = pure [ILabel l]
    place slotOf (I i) = do
      let busy = siImplicitDefs i ++ siImplicitUses i ++ siClobbers i ++ [p | OV _ (Fix p) <- siDefs i ++ siUses i] ++ [p | OP p <- siDefs i ++ siUses i]
          here = "place " ++ sfName fn ++ " " ++ siOp i ++ ": "
      -- uses: fixed registers first, then scratch for the rest
      (useRegs, pool) <- assign here busy (plScratch pl) (siUses i)
      -- definitions: tied ones take their use's register, fixed their own,
      -- the rest fresh scratch (never one a use holds: a pseudo may write
      -- its definition before it has read every use)
      (defRegs, _) <- assignDefs here busy pool useRegs (siDefs i)
      let loads = [I (plLoad pl p (slotOf v)) | (OV v _, Just p) <- zip (siUses i) useRegs]
          stores = [I (plStore pl p (slotOf v)) | (OV v _, Just p) <- zip (siDefs i) defRegs]
          sub os rs = [maybe o OP r | (o, r) <- zip os rs]
          placed = i {siUses = sub (siUses i) useRegs, siDefs = sub (siDefs i) defRegs}
      unless (all (\(I transfer) -> siFlags transfer == FlagsNone
                      && siControl transfer == Next && null (siCalls transfer)) (loads ++ stores)) $
        Left (here ++ "slot transfer changes flags, control flow or calls")
      -- an instruction that reads flags must not have a definition store
      -- or a use load between it and the writer that sets them: loads and
      -- stores are flag-neutral by the Placement contract, so this holds;
      -- a tail transfer or return after stores would lose the value, so
      -- an instruction that leaves the function defines nothing
      case siControl i of
        Return | not (null stores) -> Left (here ++ "a return or tail transfer defines a value")
        _ -> pure ()
      pure (loads ++ [I placed] ++ stores)
    assign here busy scratch os = go os (scratch GPR, scratch FPR) []
      where
        go [] pool acc = pure (reverse acc, pool)
        go (o : rest) pool@(g, f) acc = case o of
          OV _ (Fix p) -> go rest pool (Just p : acc)
          OV _ (Any GPR) -> case g \\ busy of
            (p : _) -> go rest (filter (/= p) g, f) (Just p : acc)
            [] -> Left (here ++ "no scratch register of class GPR is free")
          OV _ (Any FPR) -> case f \\ busy of
            (p : _) -> go rest (g, filter (/= p) f) (Just p : acc)
            [] -> Left (here ++ "no scratch register of class FPR is free")
          OV _ (Tied _) -> Left (here ++ "a tied use operand")
          _ -> go rest pool (Nothing : acc)
    assignDefs here busy pool useRegs os = go os pool []
      where
        go [] p acc = pure (reverse acc, p)
        go (o : rest) p@(g, f) acc = case o of
          OV _ (Fix r) -> go rest p (Just r : acc)
          OV _ (Tied k) -> case drop k useRegs of
            (Just r : _) -> go rest p (Just r : acc)
            _ -> Left (here ++ "tied to an operand without a register")
          OV _ (Any GPR) -> case g \\ busy of
            (r : _) -> go rest (filter (/= r) g, f) (Just r : acc)
            [] -> Left (here ++ "no scratch register of class GPR is free for a definition")
          OV _ (Any FPR) -> case f \\ busy of
            (r : _) -> go rest (g, filter (/= r) f) (Just r : acc)
            [] -> Left (here ++ "no scratch register of class FPR is free for a definition")
          _ -> go rest p (Nothing : acc)
