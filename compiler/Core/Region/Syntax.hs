-- Typed region control IR. Source expressions keep their checked types;
-- existential receive steps, bundles and raw control cells have separate
-- internal sorts. They never masquerade as source tuples or arrow types.
module Core.Region.Syntax
  (ControlType(..),Control(..),Parameter(..),Result(..),Cell(..),Contract(..),Route(..),
   Call,makeCall,callWitness,callRoute,callArguments,decodeCall,Flow(..),Alternative(..),Slot(..),Body(..),Function(..),
   parameterId,parameterName,functionContract) where
import qualified Core.Typed.Syntax as T
import Core.Identity
import Type.Syntax (Type,Scheme)
import Ownership.Shape (LShape)
import qualified Data.Map.Strict as M
import Control.Monad (unless)

data ControlType=Mark | Sequence | Tick | State [Scheme] deriving Show
data Control=Control {controlId :: BinderId,controlName :: String,controlType :: ControlType} deriving Show
data Parameter=ValueParameter T.Binder | ControlParameter Control deriving Show
data Result=ValueResult Type | ReceiveStep Type deriving Show
data Cell=ValueCell Scheme LShape | InternalCell ControlType deriving Show
data Contract=Contract {contractParameters :: [Cell],contractResult :: Result} deriving Show
data Route=Route
  { routeSource :: String,routeLabel :: String,routeBoundary :: Bool,
    routeLive :: [Int],routeParameters :: [T.Binder] } deriving Show
-- The original checked call witnesses the relation between a target's
-- polymorphic interface, these actual operands and its instantiated result.
data Call=Call T.Expr Route [T.Expr] deriving Show
callWitness (Call e _ _)=e
callRoute (Call _ r _)=r
callArguments (Call _ _ args)=args
makeCall :: M.Map BinderId T.Binder -> Route -> T.Expr -> Either String Call
makeCall scope route witness=case decodeCall scope witness of
  Just (name,args) | name==routeSource route->do
    unless (length args==length (routeParameters route)) (Left "typed region call: physical arity mismatch")
    pure (Call witness route args)
  _->Left "typed region call: witness/route mismatch"
decodeCall :: M.Map BinderId T.Binder -> T.Expr -> Maybe (String,[T.Expr])
decodeCall scope e=case T.exprNode e of
  T.CodeCall (T.CodeId n) cs args->(,) n . (++args) <$> captures cs
  T.JoinCall (T.CodeId n) cs args->(,) n . (++args) <$> captures cs
  T.Note x->decodeCall scope x
  _->case spine e [] of
    (T.Expr _ _ _ _ (T.Var (T.Global n _)),args)->Just (n,args)
    (T.Expr _ _ _ _ (T.ClosureValue (T.CodeId n) cs),args)->(,) n . (++args) <$> captures cs
    _->Nothing
  where
    captures=mapM (\uid->do b<-M.lookup uid scope
                            pure (T.Expr (T.binderType b) (T.binderShape b) T.Generated Nothing (T.Var (T.Local uid))))
    spine x args=case T.exprNode x of T.Apply f a->spine f (a:args);T.Note f->spine f args;_->(x,args)
data Flow
  = Value T.Expr
  | Bind T.Binder T.Expr Flow
  | BindPattern T.Pattern T.Expr Flow
  | Then T.Expr Flow
  | Branch T.Expr Flow Flow
  | Note Flow
  | Match T.MatchStyle [T.Expr] [Alternative] Flow
  | Tail Call
  deriving Show
data Alternative=Alternative [T.Pattern] [T.Guard] Flow deriving Show
-- A dead logical slot has no typed runtime value. Its zero placeholder is
-- permitted only by the retained liveness proof, never by type coercion.
data Slot=LiveSlot T.Binder Int | DeadSlot T.Binder deriving Show
data Body
  = Original
  | Ordinary T.Expr
  -- True: a receive loop, whose region opens at entry
  | LoopEntry Bool String [T.Binder] Control Control
  | LoopInner (Maybe String) [T.Binder] Control Control Flow
  | LoopCycle String [T.Binder] [Int] Control Control
  | ReceiveEntry String [T.Binder] [Int]
  | ReceiveThunk Control Control [Slot] Flow
  | ReceiveLocal Flow
  deriving Show
data Function=Function
  { functionLabel :: String,functionOwner :: String,functionSourceName :: String,
    functionSource :: T.Function,functionParameters :: [Parameter],
    functionResult :: Result,functionBody :: Body,
    functionContracts :: M.Map T.CodeId T.CodeContract,
    functionBinderOrigins :: [(BinderId,BinderId)] } deriving Show
parameterId (ValueParameter b)=T.binderId b
parameterId (ControlParameter b)=controlId b
parameterName (ValueParameter b)=T.binderName b
parameterName (ControlParameter b)=controlName b
functionContract f=Contract (map cell (functionParameters f)) (functionResult f)
  where cell (ValueParameter b)=ValueCell (T.binderScheme b) (T.binderShape b)
        cell (ControlParameter b)=InternalCell (controlType b)
