{-# LANGUAGE FlexibleContexts #-}
-- Inline checked closed entries, before region planning and erasure. Templates
-- retain their code homes; only lexical binders are cloned into the caller.
module Core.Typed.Inline (Inlining,planInlining,inlineClosed) where
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
import Control.Monad (guard,unless,void)
import Control.Monad.Identity (runIdentity)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- One round against an immutable whole-program snapshot. The pipeline owns
-- the bounded rounds; inserted bodies are not recursively expanded here.
data Inlining=Inlining Catalog (M.Map Target (Template,S.Set String))

-- Compute admission once per snapshot, not at every call in every owner.
-- Stop weighing an oversized template as soon as the node budget is spent.
planInlining :: Int -> Catalog -> Either String Inlining
planInlining limit snapshot=do
  unless (limit>=0) (Left "typed inline: negative node budget")
  pure (Inlining snapshot (M.mapMaybeWithKey admit (catalogTemplates snapshot)))
  where
    admit target template@(Template caps ps body _ _)
      | target `S.notMember` recursiveCallbacks (catalogAnalysis snapshot),
        not (null (caps++ps)),Just _<-execStateT (weigh body) limit=
          Just (template,globals body)
      | otherwise=Nothing
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
inlineClosed forbidden (Namespace ns) types@(TypeContext linears _) snapshotArities (Inlining snapshot candidates) input=do
  prepared<-importClosedLibrary types (catalogLibrary snapshot) input
  rewriteClosed types (\root codes->do
    (root',codes')<-evalStateT (do
      r<-function (RootTarget (functionName root)) root
      cs<-M.traverseWithKey (\key c->do
        f<-function (CodeTarget key) (codeAsFunction c)
        let (caps,ps)=splitAt (length (codeCaptures c)) (functionParameters f)
        pure c {codeCaptures=caps,codeParameters=ps,codeBody=functionBody f}) codes
      pure (r,cs)) (0,catalogFirstType snapshot)
    pure (root',codes')) prepared
  where
    generated ty node=Expr ty (linShapeT linears ty) Generated Nothing node
    eligible self target=case M.lookup target candidates of
      Just (template,globals)
        | target/=self,S.null (globals `S.intersection` forbidden)->Just template
      _->Nothing
    function self fn=do
      let scope=M.fromList [(binderId b,b) | b<-functionParameters fn++allBinders (functionBody fn)]
          walk e=case call e of
            Just (target,ids,args) | Just (Template caps ps body contract _) <- eligible self target,
              length caps==length ids,length ps==length args ->do
                args'<-mapM walk args
                actualCaps<-mapM (\uid->maybe (lift (Left "typed inline: absent checked capture")) pure (M.lookup uid scope)) ids
                (serial,next)<-get
                let full=foldr (TFn . exprType) (exprType e) args'
                case instantiateContract next contract (map binderScheme actualCaps) full of
                  Left _->mapChildrenM walk e
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
                    put (afterSerial,instanceNext instance')
                    pure answer {exprOrigin=exprOrigin e,exprOffset=exprOffset e}
            _->mapChildrenM walk e
      body<-walk (functionBody fn)
      pure (hygiene fn {functionBody=propagate body})
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
    propagate e=let child=runIdentity (mapChildrenM (pure . propagate) e)
      in case exprNode child of
        Let b rhs body | pureFunction rhs,binderId b `S.notMember` pinnedLocals body->
          substituteValues (M.singleton (binderId b) rhs) body
        _->child
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
               in if M.null names then fn else
                 fn {functionParameters=map rename (functionParameters fn),functionBody=renameBinderNames names (functionBody fn)}
    globals e=(case exprNode e of
      Var (Global name _)->S.singleton name
      ClosureValue (CodeId name) _->S.singleton name
      CodeCall (CodeId name) _ _->S.singleton name
      JoinCall (CodeId name) _ _->S.singleton name
      _->S.empty)<>getConst (mapChildrenM (Const . globals) e)
