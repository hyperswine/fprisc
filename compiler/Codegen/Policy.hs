{-# LANGUAGE LambdaCase #-}
-- Codegen.Policy: the explicit target and profile policy the typed-IR
-- lowering and the native backends take (docs/2026-10-21-NATIVE-IR-CONTRACTS.md,
-- "Core coverage and representation evidence": scheduler fuel, stack checks
-- and raw/ARC conventions cannot be inferred from the ISA alone).
--
-- M2 implements one profile: hosted Base (the actor runtime on posix, fuel
-- on, a stack check at every entry).  The other profiles are named here so
-- that a request for them is refused by name rather than lowered under the
-- wrong contract; each gets its own register and tests before it is
-- admitted (the plan's M4).
module Codegen.Policy
  ( Profile (..), StackPolicy (..), Policy (..), m2Policy, validatePolicy, profileName,
  ) where

data Profile
  = HostedBase -- the actor runtime on a hosted OS: fuel, growable stacks, no moving collector
  | Builtin -- the bare-metal profile: no fuel, its own allocator and root scans
  | BuiltinArc -- builtin with compiler ARC: consuming/borrowing calls, alias retains
  | QosApp -- a loaded QOS app: the plane's allocation, scheduling and stack growth
  | Rv32 -- the 32-bit word: Int is signed 31-bit, every width needs legalization
  deriving (Eq, Ord, Show)

data StackPolicy
  = StackCheckEveryEntry -- every function entry checks its headroom (M2's choice; the M0 register allows it)
  | StackCheckLegacyShallow -- the legacy rule: skip the check when the frame is small and no generated function is called
  deriving (Eq, Ord, Show)

data Policy = Policy
  { polProfile :: Profile,
    polFuel :: Bool, -- the entry fuel tick and every inlined `$fuel` tick are emitted
    polStackCheck :: StackPolicy
  }
  deriving (Eq, Ord, Show)

m2Policy :: Policy
m2Policy = Policy HostedBase True StackCheckEveryEntry

profileName :: Profile -> String
profileName = \case
  HostedBase -> "hosted Base"
  Builtin -> "builtin"
  BuiltinArc -> "builtin with ARC"
  QosApp -> "QOS app"
  Rv32 -> "rv32"

-- what M2 implements; everything else is refused by name
validatePolicy :: Policy -> Either String ()
validatePolicy p = case polProfile p of
  HostedBase
    | not (polFuel p) -> Left "the hosted Base profile without fuel is not a supported policy"
    | polStackCheck p /= StackCheckEveryEntry -> Left "the legacy shallow stack-check rule is not implemented in M2 (the frame size is a layout result); every entry is checked"
    | otherwise -> Right ()
  other -> Left ("the " ++ profileName other ++ " profile has no typed-IR native lowering in M2")
