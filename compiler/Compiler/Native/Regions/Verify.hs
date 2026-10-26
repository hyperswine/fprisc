{-# LANGUAGE FlexibleContexts #-}
-- Verify the complete region graph, physical/protocol contracts, lexical
-- identities and the liveness/invariance authority used by state packing.
module Compiler.Native.Regions.Verify (verifyRegions) where
import qualified Compiler.Native.Core as Native
import qualified Core.Typed.Syntax as T
import qualified Core.Typed.Program as Source
import Core.Typed.Pipeline
import Core.Typed.Walk
import Core.Typed.Verify (verifyFunctionWith,sameType)
import Core.Typed.Erase
import Core.Region.Flow
import qualified Core.Region.Syntax as R
import Core.Region.Runtime (Hook(..),hookName)
import Core.Analysis.Alpha (sameFunction)
import Core.Opt.Representation (eraseLayoutCasts)
import Core.Identity
import Core.Syntax (Name)
import Compiler.DataLayout
import Type.Syntax (Scheme(..))
import qualified ReceiveTurns as Turns
import Control.Monad.State.Strict
import Control.Monad (unless,forM_)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

verifyRegions :: Native.NativeCore -> Turns.Rewrite -> M.Map Name R.Function -> S.Set Name -> S.Set Name -> Either String ()
verifyRegions native rewrite fs helpers blocked=do
  let closed=Native.nativeClosed native;input=closedInput closed;types=Source.programTypes input
      original=Native.nativeDefinitions native
      plannedGroups=M.fromList [(n,g) | g<-Turns.rewriteGroups rewrite,n<-Turns.groupMembers g]
      ids=concatMap ownedIds (M.elems fs)
      bad why=Left ("typed region program: "++why)
      protocolNames=helpers<>S.fromList (map hookName [CallPending,CallLeave,LoopLeave,SequenceNumber,Open,PoolMark,HasRoom,Cycle,ReceiveLoop])
  unless (length ids==S.size (S.fromList ids)) (bad "binder identity shared by emitted functions")
  unless ((M.keysSet original S.\\ blocked) `S.isSubsetOf` M.keysSet fs) (bad "lost a checked source entry")
  forM_ (M.toList fs) $ \(name,f)->do
    let source=R.functionSource f
        ps=T.functionParameters source
        idsOf=map T.binderId
        bodyFlow=case R.functionBody f of R.LoopInner _ _ _ _ flow->Just flow;R.ReceiveThunk _ _ _ flow->Just flow;R.ReceiveLocal flow->Just flow;_->Nothing
        actual=case R.functionBody f of
          R.Ordinary e->source {T.functionBody=e}
          _->maybe source (\flow->source {T.functionBody=flowSource flow}) bodyFlow
        check why ok=unless ok (bad (name++": "++why))
    check "label/key mismatch" (name==R.functionLabel f)
    check "a binder captures a protocol symbol" (S.null (emittedNames f `S.intersection` protocolNames))
    case M.lookup (R.functionSourceName f) original of
      Just definition->do
        let owner=Native.checkedOwner definition;parent=Native.checkedFunction definition
        check "source owner mismatch" (owner==R.functionOwner f && T.functionName source==T.functionName parent)
        check "source physical scheme mismatch" (sameType (T.functionType parent) (T.functionType source)
          && length ps==length (T.functionParameters parent)
          && and (zipWith (\a b->sameScheme (T.binderScheme a) (T.binderScheme b)) ps (T.functionParameters parent)))
        check "source binder provenance mismatch" (if name `S.member` helpers
          then R.functionBinderOrigins f==zip (map T.binderId (T.functionParameters parent)) (map T.binderId ps)
          else map T.binderId ps==map T.binderId (T.functionParameters parent) && null (R.functionBinderOrigins f))
      _->bad (name++": source definition is absent from the checked parent")
    check "duplicate physical parameter" (length (R.functionParameters f)==S.size (S.fromList (map R.parameterId (R.functionParameters f))))
    check "duplicate physical parameter spelling" (length (R.functionParameters f)==S.size (S.fromList (map R.parameterName (R.functionParameters f))))
    let controls=[c | R.ControlParameter c<-R.functionParameters f]++case R.functionBody f of
          R.LoopEntry _ _ _ mark seqn->[mark,seqn]
          _->[]
        controlNames=S.fromList (map R.controlName controls)
        sourceNames=S.fromList (map T.binderName (ps++allBinders (T.functionBody actual)))
        sourceReferences=case R.functionBody f of
          R.LoopEntry {}->S.empty
          R.LoopCycle {}->S.empty
          R.ReceiveEntry {}->S.empty
          _->references (T.functionBody actual)
    check "duplicate control spelling" (length controls==S.size controlNames)
    check "control cell captures a source binding or symbol" (S.null (controlNames `S.intersection` (sourceNames<>sourceReferences)))
    check "physical helper arity exceeds 64" (name `S.notMember` helpers || length (R.functionParameters f)<=64)
    check "helper source disagrees with its plan" (name `S.notMember` helpers ||
      Turns.generatedSource (Turns.rewriteGenerated rewrite M.! name)==R.functionSourceName f)
    check "helper role disagrees with its plan" (name `S.notMember` helpers || case
      (Turns.generatedKind (Turns.rewriteGenerated rewrite M.! name),R.functionBody f) of
        (Turns.LoopInner,R.LoopInner {})->True
        (Turns.LoopCycle,R.LoopCycle {})->True
        (Turns.ReceiveThunk,R.ReceiveThunk {})->True
        (Turns.ReceiveJoin,R.ReceiveLocal {})->True
        _->False)
    case R.functionBody f of
      R.Original->pure () -- retained, immutable checked NativeCore parent
      _->do
        verifyFunctionWith (R.functionContracts f) types actual
        Source.verifyProgramCalls input (R.functionOwner f) (T.functionBody actual)
        closedSource (T.functionBody actual)
    let result=case R.functionResult f of R.ValueResult t->t;R.ReceiveStep t->t
    check "source/result mismatch" (sameType result (T.exprType (T.functionBody actual)))
    check "protocol result sort" (case (R.functionBody f,R.functionResult f) of
      (R.ReceiveThunk {},R.ReceiveStep _)->True
      (R.ReceiveLocal {},R.ReceiveStep _)->True
      (R.ReceiveThunk {},_)->False
      (R.ReceiveLocal {},_)->False
      (_,R.ValueResult _)->True
      _->False)
    case R.functionBody f of
      R.Original->check "original parameter bank" (sameBank (R.functionParameters f) (map R.ValueParameter ps) && name==R.functionSourceName f)
      R.Ordinary _->check "ordinary parameter bank" (sameBank (R.functionParameters f) (map R.ValueParameter ps))
      R.LoopEntry eager inner bs mark seqn->do
        check "entry parameter bank" (sameBinders bs ps && sameBank (R.functionParameters f) (map R.ValueParameter ps))
        -- only a receive loop opens its region at entry; a pure loop's opens
        -- when a slab has filled, its state built in the caller's pool
        check "loop entry opening disagrees with its group"
          (maybe False (\g->Turns.groupLooped g && eager==not (Turns.groupPure g)) (M.lookup (R.functionSourceName f) plannedGroups))
        checkControl mark R.Mark;checkControl seqn R.Sequence
        targetFor (R.functionSourceName f) Turns.LoopInner inner (length ps+2)
      R.LoopInner cold bs mark seqn _->do
        loopBank f ps bs mark seqn
        mapM_ (\name->targetFor (R.functionSourceName f) Turns.LoopCycle name (length ps+2)) cold
      R.LoopCycle inner bs changing mark seqn->do
        loopBank f ps bs mark seqn
        check "invalid changing state slot" (all (\i->i>=0 && i<length ps) changing && length changing==S.size (S.fromList changing))
        check "loop state liveness/invariance proof disagrees"
          ([T.binderName (ps!!i) | i<-changing]==Turns.generatedState (Turns.rewriteGenerated rewrite M.! name))
        targetFor (R.functionSourceName f) Turns.LoopInner inner (length ps+2)
      R.ReceiveEntry helper bs live->do
        check "receive entry bank" (sameBinders bs ps && sameBank (R.functionParameters f) (map R.ValueParameter ps))
        check "invalid receive state slot" (all (\i->i>=0 && i<length ps) live && length live==S.size (S.fromList live))
        targetFor (R.functionSourceName f) Turns.ReceiveThunk helper 2
      R.ReceiveThunk state tick slots _->do
        checkControl tick R.Tick
        check "receive physical bank" (sameBank (R.functionParameters f) (map R.ControlParameter [state,tick]))
        check "receive logical bank" (sameBinders (map slotBinder slots) ps)
        let live=[(T.binderName b,i) | R.LiveSlot b i<-slots]
            planned=Turns.generatedState (Turns.rewriteGenerated rewrite M.! name)
        check "dead-slot liveness proof disagrees" (map fst live==planned && map snd live==[0..length live-1])
        case R.controlType state of
          R.State fields->check "receive bundle schemes" (length fields==length live && and
            [sameScheme sc (T.binderScheme b) | (sc,R.LiveSlot b _)<-zip fields [s | s@R.LiveSlot {}<-slots]])
          _->bad (name++": state cell lacks bundle sort")
      R.ReceiveLocal _->check "receive local bank" (sameBank (R.functionParameters f) (map R.ValueParameter ps))
    forM_ bodyFlow $ \flow->forM_ (tailCalls flow) $ \call->do
      let route=R.callRoute call
      check "route source arity" (length (R.callArguments call)==length (R.routeParameters route))
      case R.decodeCall (scope actual) (R.callWitness call) of
        Just (target,args)->check "call operands disagree with their checked witness"
          (target==R.routeSource route && length args==length (R.callArguments call)
            && and (zipWith sameOperand args (R.callArguments call)))
        _->bad (name++": call witness has no checked physical operands")
      case (M.lookup (R.routeSource route) original,M.lookup (R.routeSource route) plannedGroups) of
        (Just definition,Just group)->do
          let parent=Native.checkedFunction definition
          check "route source bank" (sameBinders (R.routeParameters route) (T.functionParameters parent))
          check "route boundary proof" (R.routeBoundary route==(R.routeSource route `S.member` Turns.groupBoundaries group))
          check "route liveness proof" (R.routeLive route==[i | (i,b)<-zip [0..] (T.functionParameters parent),
            T.binderName b `S.member` (Turns.groupLive group M.! R.routeSource route)])
        _->bad (name++": route has no checked source/group authority")
      case M.lookup (R.routeLabel route) fs of
        Just destination->do
          check "route source identity" (R.functionSourceName destination==R.routeSource route)
          check "route logical parameter schemes" (length (R.routeParameters route)==length (T.functionParameters (R.functionSource destination)) && and
            (zipWith (\a b->sameScheme (T.binderScheme a) (T.binderScheme b)) (R.routeParameters route) (T.functionParameters (R.functionSource destination))))
          check "route protocol sort" (case (R.functionResult f,R.functionResult destination) of
            (R.ValueResult _,R.ValueResult _)->True;(R.ReceiveStep _,R.ReceiveStep _)->True;_->False)
        _->bad (name++": absent typed route")
      let arity=case R.functionResult f of
            R.ValueResult _->length (R.callArguments call)+2
            R.ReceiveStep _->if R.routeBoundary route then 2 else length (R.callArguments call)
          role=case R.functionResult f of
            R.ValueResult _->Turns.LoopInner
            R.ReceiveStep _->if R.routeBoundary route then Turns.ReceiveThunk else Turns.ReceiveJoin
      targetFor (R.routeSource route) role (R.routeLabel route) arity
    forM_ bodyFlow $ \flow->case M.lookup (R.functionSourceName f) plannedGroups of
      Just group->validateFlow (S.fromList (Turns.groupMembers group)) flow
      _->bad (name++": helper has no source control group")
  -- A source-equivalent checker projection retains the original immutable
  -- proof directly. Changed logical bodies must re-establish its dataflow
  -- facts before they can be published with the same protocol contract.
  let logical=M.fromList [(R.functionSourceName f,(f,source {T.functionBody=flowSource flow}))
        | f<-M.elems fs,let source=R.functionSource f,Just flow<-[functionFlow f]]
  rows<-traverse (\(f,source)->eraseLogical native f source) logical
  let unchanged=all (\(name,row)->maybe False (`sameFunction` row) (M.lookup name (Turns.rewriteInput rewrite))) (M.toList rows)
  unless unchanged (Turns.validateSource rewrite (rows `M.union` Turns.rewriteInput rewrite))
  where
    targetFor source role name arity=case M.lookup name fs of
      Just f | length (R.functionParameters f)==arity,R.functionSourceName f==source,
        Just declaration<-M.lookup name (Turns.rewriteGenerated rewrite),Turns.generatedKind declaration==role->Right ()
      _->Left ("typed region program: target/physical interface mismatch at "++name)
    checkControl c want=unless (sameControl (R.controlType c) want) (Left "typed region program: control cell sort")
    loopBank f ps bs mark seqn=do
      unless (sameBinders bs ps && sameBank (R.functionParameters f) (map R.ValueParameter ps++map R.ControlParameter [mark,seqn]))
        (Left "typed region program: loop physical bank")
      checkControl mark R.Mark;checkControl seqn R.Sequence

eraseLogical native f source=do
  let closed=Native.nativeClosed native;input=closedInput closed;layouts=closedLayouts closed
      reserved=M.keysSet (Source.programSchemas input)<>references (T.functionBody source)
        <>S.fromList (map T.binderName (T.functionParameters source++allBinders (T.functionBody source)))
      fresh stem=do
        n<-get;put (n+1)
        let name="$typed.region.proof."++T.functionName source++"."++stem++"."++show (n::Int)
        if name `S.member` reserved then fresh stem else pure name
      constructor n=case M.lookup n (constructorLayouts layouts) of Just c->Just c;_->wideTup n
      layout=Layout fresh constructor (shapeLayouts layouts) (\_ _ _->lift (Left "typed region proof: implicit join"))
  row<-evalStateT (eraseFunctionWith (R.functionContracts f) (Source.programTypes input) layout source) 0 >>= id
  pure (eraseLayoutCasts (M.singleton (R.functionSourceName f) row) M.! R.functionSourceName f)

sameControl R.Mark R.Mark=True
sameControl R.Sequence R.Sequence=True
sameControl R.Tick R.Tick=True
sameControl (R.State a) (R.State b)=length a==length b && and (zipWith sameScheme a b)
sameControl _ _=False
sameScheme (Forall a b x) (Forall c d y)=a==c && b==d && sameType x y
sameBinders a b=length a==length b && and (zipWith sameBinder a b)
sameBinder a b=T.binderId a==T.binderId b && T.binderName a==T.binderName b
  && T.binderShape a==T.binderShape b && sameScheme (T.binderScheme a) (T.binderScheme b)
sameBank a b=length a==length b && and (zipWith same a b)
  where
    same (R.ValueParameter x) (R.ValueParameter y)=sameBinder x y
    same (R.ControlParameter x) (R.ControlParameter y)=R.controlId x==R.controlId y
      && R.controlName x==R.controlName y && sameControl (R.controlType x) (R.controlType y)
    same _ _=False
sameOperand a b=sameType (T.exprType a) (T.exprType b) && T.exprShape a==T.exprShape b
  && case T.exprNode a of
    T.Var (T.Local uid)->case T.exprNode b of T.Var (T.Local other)->uid==other;_->False
    _->True -- ordinary arguments are immutable projections of the witness
