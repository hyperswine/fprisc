-- Typed expressions before closure lifting. Identities, not display spellings,
-- resolve local references. Erasure is an explicit boundary for passes that
-- have not migrated yet; it is not a typed optimization result.
module Core.Typed.Syntax
  ( Binder(..), Reference(..), Origin(..), Expr(..), Node(..), Function(..), TypeContext(..),
    binderType, functionType ) where
import Core.Identity
import Type.Syntax (Type(..), Scheme(..))
import Ownership.Shape (LShape)

data Binder = Binder
  { binderId :: !BinderId, binderName :: String,
    binderScheme :: Scheme, binderShape :: LShape } deriving (Show)
data Reference = Local !BinderId | Global String Scheme deriving (Show)
data Origin = Checked !ExprId | Generated deriving (Eq, Show)
data Expr = Expr
  { exprType :: Type, exprShape :: LShape, exprOrigin :: Origin,
    exprOffset :: Maybe Int, exprNode :: Node } deriving (Show)
data Node
  = Var Reference
  | IntValue Integer
  | StringValue String
  | Apply Expr Expr
  | Lambda [Binder] Expr
  | Let Binder Expr Expr
  | If Expr Expr Expr
  | BoolValue Bool
  | BoolTest Bool Expr
  | Note Expr
  deriving (Show)
newtype TypeContext = TypeContext [String] deriving (Show)
data Function = Function
  { functionName :: String, functionParameters :: [Binder],
    functionBody :: Expr } deriving (Show)
binderType :: Binder -> Type
binderType b = case binderScheme b of Forall _ _ t -> t
functionType :: Function -> Type
functionType f = foldr (TFn . binderType) (exprType (functionBody f)) (functionParameters f)
