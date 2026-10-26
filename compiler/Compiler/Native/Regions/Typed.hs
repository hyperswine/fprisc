{-# LANGUAGE FlexibleContexts #-}
-- Checked region control is a distinct program product. Source expressions
-- retain their annotations; protocol sorts never enter the source type system.
module Compiler.Native.Regions.Typed
  (Program,build,programNative,programFunctions,programHelpers,programFallback,
   verifyProgram,rewriteHelpers,emitProgram) where
import qualified Compiler.Native.Core as Native
import qualified Core.Typed.Syntax as T
import Core.Region.Flow
import qualified Compiler.Native.Regions.Verify as Verify
import qualified Core.Typed.Program as Source
import Core.Typed.Pipeline
import Core.Typed.Walk
import Core.Typed.Erase
import Core.Identity
import Core.Syntax (Name,Prog)
import qualified Core.Region.Syntax as R
import Core.Opt.Representation (eraseLayoutCasts)
import Compiler.DataLayout
import qualified ReceiveTurns as Turns
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Monad.State.Strict
import Control.Monad (unless,forM,forM_)

data Program=Program Native.NativeCore Turns.Rewrite (M.Map Name R.Function) (S.Set Name) (S.Set Name)
programNative (Program p _ _ _ _)=p
programFunctions (Program _ _ fs _ _)=fs
programHelpers (Program _ _ fs names _)=M.map R.functionContract (M.restrictKeys fs names)
programFallback (Program _ rewrite fs _ _)=M.keysSet (Turns.rewriteProgram rewrite) S.\\ M.keysSet fs

-- Later helper-body passes publish and verify a complete changed graph.
-- Original parent definitions are not editable through this projection.
rewriteHelpers :: (R.Function -> Either String R.Function) -> Program -> Either String Program
rewriteHelpers pass (Program native rewrite fs helpers blocked)=do
  changed<-M.traverseWithKey (\name f->if name `S.member` helpers then pass f else Right f) fs
  let result=Program native rewrite changed helpers blocked
  verifyProgram result
  pure result

build :: Native.NativeCore -> M.Map Name Int -> Turns.Rewrite -> Either String Program
build native arities rewrite=do
  unless (eraseLayoutCasts (Native.nativeProgram native)==Turns.rewriteInput rewrite)
    (Left "typed regions: plan belongs to another input projection")
  (functions,_)<-runStateT make 0
  let result=Program native rewrite functions helperNames blocked
  verifyProgram result
  pure result
  where
    available=Native.nativeDefinitions native
    selected=[g | g<-Turns.rewriteGroups rewrite,all (`M.member` available) (Turns.groupMembers g)]
    blocked=S.unions [S.fromList (Turns.groupMembers g) | g<-Turns.rewriteGroups rewrite,
      not (all (`M.member` available) (Turns.groupMembers g))]
    groups=M.fromList [(n,g) | g<-selected,n<-Turns.groupMembers g]
    helpers=M.filter ((`M.member` groups) . Turns.generatedSource) (Turns.rewriteGenerated rewrite)
    helperNames=M.keysSet helpers
    closed=Native.nativeClosed native
    source=closedInput closed
    allFunctions=map Native.checkedFunction (M.elems available)
    binders=concat [T.functionParameters f++allBinders (T.functionBody f) | f<-allFunctions]
    namespaces=S.fromList [ns | b<-binders,let BinderId ns _=T.binderId b]
    Namespace parent=Source.programNamespace source
    namespace=choose (0::Int)
      where choose n=let ns=Namespace (parent++"/regions/"++show n)
                     in if ns `S.member` namespaces then choose (n+1) else ns
    occupied=S.fromList (map T.binderName binders)<>M.keysSet (Turns.rewriteProgram rewrite)
    freshId=do n<-get;put (n+1);pure (BinderId namespace n)
    control stem ty=do
      uid@(BinderId _ n)<-freshId
      let name=if stem `S.notMember` occupied then stem else stem++"."++show n
      if name `S.member` occupied then control stem ty else pure (R.Control uid name ty)
    copy f=do
      let bs=T.functionParameters f++allBinders (T.functionBody f)
      ids<-mapM (const freshId) bs
      let renames=M.fromList (zip (map T.binderId bs) ids)
          ps=[b {T.binderId=renames M.! T.binderId b} | b<-T.functionParameters f]
      pure (f {T.functionParameters=ps,T.functionBody=renameBinders renames (T.functionBody f)},
        zip (map T.binderId (T.functionParameters f)) (map T.binderId ps))
    label n kind=case [name | (name,g)<-M.toList helpers,Turns.generatedSource g==n,Turns.generatedKind g==kind] of
      [name]->Right name
      _->Left ("typed regions: absent or ambiguous planned helper for "++n)
    live g n=[i | (i,b)<-zip [0..] (T.functionParameters (Native.checkedFunction (available M.! n))),
      T.binderName b `S.member` (Turns.groupLive g M.! n)]
    routes g=traverse (\n->do
      let boundary=n `S.member` Turns.groupBoundaries g
      name<-label n (if Turns.groupLooped g then Turns.LoopInner else if boundary then Turns.ReceiveThunk else Turns.ReceiveJoin)
      pure (R.Route n name boundary (live g n) (T.functionParameters (Native.checkedFunction (available M.! n)))))
      (M.fromList [(n,n) | n<-Turns.groupMembers g])
    calls name=M.findWithDefault S.empty name (Turns.rewriteCallTargets rewrite)
    wrap name f=let (body,changed)=wrapCalls arities (calls name) (scope f) (T.functionBody f)
                in (f {T.functionBody=body},changed)
    make=do
      originals<-forM (M.toList (M.withoutKeys available blocked)) $ \(name,definition)->do
        let owner=Native.checkedOwner definition;f=Native.checkedFunction definition;contracts=Native.checkedContracts definition
        let (original,changed)=wrap name f
            ps=T.functionParameters original
            result=R.ValueResult (T.exprType (T.functionBody original))
            definition body=R.Function name owner name original (map R.ValueParameter ps) result body contracts []
        body<-case M.lookup name groups of
          Just g | name `S.member` Turns.groupBoundaries g->if Turns.groupLooped g then do
            inner<-lift (label name Turns.LoopInner)
            mark<-control "$loop.mark" R.Mark;seqn<-control "$loop.seq" R.Sequence
            pure (R.LoopEntry (not (Turns.groupPure g)) inner ps mark seqn)
            else do thunk<-lift (label name Turns.ReceiveThunk);pure (R.ReceiveEntry thunk ps (live g name))
          _->pure (if changed then R.Ordinary (T.functionBody original) else R.Original)
        pure (name,definition body)
      generated<-forM (M.toList helpers) $ \(name,description)->do
        let sourceName=Turns.generatedSource description
            g=groups M.! sourceName
            definition=available M.! sourceName
            owner=Native.checkedOwner definition;original=Native.checkedFunction definition;contracts=Native.checkedContracts definition
        (copied,origins)<-copy original
        let (f,_)=wrap name copied
            ps=T.functionParameters f
            result=T.exprType (T.functionBody f)
            base params output body=R.Function name owner sourceName f params output body contracts origins
        rs<-lift (routes g)
        case Turns.generatedKind description of
          Turns.LoopInner->do
            mark<-control "$loop.mark" R.Mark;seqn<-control "$loop.seq" R.Sequence
            cold<-if sourceName `S.member` Turns.groupBoundaries g then Just <$> lift (label sourceName Turns.LoopCycle) else pure Nothing
            flow<-lift (flowFor rs f)
            pure (name,base (map R.ValueParameter ps++map R.ControlParameter [mark,seqn]) (R.ValueResult result)
              (R.LoopInner cold ps mark seqn flow))
          Turns.LoopCycle->do
            mark<-control "$loop.mark" R.Mark;seqn<-control "$loop.seq" R.Sequence
            inner<-lift (label sourceName Turns.LoopInner)
            let changing=[i | i<-live g sourceName,(sourceName,i) `S.notMember` Turns.groupInvariants g]
            pure (name,base (map R.ValueParameter ps++map R.ControlParameter [mark,seqn]) (R.ValueResult result)
              (R.LoopCycle inner ps changing mark seqn))
          Turns.ReceiveThunk->do
            let retained=live g sourceName
                fields=[T.binderScheme (ps!!i) | i<-retained]
                slots=[maybe (R.DeadSlot b) (R.LiveSlot b) (lookup i (zip retained [0..])) | (i,b)<-zip [0..] ps]
            state<-control "$receive.state" (R.State fields);tick<-control "$receive.unit" R.Tick
            flow<-lift (flowFor rs f)
            pure (name,base (map R.ControlParameter [state,tick]) (R.ReceiveStep result) (R.ReceiveThunk state tick slots flow))
          Turns.ReceiveJoin->do
            flow<-lift (flowFor rs f)
            pure (name,base (map R.ValueParameter ps) (R.ReceiveStep result) (R.ReceiveLocal flow))
      pure (M.fromList (originals++generated))

verifyProgram :: Program -> Either String ()
verifyProgram (Program native rewrite fs helpers blocked)=Verify.verifyRegions native rewrite fs helpers blocked

emitProgram :: Program -> Either String Prog
emitProgram (Program native rewrite fs _ _)=do
  outputs<-traverse one fs
  pure (eraseLayoutCasts outputs `M.union` Turns.rewriteProgram rewrite)
  where
    closed=Native.nativeClosed native;input=closedInput closed;types=Source.programTypes input;layouts=closedLayouts closed
    one f=do
      case R.functionBody f of
        R.Original->maybe (Left "typed region erasure: missing original parent body") Right
          (M.lookup (R.functionSourceName f) (Turns.rewriteInput rewrite))
        _->changed f
    changed f=do
      let name=R.functionLabel f
          actual=maybe (T.functionBody (R.functionSource f)) flowSource (functionFlow f)
          reserved=M.keysSet (Source.programSchemas input)<>references actual<>emittedNames f
            <>S.fromList (map T.binderName (allBinders actual++T.functionParameters (R.functionSource f)))
          fresh stem=do
            n<-get;put (n+1)
            let candidate="$typed.region.erase."++show (length name)++"."++name++"."++stem++"."++show (n::Int)
            if candidate `S.member` reserved then fresh stem else pure candidate
          constructor n=case M.lookup n (constructorLayouts layouts) of Just c->Just c;_->wideTup n
          layout=Layout fresh constructor (shapeLayouts layouts) (\_ _ _->lift (Left "typed region erasure: implicit join"))
      evalStateT (eraseRegionFunctionWith types layout f) 0 >>= id
