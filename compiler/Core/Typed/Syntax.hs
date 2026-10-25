-- Typed expressions before closure lifting. Identities, not display spellings,
-- resolve local references. Erasure is an explicit boundary for passes that
-- have not migrated yet; it is not a typed optimization result.
module Core.Typed.Syntax
  ( Binder(..), Reference(..), Origin(..), Expr(..), Node(..), Function(..), TypeContext(..), Pattern(..), PatNode(..), Alternative(..), Guard(..), MatchStyle(..), patternBinders,
    binderType, functionType ) where
import Source.Span (SourceOffset)
import Core.Identity
import Type.Syntax (Type(..), Scheme(..))
import Ownership.Shape (LShape)
import qualified Data.Map.Strict as M

data Binder = Binder
  { binderId :: !BinderId, binderName :: String,
    binderScheme :: Scheme, binderShape :: LShape } deriving (Show)
data Reference = Local !BinderId | Global String Scheme deriving (Show)
data Origin = Checked !ExprId | Reinstantiated !ExprId | Generated deriving (Eq, Show)
data Expr = Expr
  { exprType :: Type, exprShape :: LShape, exprOrigin :: Origin,
    exprOffset :: Maybe SourceOffset, exprNode :: Node } deriving (Show)
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
  | Construct String [Expr]
  | AtomValue String
  | TupleValue [Expr]
  | ListValue [Expr]
  | RecordValue [(String,Expr)]
  | RecordField Expr [String]
  | RecordUpdate Expr [([String],Expr)]
  | ResultPipe Expr Expr
  | Sequence Expr Expr
  | LetPattern Pattern Expr Expr
  | Match MatchStyle [Expr] [Alternative]
  deriving (Show)
data Pattern = Pattern
  { patType :: Type, patDisplay :: String, patNode :: PatNode } deriving (Show)
data PatNode = Bind Binder | Wildcard | IntegerPattern Integer | StringPattern String
  | ConstructorPattern String [Pattern] | TuplePattern [Pattern]
  | RecordPattern [(String,Binder)] deriving (Show)
data Guard = BoolGuard Expr | PatternGuard Pattern Expr deriving (Show)
data Alternative = Alternative [Pattern] [Guard] Expr deriving (Show)
data MatchStyle = CaseMatch | FunctionMatch String deriving (Eq,Show)
data TypeContext = TypeContext [String] (M.Map String Scheme) deriving (Show)
patternBinders :: Pattern -> [Binder]
patternBinders p = case patNode p of
  Bind b -> [b]
  ConstructorPattern _ ps -> concatMap patternBinders ps
  TuplePattern ps -> concatMap patternBinders ps
  RecordPattern fs -> map snd fs
  _ -> []
data Function = Function
  { functionName :: String, functionParameters :: [Binder],
    functionBody :: Expr } deriving (Show)
binderType :: Binder -> Type
binderType b = case binderScheme b of Forall _ _ t -> t
functionType :: Function -> Type
functionType f = foldr (TFn . binderType) (exprType (functionBody f)) (functionParameters f)
