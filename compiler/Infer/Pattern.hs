-- The derivation of a pattern's input and field types, retained from inference.
-- Sites link it to lexical checking occurrences without matching source text.
module Infer.Pattern (PatternInfo(..), PatternSite(..), mapPatternTypesM, bindPattern) where
import Core.Identity (ExprId, BinderId)
import qualified Data.Map.Strict as M
import Frontend.Syntax (SPat)
import Type.Syntax (Type)

data PatternSite = ParameterOf String Int Int | GuardOf String Int Int
                 | ArmOf ExprId Int | BindingOf ExprId Int | LocalOf ExprId Int
  deriving (Eq,Ord,Show)
data PatternInfo = PatternInfo
  { matchedSource :: SPat, matchedType :: !Type,
    matchedChildren :: [PatternInfo], matchedBindings :: M.Map String BinderId } deriving (Show)
mapPatternTypesM :: Monad m => (Type -> m Type) -> PatternInfo -> m PatternInfo
mapPatternTypesM solve (PatternInfo p t cs bs) = (\t' cs' -> PatternInfo p t' cs' bs) <$> solve t <*> traverse (mapPatternTypesM solve) cs
bindPattern :: M.Map String BinderId -> PatternInfo -> PatternInfo
bindPattern bs (PatternInfo p t cs _) = PatternInfo p t (map (bindPattern bs) cs) bs
