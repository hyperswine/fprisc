-- Typed expressions through layout planning and closure lifting. Identities, not display spellings,
-- resolve local references. Erasure is an explicit boundary for passes that
-- have not migrated yet; it is not a typed optimization result.
module Core.Typed.Syntax
  ( Binder(..), Reference(..), Origin(..), Expr(..), Node(..), Function(..), TypeContext(..), Pattern(..), PatNode(..), Alternative(..), Guard(..), MatchStyle(..), patternBinders,
    CodeId(..), CodeKind(..), CodeFunction(..), CodeContract(..), codeContract, codeAsFunction,
    UpdatePlan(..), UpdateBranch(..), UpdateField(..),
    binderType, functionType, lambdaView ) where
import Source.Span (SourceOffset)
import Core.Identity
import Type.Syntax (Type(..), Scheme(..))
import Ownership.Shape (LShape)
import qualified Data.Map.Strict as M
import Compiler.VectorLayout (VectorBuilder)

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
  | LetRec Binder Expr Expr
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
  | PlannedUpdate Expr UpdatePlan
  | ResultPipe Expr Expr
  | Sequence Expr Expr
  | LetPattern Pattern Expr Expr
  | Match MatchStyle [Expr] [Alternative]
  | ClosureValue CodeId [BinderId]
  | JoinCall CodeId [BinderId] [Expr]
  | MatchTail MatchStyle [Expr] [Alternative] Expr
  | Fail String
  | LayoutLiteral String
  | VectorBuild VectorBuilder Expr
  deriving (Show)
-- Layout copies retain opaque row fields without inventing language types for
-- them. Only replacements contain expressions, each with its checked type.
data UpdatePlan = UpdatePlan [String] [UpdateBranch] deriving (Show)
data UpdateBranch = UpdateBranch Int [(String,UpdateField)] deriving (Show)
data UpdateField = KeepField | ReplaceField Expr | NestedUpdate UpdatePlan deriving (Show)
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
-- Capture schemes are separate from the ordinary argument/result arrow.
-- Capturing a let-polymorphic value must not pretend it is a monomorphic arg.
newtype CodeId = CodeId String deriving (Eq,Ord,Show)
data CodeKind = ClosureCode | JoinCode deriving (Eq,Show)
data CodeFunction = CodeFunction
  { codeId :: CodeId, codeKind :: CodeKind, codeCaptures :: [Binder],
    codeParameters :: [Binder], codeBody :: Expr } deriving (Show)
data CodeContract = CodeContract
  { contractKind :: CodeKind, contractCaptures :: [(Scheme,LShape)],
    contractParameters :: [Type], contractResult :: Type } deriving (Show)
codeContract :: CodeFunction -> CodeContract
codeContract f=CodeContract (codeKind f) [(binderScheme b,binderShape b) | b<-codeCaptures f]
  (map binderType (codeParameters f)) (exprType (codeBody f))
codeAsFunction :: CodeFunction -> Function
codeAsFunction f=let CodeId name=codeId f in Function name (codeCaptures f++codeParameters f) (codeBody f)
binderType :: Binder -> Type
binderType b = case binderScheme b of Forall _ _ t -> t
functionType :: Function -> Type
functionType f = foldr (TFn . binderType) (exprType (functionBody f)) (functionParameters f)
-- Source notes carry locations, not initialization effects. Recursive locals
-- must initialize a function; arbitrary strict recursive values have no knot.
lambdaView :: Expr -> Maybe ([Binder],Expr)
lambdaView e=case exprNode e of
  Note x->lambdaView x
  Lambda ps body | not (null ps)->Just (ps,body)
  _->Nothing
