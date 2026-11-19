-- Ownership proof obligations and source violations are different results.
-- Neither the checker nor its fixpoint driver discovers constraints in prose.
module Ownership.Finding (Finding(..), atFinding) where
import Source.Span
data Finding = RequireUnrestricted String | Violation (Maybe SourceOffset) String
  deriving (Eq,Ord,Show)
atFinding :: SourceOffset -> Finding -> Finding
atFinding offset (Violation Nothing message)=Violation (Just offset) message
atFinding _ finding=finding
