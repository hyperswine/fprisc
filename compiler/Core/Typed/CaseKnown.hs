{-# LANGUAGE FlexibleContexts #-}
-- Case of a known constructor, through case-of-case. A `case` whose scrutinee
-- is (or ends in, through lets, sequences, ifs and nested cases) a constructor
-- or tuple value selects its alternative statically and binds the fields in
-- place, so the value is never built. Evaluation and trap order are kept: the
-- fields are evaluated by the same lets, in the same order, before the chosen
-- alternative. Alternatives are moved, never copied, so a rewrite declines
-- whenever two leaves would select the same one. Anything not provably known
-- (an unknown leaf, a guard, a nested pattern) leaves the case untouched.
module Core.Typed.CaseKnown (caseKnownClosed) where
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Verify (sameType)
import Core.Typed.Walk
import Type.Syntax (Type(..),Scheme(..))
import Control.Monad (guard)
import Control.Monad.State.Strict
import Control.Monad.Writer.Strict
import Data.Monoid (Any(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- The Bool reports whether any case was resolved.
caseKnownClosed :: TypeContext -> ClosedFunction -> Either String (ClosedFunction,Bool)
caseKnownClosed types=mapClosedChanged types (Right . rewrite types)
  (\code->let (f,changed)=rewrite types (codeAsFunction code) in Right (code {codeBody=functionBody f},changed))

data Known=Con String [Expr] | Tup [Expr]
-- Yes carries the binding wrappers, outermost (first field) first.
data Result=NoMatch | Unsure | Yes [Expr -> Expr]

rewrite :: TypeContext -> Function -> (Function,Bool)
rewrite (TypeContext _ constructors) input=(input {functionBody=body},changed)
  where
    (body,Any changed)=runWriter (walk (functionBody input))
    walk e=mapChildrenM walk e >>= \e'->case exprNode e' of
      -- Closure conversion lowers `case x of ...` to a let of the scrutinee
      -- and a match tail on that fresh, otherwise unused, binder.
      Let sb rhs m | MatchTail CaseMatch [x] alts _<-exprNode m,Var (Local sid)<-exprNode x,sid==binderId sb,
                     length (filter (==sid) (localUses m))==1,
                     Just r<-evalStateT (leaf e' alts rhs) S.empty->tell (Any True) >> pure r
      _->pure e'
    arity name=case M.lookup name constructors of
      Just (Forall _ _ t)->Just (count t)
      Nothing->Nothing
    count (TFn _ t)=1+count t
    count _=0::Int
    unNote e=case exprNode e of Note x->unNote x;_->e
    spine e args=case exprNode e of
      Apply fn arg->spine fn (arg:args)
      Note x->spine x args
      _->(e,args)
    trivial e=case exprNode (unNote e) of
      Var {}->True;IntValue _->True;StringValue _->True;BoolValue _->True;AtomValue _->True;ClosureValue {}->True
      _->False
    known e=case exprNode e of
      Construct n xs->Just (Con n xs)
      TupleValue xs->Just (Tup xs)
      Var (Global n _) | arity n==Just 0->Just (Con n [])
      Apply {} | (h,args)<-spine e [],Var (Global n _)<-exprNode h,Just k<-arity n,k>0,k==length args->Just (Con n args)
      _->Nothing
    -- One scrutinee leaf, in the context that `outer` (the whole case) replaces.
    leaf outer alts s=let e=unNote s in case exprNode e of
      Let b rhs rest->node e . Let b rhs <$> leaf outer alts rest
      Sequence a rest->node e . Sequence a <$> leaf outer alts rest
      If c t f->node e <$> (If c <$> leaf outer alts t <*> leaf outer alts f)
      MatchTail style xs inner fb->do
        inner'<-mapM (\(Alternative ps gs b)->Alternative ps gs <$> leaf outer alts b) inner
        fb'<-leaf outer alts fb
        pure (node e (MatchTail style xs inner' fb'))
      Fail m->pure (node e (Fail m))
      _->lift (known e) >>= select e
      where
        node old n=old {exprType=exprType outer,exprShape=exprShape outer,exprOrigin=Generated,exprNode=n}
        select e k=go (0::Int) alts
          where
            go _ []=lift Nothing
            go i (Alternative [p] gs body:rest)=case matchPat e k p of
              NoMatch->go (i+1) rest
              Yes binds | null gs->do
                used<-get
                guard (i `S.notMember` used)
                put (S.insert i used)
                pure (foldr ($) body binds)
              _->lift Nothing
            go _ _=lift Nothing
    matchPat leafExpr k p=case (patNode p,k) of
      (Wildcard,_)->Yes [skip a | a<-fields k,not (trivial a)]
      (Bind b,_)->Yes [\rest->generated rest (Let b leafExpr rest)]
      (ConstructorPattern c ps,Con n args)
        | c/=n->NoMatch
        | otherwise->subs ps args
      (TuplePattern ps,Tup args)->subs ps args
      _->Unsure
    fields (Con _ xs)=xs
    fields (Tup xs)=xs
    skip a rest=generated rest (Sequence a rest)
    subs ps args
      | length ps/=length args=Unsure
      | otherwise=foldr combine (Yes []) (zip ps args)
    combine (p,a) acc=case (patNode p,acc) of
      (Wildcard,Yes bs)->Yes ([skip a | not (trivial a)]++bs)
      (Bind b,Yes bs) | sameType (binderType b) (exprType a)->Yes ((\rest->generated rest (Let b a rest)):bs)
      _->Unsure
    generated rest n=rest {exprOrigin=Generated,exprNode=n}
