{-# LANGUAGE LambdaCase #-}
-- Codegen.Selected: the selected-instruction structure between the typed
-- IR and a target's assembly (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md,
-- milestone M2; docs/2026-10-21-NATIVE-IR-CONTRACTS.md, "Calls and
-- target constraints").
--
-- A selected instruction carries an operation identity over operands that
-- are still virtual registers, each carrying the target's constraint. Shared
-- protocols and all native ISA operations use constructors in Codegen.Opcode.
-- Invented text operations are confined to synthetic constraint tests and are
-- refused by every native emission path. Constraints include:
--
--   * a register class (the integer bank, the float/vector bank),
--   * a fixed physical register (an argument or result register, x86-64's
--     division registers %rax/%rdx and its shift count %cl),
--   * a tied definition (x86-64's two-address arithmetic: the destination
--     is the register of use operand i),
--
-- plus what the instruction does beyond its operands: implicit uses and
-- definitions, the registers a call clobbers, whether it reads or writes
-- the condition flags, its control effect, and the bound events inside it
-- (a safepoint boundary, C calls).  Every temporary a selection introduces
-- is a virtual register here; nothing is hidden inside a string.
--
-- The vocabulary carries x86-64's needs from its first commit, as the plan
-- requires: tied destinations, fixed division and shift registers, the
-- split between the value register (%rax) and the first-argument register
-- (%rdi) at a call, the call-alignment pseudo and the a6/a7 argument cells
-- as memory operands.  `tests/SelectedIR.hs` writes those shapes down and
-- checks the validity rules on them; both direct scalar selectors use
-- this vocabulary.
--
-- Nothing here chooses a physical register for a virtual one.  That is
-- placement (Codegen.Place.placeInSlots in M2: every virtual register in a
-- frame slot) or allocation (M3).
module Codegen.Selected
  ( VReg (..), RegClass (..), Phys (..), Constraint (..), Operand (..),
    Flags (..), Control (..), Call (..), Annotation(..), AllocationEvent(..),
    SInstr (..), Item (..), Label (..), SFn (..),
    RegisterFile (..), plain, plainOpcode, siOp, checkFn, itemLabels, instrVRegs, operandVReg,
  ) where

import Codegen.Calling.Types (Transfer, ArgumentCell)
import Codegen.Frame (FrameRef)
import qualified Codegen.Opcode as Op
import Control.Monad (forM_, unless, when)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- a virtual register: the IR's values and the temporaries selection adds
newtype VReg = VReg Int deriving (Eq, Ord, Show)

data RegClass = GPR | FPR deriving (Eq, Ord, Show)

-- a physical register by its target name ("x0", "rax", "cl" is not one: the
-- shift count is "rcx" and the target prints the sub-register it needs)
newtype Phys = Phys String deriving (Eq, Ord, Show)

-- what the target demands of an operand's register
data Constraint
  = Any RegClass -- any register of the class
  | Fix Phys -- exactly this register
  | Tied Int -- (definitions only) the register of use operand i
  deriving (Eq, Ord, Show)

data Operand
  = OV VReg Constraint -- a virtual register
  | OP Phys -- a named physical register (sp, the frame pointer, the hart register)
  | OI Integer -- an immediate
  | OS String -- a symbol: a function, a runtime entry, a data object, a TLS cell
  | OC ArgumentCell -- a private x64 argument cell, not an arbitrary linker symbol
  | OL Label -- a function-local label
  | OF FrameRef Int -- a frame object plus a byte offset, symbolic until layout
  deriving (Eq, Ord, Show)

-- the condition flags (NZCV, RFLAGS)
data Flags = FlagsNone | FlagsDef | FlagsUse | FlagsDefUse deriving (Eq, Ord, Show)

-- what happens after the instruction
data Control
  = Next -- falls through
  | CondTo [Label] -- may go to any of these, else falls through
  | JumpTo Label -- always goes there
  | Return -- leaves the function: a return or a tail transfer
  deriving (Eq, Ord, Show)

-- a call inside the instruction (a direct `bl`/`call`, or one buried in a
-- pseudo such as the fuel tick or the stack check)
data Call = Call
  { callTarget :: String, -- the symbol, as the IR names it (the printer adds the platform prefix)
    callSafepoint :: Bool, -- the callee ticks the fuel counter on entry, or is the tick: a bound reset
    callRuntime :: Bool -- a C call counted by the bound's runtime-call accounting
  }
  deriving (Eq, Ord, Show)

newtype Label = Label String deriving (Eq, Ord, Show)

-- Semantic payloads and allocation accounting have different owners. An entry
-- label spelled "copy" cannot become an allocation statistic, and inserting a
-- copy cannot overwrite a label, frame-save index or restore decision.
data Annotation=NoAnnotation | EntryLabels Label | SaveGroup Int | SkipRestores
  deriving (Eq,Ord,Show)
data AllocationEvent=SpillStore | Reload | RegisterCopy deriving (Eq,Ord,Show)

data SInstr = SInstr
  { siOpcode :: Op.Opcode, -- constructor identity survives placement/allocation
    siDefs :: [Operand],
    siUses :: [Operand],
    siImplicitDefs :: [Phys], -- written beyond the listed definitions (an expansion's scratch, %rdx of a division)
    siImplicitUses :: [Phys], -- read beyond the listed uses (the hart register, %rdx of a division)
    siClobbers :: [Phys], -- destroyed, holding nothing afterwards (a call's caller-saved set)
    siFlags :: Flags,
    siControl :: Control,
    siCalls :: [Call], -- in order; empty for an ordinary instruction
    siAnnotation :: Annotation,
    siTransfer :: Maybe Transfer, -- physical entry/argument/result contract for a direct transfer
    siAllocation :: Maybe AllocationEvent
  }
  deriving (Eq, Ord, Show)

data Item = ILabel Label | I SInstr deriving (Eq, Ord, Show)

data SFn = SFn
  { sfName :: String,
    sfParams :: [VReg], -- the entry values, in argument order
    sfBody :: [Item]
  }
  deriving (Eq, Ord, Show)

-- what the checker needs to know about a target's registers
data RegisterFile = RegisterFile
  { rfClassOf :: Phys -> Maybe RegClass, -- Nothing: not a register of this target
    rfReserved :: [Phys] -- never an operand: the stack pointer, the hart register, the expansion scratch
  }

-- an ordinary instruction: no implicit registers, no flags, falls through
plain :: String -> [Operand] -> [Operand] -> SInstr
plain op = plainOpcode (Op.textOpcode op)

plainOpcode :: Op.Opcode -> [Operand] -> [Operand] -> SInstr
plainOpcode op ds us = SInstr op ds us [] [] [] FlagsNone Next [] NoAnnotation Nothing Nothing

-- Diagnostic spelling only. Typed selectors/renderers use siOpcode.
siOp :: SInstr -> String
siOp = Op.opcodeName . siOpcode

operandVReg :: Operand -> Maybe (VReg, Constraint)
operandVReg = \case
  OV v c -> Just (v, c)
  _ -> Nothing

instrVRegs :: SInstr -> [(VReg, Constraint)]
instrVRegs i = [x | o <- siDefs i ++ siUses i, Just x <- [operandVReg o]]

itemLabels :: [Item] -> [Label]
itemLabels items = [l | ILabel l <- items]

-- The validity rules.  A violation is a compiler error, never a fallback:
-- selection produced something allocation could not honour.
--
--   * every virtual register has one register class, consistent across
--     its occurrences; a Fix names a register of that class;
--   * Tied i names a use operand i that is a virtual register of the same
--     class; definitions only;
--   * a fixed register is not reserved, and a fixed definition is not also
--     in the clobber list (a result is defined, not destroyed);
--   * two fixed uses or two fixed definitions of one instruction do not
--     name the same register for different virtual registers;
--   * an instruction with a call declares clobbers;
--   * every label a branch names is defined exactly once; a label is
--     defined at most once;
--   * every virtual register used is a parameter or defined somewhere.
checkFn :: RegisterFile -> SFn -> Either String ()
checkFn rf fn = mapLeft (("selected " ++ sfName fn ++ ": ") ++) $ do
  let labels = itemLabels (sfBody fn)
  when (length (S.fromList labels) /= length labels) (Left "a label is defined twice")
  let labelSet = S.fromList labels
      instrs = [i | I i <- sfBody fn]
      occurrences = [(v, classOf c) | i <- instrs, (v, c) <- instrVRegs i]
      classOf = \case
        Any k -> Just k
        Fix p -> rfClassOf rf p
        Tied _ -> Nothing
      classes = M.fromListWith (\a b -> if a == b then a else Nothing)
                  [(v, Just k) | (v, Just k) <- occurrences]
      defined = S.fromList (sfParams fn ++ [v | i <- instrs, (v, _) <- [x | o <- siDefs i, Just x <- [operandVReg o]]])
  forM_ (M.toList classes) $ \(v, k) -> when (k == Nothing) (Left (show v ++ " is used with two register classes"))
  forM_ (zip [0 :: Int ..] instrs) $ \(n, i) -> do
    let here = "#" ++ show n ++ " " ++ siOp i ++ ": "
        fixes os = [(p, v) | OV v (Fix p) <- os]
    forM_ (siUses i) $ \o -> case o of
      OV _ (Tied _) -> Left (here ++ "a use operand is tied")
      OV v (Fix p) -> do
        fixOk here v p
        unless (S.member v defined) (Left (here ++ show v ++ " is never defined"))
      OV v _ -> unless (S.member v defined) (Left (here ++ show v ++ " is never defined"))
      OL l -> unless (S.member l labelSet) (Left (here ++ "names an undefined label"))
      _ -> pure ()
    forM_ (siDefs i) $ \o -> case o of
      OV v (Tied k) -> do
        when (k < 0 || k >= length (siUses i)) (Left (here ++ "tied to a use operand that does not exist"))
        case siUses i !! k of
          OV u c -> do
            let kv = M.lookup v classes
                ku = M.lookup u classes
            unless (kv == ku || kv == Nothing || ku == Nothing) (Left (here ++ "tied operands have different classes"))
            case c of
              Fix p -> fixOk here v p
              _ -> pure ()
          _ -> Left (here ++ "tied to a use operand that is not a virtual register")
      OV v (Fix p) -> do
        fixOk here v p
        when (p `elem` siClobbers i) (Left (here ++ "defines " ++ show p ++ " and clobbers it"))
      _ -> pure ()
    let dup os = [p | (p, vs) <- M.toList (M.fromListWith (++) [(p, [v]) | (p, v) <- fixes os]), length (S.fromList vs) > 1]
    unless (null (dup (siUses i))) (Left (here ++ "two uses fix the same register"))
    unless (null (dup (siDefs i))) (Left (here ++ "two definitions fix the same register"))
    unless (null (siCalls i) || not (null (siClobbers i))) (Left (here ++ "a call without clobbers"))
    forM_ (siClobbers i ++ siImplicitDefs i ++ siImplicitUses i) $ \p ->
      when (rfClassOf rf p == Nothing) (Left (here ++ "names " ++ show p ++ ", not a register"))
    case siControl i of
      CondTo ls -> forM_ ls (\l -> unless (S.member l labelSet) (Left (here ++ "branches to an undefined label")))
      JumpTo l -> unless (S.member l labelSet) (Left (here ++ "jumps to an undefined label"))
      _ -> pure ()
  pure ()
  where
    fixOk here v p = do
      when (p `elem` rfReserved rf) (Left (here ++ show v ++ " is fixed to the reserved register " ++ show p))
      case rfClassOf rf p of
        Nothing -> Left (here ++ show p ++ " is not a register")
        Just _ -> pure ()
    mapLeft f = either (Left . f) Right
