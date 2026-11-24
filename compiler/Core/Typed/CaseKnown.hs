{-# LANGUAGE FlexibleContexts #-}
-- Case of a known constructor, through case-of-case and let-bound constructors.
-- A `case` whose scrutinee is (or ends in, through lets, sequences, ifs,
-- nested cases, or let-bound constructors/tuples with trivial fields) a
-- constructor or tuple value selects its alternative statically and binds the
-- fields in place, so the value is never built. Evaluation and trap order are
-- kept: the fields are evaluated by the same lets, in the same order, before
-- the chosen alternative. Alternatives are moved, never copied, so a rewrite
-- declines whenever two leaves would select the same one. Anything not
-- provably known (an unknown leaf, a guard, a nested pattern) leaves the case
-- untouched.
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

data Known=Con String [Expr] | Tup [Expr] | Rec (M.Map String Expr)
-- Yes carries the binding wrappers, outermost (first field) first.
data Result=NoMatch | Unsure | Yes [Expr -> Expr]

rewrite :: TypeContext -> Function -> (Function,Bool)
rewrite (TypeContext _ constructors) input=go (4::Int) False (functionBody input)
  where
    go 0 anyChanged b=(input {functionBody=b},anyChanged)
    go rounds anyChanged b=
      let (b',Any changed)=runWriter (walk M.empty b)
       in if changed then go (rounds-1) True b' else (input {functionBody=b'},anyChanged)

    walk env e=case exprNode e of
      Let b rhs body -> do
        rhs'<-walk env rhs
        let (rhsWrap,rhsCore)=stripEntryTicks rhs'
            env1=case known env (unNote rhsCore) of
              Just k | all trivial (fields k)->M.insert (binderId b) k env
              _->env
        body'<-walk env1 body
        let e'=e {exprNode=Let b rhs' body'}
        case peelCaseTarget (binderId b) body' of
          Just (bodyWrap,alts,fb) | Just r<-evalStateT (leaf env e' alts rhs') S.empty ->
            tell (Any True) >> pure (bodyWrap r)
          _->case M.lookup (binderId b) env1 of
            Just _ | binderId b `notElem` localUses body' ->
              tell (Any True) >> pure (rhsWrap body')
            _->pure e'
      MatchTail (FunctionMatch _) args [Alternative ps [] body] _
        | length ps == length args, Just wrap <- irrefutableBinds ps args -> do
            tell (Any True)
            walk env (wrap body)
      Match (FunctionMatch _) args [Alternative ps [] body]
        | length ps == length args, Just wrap <- irrefutableBinds ps args -> do
            tell (Any True)
            walk env (wrap body)
      MatchTail CaseMatch [x] alts fb -> do
        alts'<-mapM (walkAlt env) alts
        fb'<-walk env fb
        let e'=e {exprNode=MatchTail CaseMatch [x] alts' fb'}
        case exprNode (unNote x) of
          Var (Local sid) | Just k<-M.lookup sid env,
            Just r<-evalStateT (select e' alts' x k) S.empty ->
              tell (Any True) >> pure r
          _->pure e'
      Match CaseMatch [x] alts -> do
        alts'<-mapM (walkAlt env) alts
        let e'=e {exprNode=Match CaseMatch [x] alts'}
        case exprNode (unNote x) of
          Var (Local sid) | Just k<-M.lookup sid env,
            Just r<-evalStateT (select e' alts' x k) S.empty ->
              tell (Any True) >> pure r
          _->pure e'
      RecordField base [field] -> do
        base'<-walk env base
        case known env (unNote base') of
          -- Inline record literals can reach this fold (not only env
          -- entries, which already require every field trivial). Dropping
          -- a non-trivial sibling would skip its traps/effects.
          Just (Rec fm) | Just val<-M.lookup field fm, sameType (exprType e) (exprType val),
            all trivial [v | (f,v) <- M.toList fm, f /= field] ->
            tell (Any True) >> pure val
          _->pure e {exprNode=RecordField base' [field]}
      _->mapChildrenM (walk env) e

    irrefutableBinds ps args=foldr step (Just id) (zip ps args)
      where
        step (p,a) acc=case (patNode p,acc) of
          (Bind b,Just w) | sameType (binderType b) (exprType a)->Just (\r->generated r (Let b a (w r)))
          (Wildcard,Just w)->Just (\r->if trivial a then w r else generated r (Sequence a (w r)))
          _->Nothing

    walkAlt env (Alternative ps gs body)=do
      gs'<-mapM (walkGuard env) gs
      body'<-walk env body
      pure (Alternative ps gs' body')
    walkGuard env (BoolGuard g)=BoolGuard <$> walk env g
    walkGuard env (PatternGuard p g)=PatternGuard p <$> walk env g

    -- Strip leading EntryTick wrappers (inserted by Core.Typed.Inline) while
    -- returning a wrapper that preserves the tick in place.
    stripEntryTicks e=case exprNode (unNote e) of
      Sequence a rest | isEntryTick a ->
        let (w,core)=stripEntryTicks rest
         in (\x->generated x (Sequence a (w x)),core)
      Let tb a rest | isEntryTick a, binderId tb `notElem` localUses rest ->
        let (w,core)=stripEntryTicks rest
         in (\x->generated x (Sequence a (w x)),core)
      _->(id,e)

    isEntryTick e=case exprNode (unNote e) of EntryTick->True; _->False

    -- Match `body` when it is either `MatchTail CaseMatch [Var sid] alts fb`
    -- (with `sid` unused in `alts`/`fb`) or a chain of single-use aliases and
    -- inlined EntryTicks leading to that MatchTail.
    peelCaseTarget sid body=case exprNode (unNote body) of
      MatchTail CaseMatch [x] alts fb
        | Var (Local xid)<-exprNode (unNote x), xid==sid, not (usedInArms sid alts fb) ->
            Just (id,alts,fb)
      Match CaseMatch [x] alts
        | Var (Local xid)<-exprNode (unNote x), xid==sid, not (any (usedInAlt sid) alts) ->
            Just (id,alts,body)
      Sequence a rest | isEntryTick a -> do
        (w,alts,fb)<-peelCaseTarget sid rest
        pure (\x->generated x (Sequence a (w x)),alts,fb)
      Let tb a rest | isEntryTick a, binderId tb `notElem` localUses rest -> do
        (w,alts,fb)<-peelCaseTarget sid rest
        pure (\x->generated x (Sequence a (w x)),alts,fb)
      Let b rhs rest
        | Var (Local xid)<-exprNode (unNote rhs), xid==sid, sid `notElem` localUses rest ->
            peelCaseTarget (binderId b) rest
      _->Nothing

    usedInArms sid alts fb=sid `elem` localUses fb || any (usedInAlt sid) alts
    usedInAlt sid (Alternative _ gs b)=sid `elem` localUses b || any (elem sid . guardUses) gs
      where
        guardUses (BoolGuard g)=localUses g
        guardUses (PatternGuard _ g)=localUses g
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
    isIntLit e=case exprNode (unNote e) of IntValue _->True; _->False
    trivial e=case exprNode (unNote e) of
      Var {}->True;IntValue _->True;StringValue _->True;BoolValue _->True;ClosureValue {}->True
      Apply {} | (h,args)<-spine e [], Var (Global n _)<-exprNode h,
        n `elem` ["f64frombits","f32frombits"], all isIntLit args -> True
      _->False
    known env e=case exprNode e of
      Var (Local sid)->M.lookup sid env
      Construct n xs->Just (Con n xs)
      TupleValue xs->Just (Tup xs)
      RecordValue fs->Just (Rec (M.fromList fs))
      Var (Global n _) | arity n==Just 0->Just (Con n [])
      Apply {} | (h,args)<-spine e [],Var (Global n _)<-exprNode h,Just k<-arity n,k>0,k==length args->Just (Con n args)
      _->Nothing
    -- One scrutinee leaf, in the context that `outer` (the whole case) replaces.
    leaf env outer alts s=let e=unNote s in case exprNode e of
      Let b rhs rest->
        let (_,rhsCore)=stripEntryTicks rhs
            env'=case known env (unNote rhsCore) of
              Just k | all trivial (fields k)->M.insert (binderId b) k env
              _->env
         in node e . Let b rhs <$> leaf env' outer alts rest
      Sequence a rest->node e . Sequence a <$> leaf env outer alts rest
      If c t f->node e <$> (If c <$> leaf env outer alts t <*> leaf env outer alts f)
      MatchTail style xs inner fb->do
        inner'<-mapM (\(Alternative ps gs b)->Alternative ps gs <$> leaf env outer alts b) inner
        fb'<-leaf env outer alts fb
        pure (node e (MatchTail style xs inner' fb'))
      Fail m->pure (node e (Fail m))
      _->lift (known env e) >>= select outer alts e
      where
        node old n=old {exprType=exprType outer,exprShape=exprShape outer,exprOrigin=Generated,exprNode=n}
    select _ alts e k=goAlt (0::Int) alts
      where
        goAlt _ []=lift Nothing
        goAlt i (Alternative [p] gs body:rest)=case matchPat e k p of
          NoMatch->goAlt (i+1) rest
          Yes binds | null gs->do
            used<-get
            guard (i `S.notMember` used)
            put (S.insert i used)
            pure (foldr ($) body binds)
          _->lift Nothing
        goAlt _ _=lift Nothing
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
    fields (Rec fm)=M.elems fm
    skip a rest=generated rest (Sequence a rest)
    subs ps args
      | length ps/=length args=Unsure
      | otherwise=foldr combine (Yes []) (zip ps args)
    combine (p,a) acc=case (patNode p,acc) of
      (Wildcard,Yes bs)->Yes ([skip a | not (trivial a)]++bs)
      (Bind b,Yes bs) | sameType (binderType b) (exprType a)->Yes ((\rest->generated rest (Let b a rest)):bs)
      _->Unsure
    generated rest n=rest {exprOrigin=Generated,exprNode=n}
