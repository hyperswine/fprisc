-- Effect-order evidence over checked lexical/code identities, before erasure.
module Core.Typed.FusionSafety (Safety,Reason(..),planSafety,unsafeTarget,unsafeExpression,renderReason) where
import Core.Typed.Syntax
import Core.Typed.Callback.Model
import Core.Typed.Walk (mapChildrenM)
import Core.FusionPolicy (safePrimitives)
import Core.Primitives (primArities,entryTickName)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Lazy as M
import qualified Data.Set as S

data Reason=UnknownFunction Target | Primitive String | Partial Target
  | UnknownCall String | FunctionValue Target | Recursive Target | Failure | Unsupported String
  deriving (Eq,Show)
data Evidence=Ref Target | Refusal Reason
data Safety=Safety (M.Map Target Template) (M.Map Target [Evidence])

-- Body summaries are lazy and shared. A large program need not inspect every
-- unrelated callback body merely because one vector site asks for evidence.
planSafety :: M.Map Target Template -> Safety
planSafety templates=Safety templates (M.map (\(Template _ _ body _ _)->facts templates body) templates)

unsafeTarget :: Safety -> Target -> Maybe Reason
unsafeTarget safety=target safety S.empty
target :: Safety -> S.Set Target -> Target -> Maybe Reason
target safety@(Safety _ summaries) seen key
  | key `S.member` seen=Just (Recursive key)
  | otherwise=case M.lookup key summaries of
      Nothing->Just (UnknownFunction key)
      Just evidence->resolve safety (S.insert key seen) evidence
resolve _ _ []=Nothing
resolve _ _ (Refusal reason:_)=Just reason
resolve safety seen (Ref key:rest)=case target safety seen key of
  Nothing->resolve safety seen rest
  result->result
unsafeExpression :: Safety -> Expr -> Maybe Reason
unsafeExpression safety@(Safety templates _) e=resolve safety S.empty (facts templates e)

facts :: M.Map Target Template -> Expr -> [Evidence]
facts templates e=case exprNode (unNote e) of
  Apply {}->let (head',args)=spine e [] in case exprNode head' of
    Var (Global n _) -> call (RootTarget n) n args
    ClosureValue key _->call (CodeTarget key) (label (CodeTarget key)) args
    Var (Local uid)->[Refusal (UnknownCall (show uid))]
    _->[Refusal (Unsupported "a computed call")]
  CodeCall key _ args->call (CodeTarget key) (label (CodeTarget key)) args
  JoinCall key _ args->call (CodeTarget key) (label (CodeTarget key)) args
  Var (Local _)->[]
  Var (Global n _) | Just (Template _ [] _ _ _)<-M.lookup (RootTarget n) templates->[Ref (RootTarget n)]
  Var (Global n _)->[Refusal (FunctionValue (RootTarget n))]
  ClosureValue key _->[Refusal (FunctionValue (CodeTarget key))]
  Fail _->[Refusal Failure]
  -- Unreachability belongs to the frontend-checked match protocol, not to
  -- Generated origin: generated constructor/hole traps can execute as well.
  MatchTail _ args alternatives fallback->concatMap (facts templates) args
    ++concatMap alternative alternatives++case exprNode (unNote fallback) of
      Fail _ | exprOrigin (unNote fallback)==Generated->[]
      _->facts templates fallback
  LetPattern pattern rhs body->facts templates rhs
    ++(if irrefutable pattern then [] else [Refusal Failure])++facts templates body
  VectorBuild {}->[Refusal (Primitive "vector allocation")]
  VectorReadPair {}->[Refusal (Primitive "vector read")]
  CallRegion {}->[Refusal (Unsupported "a region operation")]
  ResultPipe {}->[Refusal (Unsupported "a result pipeline")]
  _->children
  where
    children=getConst (mapChildrenM (Const . facts templates) (unNote e))
    call key name args
      | name==entryTickName=[]
      | name `elem` ["f64frombits","f32frombits"],all int args,
        lookup name primArities==Just (length args)=[]
      | Just (Template _ ps _ _ _)<-M.lookup key templates=
          if length ps==length args then concatMap (facts templates) args++[Ref key]
          else [Refusal (Partial key)]
      | name `elem` safePrimitives=
          if lookup name primArities==Just (length args) then concatMap (facts templates) args
          else [Refusal (Partial key)]
      | otherwise=[Refusal (Primitive name)]
    int x=case exprNode (unNote x) of IntValue _->True;_->False
    alternative (Alternative _ guards body)=concatMap guard guards++facts templates body
    guard (BoolGuard x)=facts templates x
    guard (PatternGuard _ x)=facts templates x
    irrefutable pattern=case patNode pattern of
      Bind _->True;Wildcard->True;RecordPattern _->True
      TuplePattern patterns->all irrefutable patterns
      _->False
label (RootTarget n)=n
label (CodeTarget (CodeId n))=n
renderReason :: Reason -> String
renderReason reason=case reason of
  UnknownFunction key->"`"++label key++"` is not a known function"
  Primitive n->"the primitive `"++n++"`"
  Partial key->"a partial application of `"++label key++"`"
  UnknownCall n->"a call through the parameter `"++n++"` (unknown function)"
  FunctionValue key->"the function value `"++label key++"`"
  Recursive key->"recursion through `"++label key++"` without termination evidence"
  Failure->"a possible failure"
  Unsupported construct->construct
