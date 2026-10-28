{-# LANGUAGE FlexibleContexts #-}
-- Inline checked closed entries, before region planning and erasure. Templates
-- retain their code homes; only lexical binders are cloned into the caller.
module Core.Typed.Inline (Inlining,planInlining,inlineClosed,inlineClosedWithDecisions) where
import qualified Core.Typed.Decision as D
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Contract
import Core.Typed.Instantiate
import Core.Typed.Callback.Catalog
import Core.Typed.Callback.Analysis (recursiveCallbacks)
import Core.Typed.Callback.Model (Target(..),Template(..),spine,unNote)
import Core.Typed.Walk
import Core.Identity
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import Control.Monad.State.Strict
import Control.Monad (guard,unless,void,when)
import Control.Monad.Identity (runIdentity)
import Control.Monad.Writer (runWriter,tell)
import Data.Monoid (Any(..))
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- One round against an immutable whole-program snapshot. The pipeline owns
-- the bounded rounds; inserted bodies are not recursively expanded here.
-- Each admitted template keeps its weight: a call site inside a loop (a
-- recursive caller) may take a larger one than a call site elsewhere, since
-- that is where the call is paid per iteration
-- (docs/2026-10-27-FOLLOWUPS.md). Two budgets, weighed once.
data Inlining=Inlining Catalog Int Int (M.Map Target (Either D.InlineReason (Template,S.Set String,Int)))

-- Compute admission once per snapshot, not at every call in every owner.
-- Stop weighing an oversized template as soon as the larger budget is spent.
planInlining :: Int -> Int -> Catalog -> Either String Inlining
planInlining limit loopLimit snapshot=do
  unless (limit>=0 && loopLimit>=0) (Left "typed inline: negative node budget")
  pure (Inlining snapshot limit loopLimit (M.mapWithKey admit (catalogTemplates snapshot)))
  where
    cap=max limit loopLimit
    admit target template@(Template caps ps body _ _)
      | target `S.member` recursiveCallbacks (catalogAnalysis snapshot)=Left D.RecursiveCallee
      | null (caps++ps)=Left D.NullaryCallee
      | Just left<-execStateT (weigh body) cap=Right (template,globals body,cap-left)
      | otherwise=Left (D.OverWeight (cap+1) cap)
    weigh :: Expr -> StateT Int Maybe ()
    weigh e=do
      budget<-get
      let cost=case exprNode e of Note _->0;EntryTick->3;MatchTail {}->4;_->1
      guard (budget>=cost)
      put (budget-cost)
      void (mapChildrenM (\x->weigh x>>pure x) e)
    globals e=(case exprNode e of Var (Global n _)->S.singleton n;_->S.empty)
      <>getConst (mapChildrenM (Const . globals) e)

inlineClosed :: S.Set String -> Namespace -> TypeContext -> M.Map String Int -> Inlining -> ClosedFunction -> Either String ClosedFunction
inlineClosed forbidden namespace types arities plan input=
  (\(f,_,_)->f) <$> inlineClosedWithDecisions False forbidden namespace types arities plan input

-- The Bool reports whether anything was inlined, propagated or renamed.
-- When nothing fired the original product is returned with its existing
-- verification and erasure; the merge is consistent by construction and the
-- rewrite below verifies any changed product before publication.
inlineClosedWithDecisions :: Bool -> S.Set String -> Namespace -> TypeContext -> M.Map String Int -> Inlining -> ClosedFunction -> Either String (ClosedFunction,[D.Decision],Bool)
inlineClosedWithDecisions reporting forbidden (Namespace ns) types@(TypeContext linears _) snapshotArities (Inlining snapshot limit loopLimit candidates) input=do
  let prepared=mergeClosedLibrary (catalogLibrary snapshot) input
  ((root',codes',changed),(_,_,notes))<-runStateT (do
    let root=closedRoot prepared;codes=closedCode prepared
    (r,rootChanged)<-function (RootTarget (functionName root)) root
    cs<-M.traverseWithKey (\key c->do
      (f,codeChanged)<-function (CodeTarget key) (codeAsFunction c)
      let (caps,ps)=splitAt (length (codeCaptures c)) (functionParameters f)
      pure (c {codeCaptures=caps,codeParameters=ps,codeBody=functionBody f},codeChanged)) codes
    pure (r,M.map fst cs,rootChanged || any snd cs)) (0,catalogFirstType snapshot,[])
  if not changed then pure (input,reverse notes,False)
  else do
    output<-rewriteClosed types (\_ _->Right (root',codes')) prepared
    pure (output,reverse notes,True)
  where
    generated ty node=Expr ty (linShapeT linears ty) Generated Nothing node
    owner=functionName (closedRoot input)
    label (RootTarget n)=n
    label (CodeTarget (CodeId n))=n
    record target why=when reporting (modify (\(serial,next,notes)->(serial,next,D.InlineDecision owner (label target) why:notes)))
    eligible self target=let budget=if self `S.member` recursiveCallbacks (catalogAnalysis snapshot) then loopLimit else limit
      in case M.lookup target candidates of
      Nothing->Nothing -- runtime/foreign entries have no inline template
      Just (Left (D.OverWeight n _))->Just (Left (D.OverWeight n budget))
      Just (Left why)->Just (Left why)
      Just (Right (template,names,weight))
        | target==self->Just (Left D.RecursiveCallee)
        | not (S.null blocked)->Just (Left (D.UsesForbiddenGlobal (S.toAscList blocked)))
        | weight>budget->Just (Left (D.OverWeight weight budget))
        | otherwise->Just (Right template)
        where blocked=names `S.intersection` forbidden
    function self fn=do
      let scope=M.fromList [(binderId b,b) | b<-functionParameters fn++allBinders (functionBody fn)]
          walk e=case call e of
            Just (target,_,_) | Just (Left why)<-eligible self target->record target why >> mapChildrenM walk e
            Just (target,ids,args) | Just (Right (Template caps ps _ _ _))<-eligible self target,
              length caps/=length ids || length ps/=length args->
                record target (D.ArityMismatch (length caps) (length ids) (length ps) (length args)) >> mapChildrenM walk e
            Just (target,ids,args) | Just (Right (Template caps ps body contract _)) <- eligible self target ->do
                args'<-mapM walk args
                actualCaps<-mapM (\uid->maybe (lift (Left "typed inline: absent checked capture")) pure (M.lookup uid scope)) ids
                (serial,next,_)<-get
                let full=foldr (TFn . exprType) (exprType e) args'
                case instantiateContract next contract (map binderScheme actualCaps) full of
                  Left _->record target D.ContractInstantiation >> mapChildrenM walk e
                  Right instance'->do
                    let (namespace,afterSerial)=chooseNamespace fn serial
                        original=Function "inline template" (caps++ps) body
                        copy=substituteFunction types (instanceSolution instance')
                          (instantiateFunction namespace types (instanceFresh instance') original)
                        (copiedCaps,copiedParams)=splitAt (length caps) (functionParameters copy)
                        renamed=renameUses (M.fromList (zip (map binderId copiedCaps) ids)) (functionBody copy)
                        -- A function reference is pure, but a closure capture
                        -- requires a lexical binder until callback rewriting.
                        captured=pinnedLocals renamed
                        replacements=M.fromList [(binderId p,a) | (p,a)<-zip copiedParams args',
                          pureFunction a,binderId p `S.notMember` captured]
                        inside=substituteValues replacements renamed
                        tick=generated (TC "Unit") EntryTick
                        entry=generated (exprType inside) (Sequence tick inside)
                        bind (p,a) rest=generated (exprType rest) (Let p a rest)
                        answer=foldr bind entry [(p,a) | (p,a)<-zip copiedParams args',binderId p `M.notMember` replacements]
                    modify (\(_,_,notes)->(afterSerial,instanceNext instance',notes))
                    record target D.Inlined
                    pure answer {exprOrigin=exprOrigin e,exprOffset=exprOffset e}
            _->mapChildrenM walk e
      before<-gets (\(serial,_,_)->serial)
      body<-walk (functionBody fn)
      after<-gets (\(serial,_,_)->serial)
      let (body',propagated)=propagate body
          (fn',renamed)=hygiene fn {functionBody=body'}
      pure (fn',before/=after || propagated || renamed)
    call e=case exprNode (unNote e) of
      CodeCall key ids args->Just (CodeTarget key,ids,args)
      JoinCall key ids args->Just (CodeTarget key,ids,args)
      _->case spine e [] of
        (head',args@(_:_)) | Var (Global name _) <- exprNode head'->Just (RootTarget name,[],args)
        _->Nothing
    chooseNamespace fn serial=go serial
      where
        go n=let candidate=Namespace (ns++"/inline/"++functionName fn++"/"++show n)
             in if candidate `S.member` catalogNamespaces snapshot then go (n+1) else (candidate,n+1)
    pureFunction e=case exprNode (unNote e) of
      Var (Global name _)->maybe False (>0) (M.lookup name snapshotArities)
      ClosureValue key []->case M.lookup key (catalogContracts snapshot) of
        Just c->contractKind c==ClosureCode
        _->False
      _->False
    substituteValues env e=let child=runIdentity (mapChildrenM (pure . substituteValues env) e)
      in case exprNode child of
        Var (Local uid) | Just a<-M.lookup uid env->child {exprNode=exprNode (unNote a)}
        _->child
    propagate e=let (child,Any sub)=runWriter (mapChildrenM propagateChild e)
      in case exprNode child of
        Let b rhs body | pureFunction rhs,binderId b `S.notMember` pinnedLocals body->
          (substituteValues (M.singleton (binderId b) rhs) body,True)
        _->(child,sub)
      where propagateChild x=let (x',fired)=propagate x in tell (Any fired) >> pure x'
    -- Erasure prints names. Assign collision-free spellings after the typed
    -- rewrite so a caller local cannot capture a template's global reference.
    hygiene fn=let bs=functionParameters fn++allBinders (functionBody fn)
                   globals' = globals (functionBody fn)
                   reserved=catalogNames snapshot<>S.fromList (map binderName bs)<>globals'
                   choose n=let name="$typed.inline."++show (length (functionName fn))++"."++functionName fn++"."++show n
                            in if name `S.member` reserved then choose (n+1) else (name,n+1)
                   add (names,used,next) b
                     | binderName b `S.notMember` globals',binderName b `S.notMember` used=
                         (names,S.insert (binderName b) used,next)
                     | otherwise=let (name,after)=choose next
                                 in (M.insert (binderId b) name names,S.insert name used,after)
                   (names,_,_)=foldl add (M.empty,S.empty,0::Int) bs
                   rename b=case M.lookup (binderId b) names of Nothing->b;Just name->b {binderName=name}
               in if M.null names then (fn,False) else
                 (fn {functionParameters=map rename (functionParameters fn),functionBody=renameBinderNames names (functionBody fn)},True)
    globals e=(case exprNode e of
      Var (Global name _)->S.singleton name
      ClosureValue (CodeId name) _->S.singleton name
      CodeCall (CodeId name) _ _->S.singleton name
      JoinCall (CodeId name) _ _->S.singleton name
      _->S.empty)<>getConst (mapChildrenM (Const . globals) e)
