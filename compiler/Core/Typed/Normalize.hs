-- Normalize checked Base entries without losing types or lexical identities.
-- Only literals/local aliases disappear. Effectful bindings retain strict
-- order; a pending binding sinks only into the next RHS that uses it last.
module Core.Typed.Normalize (normalizeClosed) where
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Verify (sameType,instanceOf)
import Core.Typed.Walk
import Core.Identity (BinderId)
import Type.Syntax (Type(..))
import Core.Primitives (entryTickName)
import Compiler.VectorLayout (builderRuntimeName)
import qualified Core.VectorRead as Read
import Core.Region.Runtime (Hook(..),hookName)
import Control.Monad.Identity
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

normalizeClosed :: TypeContext -> ClosedFunction -> Either String ClosedFunction
normalizeClosed types=mapClosed types (Right . normalize)
  (\code->let f=normalize (codeAsFunction code) in Right code {codeBody=functionBody f})

normalize :: Function -> Function
normalize input=input {functionBody=go M.empty body0}
  where
    body0=functionBody input
    binders=functionParameters input++allBinders body0
    scope=M.fromList [(binderId b,b) | b<-binders]
    spellings=M.fromListWith (+) [(binderName b,1::Int) | b<-binders]
    globals=globalNames body0
    -- Vector fusion and physical pipeline planning consume explicit producers.
    -- Preserve this canonical input rather than hiding producers in RHS lets.
    pinned=pinnedLocals body0<>S.fromList [binderId b | b<-binders,vector (binderType b)]
    vector (TAp (TC "Vector") _)=True
    vector _=False
    uses=referenceTypes body0
    -- Hoisting may broaden scope. Unique IDs prevent semantic capture;
    -- decline when the compatibility printer would capture another spelling.
    unambiguous b=M.lookup (binderName b) spellings==Just 1
    mayHoist b=unambiguous b && binderName b `S.notMember` globals
    generated old result node=old {exprType=exprType result,exprShape=exprShape result,exprOrigin=Generated,exprNode=node}
    binding old b rhs rest=generated old rest (Let b rhs rest)
    unNote e=case exprNode e of Note x->unNote x;_->e
    go env input=let e=unNote input in case exprNode e of
      Var (Local uid) | Just value<-M.lookup uid env->e {exprNode=exprNode value}
      Let b rhs rest->chain env (counts env e) [] e b rhs rest
      _->rewrite (runIdentity (mapChildrenM (pure . go env) e))
    -- Counts describe the remaining *canonical* references. An eliminated
    -- alias transfers its future uses, and later RHSs debit that same target.
    chain env left pending old b rhs rest=
      let rhs'=go env rhs
          here=counts env rhs
          remaining=M.differenceWith (\n used->Just (n-used)) left here
          uid=binderId b
          finish env' counts'=next env' counts' pending rest
      in if uid `S.member` pinned || not (unambiguous b) then keep env remaining here pending old b rhs' rest else
        case exprNode rhs' of
          IntValue _->finish (M.insert uid rhs' env) (M.delete uid remaining)
          Var (Local target) | safeAlias uid target->
            let n=M.findWithDefault 0 uid remaining
            in finish (M.insert uid rhs' env) (M.insertWith (+) target n (M.delete uid remaining))
          _->keep env remaining here pending old b rhs' rest
    keep env left here pending old b rhs rest=
      let (rhs',pending')=absorb left here pending rhs
      in next (M.delete (binderId b) env) left ((old,b,rhs'):pending') rest
    next env left pending rest=case exprNode (unNote rest) of
      Let b rhs body->chain env left pending (unNote rest) b rhs body
      _->foldl (\out (old,b,rhs)->rewrite (binding old b rhs out)) (go env rest) pending
    absorb left here pending rhs=case pending of
      (old,b,value):more | binderId b `S.notMember` pinned,
        M.member (binderId b) here,M.findWithDefault 0 (binderId b) left==0->
        absorb left here more (rewrite (binding old b value rhs))
      _->(rhs,pending)
    safeAlias uid target=case M.lookup target scope of
      Just b->M.lookup (binderName b) spellings==Just 1
        && all (instanceOf (binderScheme b)) (M.findWithDefault [] uid uses)
      _->False
    counts env=walk M.empty
      where
        add acc uid=case M.lookup uid env of
          Just value->case exprNode value of
            IntValue _->acc
            Var (Local target)->M.insertWith (+) target (1::Int) acc
            _->acc
          Nothing->M.insertWith (+) uid (1::Int) acc
        walk acc e=foldl walk (foldl add acc (directUses e)) (children e)
    occurs uid e=uid `elem` directUses e || any (occurs uid) (children e)
    rewrite e=case exprNode e of
      Let b rhs body | unambiguous b,Var (Local uid)<-exprNode body,uid==binderId b,
        sameType (exprType rhs) (exprType e)->rhs
      Let b rhs body | unambiguous b,If cond yes no<-exprNode body,
        not (occurs (binderId b) yes || occurs (binderId b) no)->case exprNode cond of
          Var (Local uid) | uid==binderId b->rewrite (generated e yes (If rhs yes no))
          BoolTest flag x | Var (Local uid)<-exprNode x,uid==binderId b->
            rewrite (generated e yes (If (cond {exprNode=BoolTest flag rhs}) yes no))
          _->e
      If cond yes no | Let b rhs value<-exprNode cond,mayHoist b,
        not (occurs (binderId b) yes || occurs (binderId b) no)->
          rewrite (binding cond b rhs (rewrite (generated e yes (If value yes no))))
      _->e

children :: Expr -> [Expr]
children e=getConst (mapChildrenM (Const . (:[])) e)
directUses :: Expr -> [BinderId]
directUses e=case exprNode e of
  Var (Local uid)->[uid]
  ClosureValue _ ids->ids
  CodeCall _ ids _->ids
  JoinCall _ ids _->ids
  _->[]
referenceTypes :: Expr -> M.Map BinderId [Type]
referenceTypes=walk M.empty
  where
    walk acc e=foldl walk (case exprNode e of
      Var (Local uid)->M.insertWith (++) uid [exprType e] acc
      _->acc) (children e)

-- Include symbols introduced by layout lowering, not only explicit globals.
globalNames :: Expr -> S.Set String
globalNames e=own<>S.unions (map globalNames (children e))
  where
    own=S.fromList $ case exprNode e of
      Var (Global n _)->[n]
      ClosureValue (CodeId n) _->[n]
      CodeCall (CodeId n) _ _->[n]
      JoinCall (CodeId n) _ _->[n]
      EntryTick->[entryTickName]
      VectorBuild builder _->[builderRuntimeName builder]
      VectorReadPair op _ _->[Read.peekName op]
      CallRegion _->map hookName [CallPending,CallLeave]
      ListValue _->["Cons","Nil"]
      ResultPipe {}->["Err"]
      _->["==" | any literal (patterns e)]
    literal p=case patNode p of
      IntegerPattern _->True;StringPattern _->True
      ConstructorPattern _ ps->any literal ps
      TuplePattern ps->any literal ps
      _->False
    patterns e=case exprNode e of
      LetPattern p _ _->[p]
      Match _ _ as->concatMap alternative as
      MatchTail _ _ as _->concatMap alternative as
      _->[]
    alternative (Alternative ps gs _)=ps++[p | PatternGuard p _<-gs]
