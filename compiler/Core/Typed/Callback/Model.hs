-- Shared callback templates and role identities. Operand views describe
-- already-evaluated values; they do not infer a callable's physical arity.
module Core.Typed.Callback.Model
  (Target(..),Slot(..),Template(..),ClonePlan(..),unNote,spine,evaluated) where
import Core.Typed.Syntax
import Core.Identity (BinderId)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Target=RootTarget String | CodeTarget CodeId deriving (Eq,Ord,Show)
data Slot=CaptureSlot Int | ArgumentSlot Int deriving (Eq,Ord,Show)
data Template=Template [Binder] [Binder] Expr CodeContract CodeKind
data ClonePlan=ClonePlan Target (S.Set BinderId)
unNote e=case exprNode e of Note x->unNote x;_->e
spine e args=case exprNode e of Apply f a->spine f (a:args);Note x->spine x args;_->(e,args)
evaluated arities e=case exprNode (unNote e) of
  Var (Local _)->True
  Var (Global n _)->maybe False (>0) (M.lookup n arities)
  ClosureValue _ []->True
  IntValue _->True;StringValue _->True;BoolValue _->True;LayoutLiteral _->True
  _->False
