-- Pass-owned advisory decisions. These are not checking evidence and never
-- select an optimization. Owners identify original source definitions.
module Core.Typed.Decision (Decision(..),InlineReason(..),CallbackReason(..)) where
data InlineReason=Inlined | RecursiveCallee | NullaryCallee
  | OverWeight Int Int -- observed weight (or lower bound), limit
  | UsesForbiddenGlobal [String] | ArityMismatch Int Int Int Int
  | ContractInstantiation deriving (Eq,Ord,Show)
data CallbackReason=Specialized | OverArity Int Int | TooDeep Int Int
  | TooManyClones Int Int | OverNodeBudget Int Int | Unification
  | EscapingType | RetainedArityOverflow | NoKnownArgument | Unstable | UnsafeArgument | UnknownTarget
  deriving (Eq,Ord,Show)
data Decision=InlineDecision String String InlineReason
  | CallbackDecision String String CallbackReason deriving (Eq,Ord,Show)
