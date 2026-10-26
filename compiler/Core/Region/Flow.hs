{-# LANGUAGE FlexibleContexts #-}
-- Structural operations on checked region control. Source annotations and
-- identities survive the control rewrite; no source types are reconstructed.
module Core.Region.Flow
  (scope,references,wrapCalls,flowFor,flowSource,functionFlow,closedSource,validateFlow,
   slotBinder,tailCalls,ownedIds,emittedNames) where
import qualified Core.Typed.Syntax as T
import Core.Typed.Walk
import qualified Core.Region.Syntax as R
import Core.Identity
import Control.Monad.State.Strict
import Control.Monad (unless,forM_)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

scope f=M.fromList [(T.binderId b,b) | b<-T.functionParameters f++allBinders (T.functionBody f)]
references e=(case T.exprNode e of
  T.Var (T.Global n _)->S.singleton n
  T.ClosureValue (T.CodeId n) _->S.singleton n
  T.CodeCall (T.CodeId n) _ _->S.singleton n
  T.JoinCall (T.CodeId n) _ _->S.singleton n
  _->S.empty)<>getConst (mapChildrenM (Const . references) e)

wrapCalls arities targets env e
  | S.null targets=(e,False)
  | otherwise=runState (walk e) False
  where
    walk x=case R.decodeCall env x of
      Just (name,args) | not (null args),name `S.member` targets,M.lookup name arities==Just (length args)->do
        child<-operands x
        put True
        pure (T.Expr (T.exprType x) (T.exprShape x) T.Generated (T.exprOffset x) (T.CallRegion child))
      _->mapChildrenM walk x
    operands x=do
      node<-case T.exprNode x of
        T.Note child->T.Note <$> operands child
        T.Apply f a->T.Apply <$> operands f <*> walk a
        T.CodeCall k cs args->T.CodeCall k cs <$> mapM walk args
        T.JoinCall k cs args->T.JoinCall k cs <$> mapM walk args
        node->pure node
      pure x {T.exprNode=node}

flowFor routes f=walk (T.functionBody f)
  where
    members=M.keysSet routes;env=scope f
    mentions e=not (S.null (references e `S.intersection` members))
    walk e=case T.exprNode e of
      T.Let b rhs body | not (mentions rhs)->R.Bind b rhs <$> walk body
      T.LetPattern p rhs body | not (mentions rhs)->R.BindPattern p rhs <$> walk body
      T.Sequence a b | not (mentions a)->R.Then a <$> walk b
      T.If c a b | not (mentions c)->R.Branch c <$> walk a <*> walk b
      T.Note x->R.Note <$> walk x
      T.MatchTail style args alts fallback | not (any mentions args),all guardsSafe alts->
        R.Match style args <$> mapM alternative alts <*> walk fallback
      _ | Just (name,args)<-R.decodeCall env e,Just route<-M.lookup name routes,
          not (any mentions args)->R.Tail <$> R.makeCall env route e
        | not (mentions e)->Right (R.Value e)
        | otherwise->Left ("typed regions "++T.functionName f++": source tail structure disagrees with the plan")
    guardsSafe (T.Alternative _ guards _)=all (\g->case g of T.BoolGuard x->not (mentions x);T.PatternGuard _ x->not (mentions x)) guards
    alternative (T.Alternative ps gs body)=R.Alternative ps gs <$> walk body

-- Reification is solely a checker projection of the retained typed tree. No
-- erased expression is used to infer or reconstruct a source type.
flowSource flow=case flow of
  R.Value e->e
  R.Tail call->R.callWitness call
  R.Bind b rhs body->let next=go body in generated next (T.Let b rhs next)
  R.BindPattern p rhs body->let next=go body in generated next (T.LetPattern p rhs next)
  R.Then a body->let next=go body in generated next (T.Sequence a next)
  R.Branch c a b->let yes=go a in generated yes (T.If c yes (go b))
  R.Note body->let next=go body in generated next (T.Note next)
  R.Match style args alts fallback->let next=go fallback
    in generated next (T.MatchTail style args [T.Alternative ps gs (go body) | R.Alternative ps gs body<-alts] next)
  where go=flowSource
        generated e node=T.Expr (T.exprType e) (T.exprShape e) T.Generated Nothing node

functionFlow f=case R.functionBody f of
  R.LoopInner _ _ _ _ flow->Just flow
  R.ReceiveThunk _ _ _ flow->Just flow
  R.ReceiveLocal flow->Just flow
  _->Nothing
closedSource e=case T.exprNode e of
  T.Lambda {}->Left "typed region program: unclosed lambda in a helper body"
  T.LetRec {}->Left "typed region program: unclosed recursive binding in a helper body"
  T.Match {}->Left "typed region program: implicit match fallthrough in a helper body"
  T.RecordUpdate {}->Left "typed region program: unplanned record layout in a helper body"
  _->mapChildrenM (\child->closedSource child>>pure child) e>>pure ()
validateFlow members flow=case flow of
  R.Value e->plain e
  R.Tail call->mapM_ plain (R.callArguments call)
  R.Bind _ a b->plain a>>validateFlow members b
  R.BindPattern _ a b->plain a>>validateFlow members b
  R.Then a b->plain a>>validateFlow members b
  R.Branch c a b->plain c>>validateFlow members a>>validateFlow members b
  R.Note b->validateFlow members b
  R.Match _ args alts fallback->do
    mapM_ plain args
    forM_ alts $ \(R.Alternative _ guards body)->do
      mapM_ (\g->case g of T.BoolGuard e->plain e;T.PatternGuard _ e->plain e) guards
      validateFlow members body
    validateFlow members fallback
  where plain e=unless (S.null (references e `S.intersection` members))
          (Left "typed region program: recursive reference outside an explicit protocol tail call")

emittedNames f=S.fromList (map R.parameterName (R.functionParameters f))<>case R.functionBody f of
  R.Original->sourceNames (T.functionBody (R.functionSource f))
  R.Ordinary e->sourceNames e
  R.LoopEntry _ _ _ mark seqn->S.fromList (map R.controlName [mark,seqn])
  R.LoopInner _ _ _ _ flow->flowNames flow
  R.LoopCycle {}->S.empty
  R.ReceiveEntry {}->S.empty
  R.ReceiveThunk _ _ slots flow->S.fromList (map (T.binderName . slotBinder) slots)<>flowNames flow
  R.ReceiveLocal flow->flowNames flow
  where sourceNames=S.fromList . map T.binderName . allBinders
        flowNames=sourceNames . flowSource

slotBinder (R.LiveSlot b _)=b
slotBinder (R.DeadSlot b)=b
tailCalls flow=case flow of
  R.Tail call->[call]
  R.Bind _ _ b->tailCalls b;R.BindPattern _ _ b->tailCalls b;R.Then _ b->tailCalls b
  R.Branch _ a b->tailCalls a++tailCalls b;R.Note b->tailCalls b
  R.Match _ _ alts fallback->concat [tailCalls b | R.Alternative _ _ b<-alts]++tailCalls fallback
  _->[]
ownedIds f=map R.parameterId (R.functionParameters f)++case R.functionBody f of
  R.Original->map T.binderId (allBinders (T.functionBody (R.functionSource f)))
  R.Ordinary e->map T.binderId (allBinders e)
  R.LoopEntry _ _ _ mark seqn->map R.controlId [mark,seqn]
  R.LoopInner _ _ _ _ flow->locals flow
  R.LoopCycle {}->[]
  R.ReceiveEntry {}->[]
  R.ReceiveThunk _ _ slots flow->map (T.binderId . slotBinder) slots++locals flow
  R.ReceiveLocal flow->locals flow
  where locals=map T.binderId . allBinders . flowSource
