{-# LANGUAGE LambdaCase #-}
-- Codegen.Policy: the explicit target and profile policy the typed-IR
-- lowering and the native backends take (docs/2026-10-21-NATIVE-IR-CONTRACTS.md,
-- "Core coverage and representation evidence": scheduler fuel, stack checks
-- and raw/ARC conventions cannot be inferred from the ISA alone).
--
-- Hosted profiles retain actor fuel and growable stacks. Builtin profiles
-- use a fixed stack with manual ownership or nonmoving conservative GC.
-- ARC uses the same fixed-stack contract after explicit ownership lowering.
module Codegen.Policy
  ( Profile (..), StackPolicy (..), Policy (..), RegisterBudget (..), registerBudget, m2Policy, validatePolicy, profileName, policyWidth,
  ) where

import Codegen.IR (Width (..))

data Profile
  = HostedBase -- the actor runtime on a hosted OS: fuel, growable stacks, no moving collector
  | Builtin -- the bare-metal profile: no fuel, its own allocator and root scans
  | Builtin32 -- builtin with a 32-bit word, fixed stack, no actor fuel
  | BuiltinArc -- builtin with compiler ARC: consuming/borrowing calls, alias retains
  | QosApp -- a loaded QOS app: the plane's allocation, scheduling and stack growth
  | Rv32 -- the 32-bit word: Int is signed 31-bit, every width needs legalization
  deriving (Eq, Ord, Show)

data StackPolicy
  = StackCheckEveryEntry -- every function entry checks its headroom (M2's choice; the M0 register allows it)
  | StackStatic -- builtin fixed stack; no hosted growth call
  | StackCheckShallow -- FPR_TYPED_IR_SHALLOW_STACK: skip the check when the frame is small and no generated function is called
  deriving (Eq, Ord, Show)

data Policy = Policy
  { polProfile :: Profile,
    polFuel :: Bool, -- the entry fuel tick and every inlined `$fuel` tick are emitted
    polStackCheck :: StackPolicy,
    polFloatInline :: Bool, -- F64 + - * / and comparisons inline on the 64-bit word (FPR_NO_F64_INLINE=1 keeps the runtime calls, for differential checks)
    polLoopMotion :: Bool, -- move total register invariants to existing loop preheaders
    polVectorFast :: Bool, -- guarded scalar flat-vector reads; misses keep the original C entry
    polRegisters :: Maybe RegisterBudget -- the target's allocatable registers, for passes that lengthen live ranges (Codegen.Pressure); Nothing: unlimited
  }
  deriving (Eq, Ord, Show)

-- What a native target's allocator has (Codegen.Target.*: the allocation
-- configurations): per class, the scheduler-preserved budget a value live
-- across a call must use, and every allocatable register. A target without
-- a float bank has zero float registers; its floats are integer words.
data RegisterBudget = RegisterBudget
  { rbGprAcross :: Int, rbGprAll :: Int, rbFprAcross :: Int, rbFprAll :: Int }
  deriving (Eq, Ord, Show)

-- by backend name, as the allocation configurations define them
registerBudget :: String -> Maybe RegisterBudget
registerBudget = \case
  "a64" -> Just (RegisterBudget 9 22 8 14) -- x19..x27 + x0..x12; d8..d15 + d2..d7
  "x64" -> Just (RegisterBudget 5 12 0 0) -- rbx, r12..r15 + rax, rcx, rdx, rsi, rdi, r8, r9
  "rv64" -> Just (RegisterBudget 11 19 0 0) -- s1..s11 + a0..a7
  "rv32" -> Just (RegisterBudget 11 19 0 0)
  _ -> Nothing

m2Policy :: Policy
m2Policy = Policy HostedBase True StackCheckEveryEntry True False True Nothing

profileName :: Profile -> String
profileName = \case
  HostedBase -> "hosted Base"
  Builtin -> "builtin"
  Builtin32 -> "builtin RV32"
  BuiltinArc -> "builtin with ARC"
  QosApp -> "QOS app"
  Rv32 -> "rv32"

-- Admit each runtime contract explicitly.
validatePolicy :: Policy -> Either String ()
validatePolicy p = if polProfile p `elem` [HostedBase,QosApp,Rv32] && polStackCheck p == StackStatic
  then Left "a hosted profile requires stack-growth checks"
  else case polProfile p of
  HostedBase
    | not (polFuel p) -> Left "the hosted Base profile without fuel is not a supported policy"
    | otherwise -> Right ()
  -- a loaded QOS app keeps hosted Base's contract: fuel, growable stacks and
  -- allocation through the app-side runtime, which delegates to the plane
  -- (NATIVE-IR-CONTRACTS "Managed values and profile-specific roots");
  -- the hart arrives by x28 or the global cell (Codegen.Target.A64)
  QosApp
    | not (polFuel p) -> Left "a QOS app without fuel is not a supported policy"
    | otherwise -> Right ()
  Builtin -> builtin
  Builtin32 -> builtin
  BuiltinArc -> builtin
  Rv32
    | polFuel p -> Right ()
    | otherwise -> Left "RV32 builtin ownership/allocator policy is not implemented"
  other -> Left ("the " ++ profileName other ++ " profile has no typed-IR native lowering in M2")
  where
    builtin
      | polFuel p = Left "builtin code has no actor fuel"
      | polStackCheck p /= StackStatic = Left "builtin code requires the fixed-stack policy"
      | otherwise = Right ()

-- Word width is separate from the fixed/growable-stack distinction.
policyWidth :: Policy -> Width
policyWidth p = if polProfile p `elem` [Rv32,Builtin32] then W32 else W64
