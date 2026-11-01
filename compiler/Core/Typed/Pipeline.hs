{-# LANGUAGE FlexibleContexts #-}
-- Native semantic passes operate on a complete owned program before erasure.
-- Layout authority stays attached to the closed product it helped construct.
module Core.Typed.Pipeline
  (ClosedProgram,closeProgram,specializeProgramWith,specializePrograms,specializeProgramsWithDecisions,inlinePrograms,inlineProgramsWithDecisions,closedDecisions,closedTouched,planVectorReads,normalizeProgram,caseKnownProgram,fusePrograms,fuseListPrograms,closedInput,closedDefinitions,closedLayouts,verifyClosedProgram) where
import qualified Core.Typed.Decision as D
import Core.Typed.Program
import Core.Typed.Syntax
import Core.Typed.Layout
import Core.Typed.Close
import Core.Typed.Stage
import Core.Typed.Resolve
import Core.Typed.Callback
import qualified Core.Typed.Callback.Catalog as Callbacks
import qualified Core.Typed.Inline as Inline
import qualified Core.Typed.VectorRead as VectorRead
import qualified Core.Typed.Normalize as Normalize
import qualified Core.Typed.CaseKnown as CaseKnown
import qualified Core.Typed.Fusion as Fusion
import qualified Core.Typed.ListFusion as ListFusion
import Core.Typed.Verify (sameType)
import Core.Typed.Walk (allBinders,mapChildrenM)
import Compiler.DataLayout
import Control.Monad.State.Strict
import Control.Monad (unless)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data ClosedProgram=ClosedProgram Program Layouts (M.Map String ClosedFunction) [D.Decision] (S.Set String)
closedInput (ClosedProgram p _ _ _ _)=p
closedDefinitions (ClosedProgram _ _ fs _ _)=fs
closedLayouts (ClosedProgram _ layouts _ _ _)=layouts
closedDecisions (ClosedProgram _ _ _ ds _)=ds
-- Definitions the most recent pass rewrote. Everything else carries its
-- previous verification and erasure, so passes report exactly what they
-- touched and downstream consumers skip the rest.
closedTouched (ClosedProgram _ _ _ _ touched)=touched

closeProgram :: CallbackMode -> Layouts -> Program -> Either String ClosedProgram
closeProgram mode layouts input=do
  verifyProgram input
  definitions<-M.traverseWithKey one (programFunctions input)
  let result=ClosedProgram input layouts definitions [] (M.keysSet definitions)
  verifyClosedProgram result
  specializeProgramWith mode [] result
  where
    types=programTypes input
    one owner fn=do
      layout<-planFunction (programNamespace input) (shapeLayouts layouts) types fn
      staged<-stageFunction (programNamespace input) types (programArities input) (plannedFunction layout)
      let reserved=M.keysSet (programSchemas input)<>globals (functionBody fn)
          fresh stem=do
            n<-get;put (n+1)
            let label=stem++"_"++show (n::Int)++"."++show (length owner)++"."++owner
            if label `S.member` reserved then fresh stem else pure label
      closed<-evalState (closeFunctionWith (programSchemas input) (programNamespace input) fresh types (stagedFunction staged)) 0
      resolved<-resolveCalls types closed
      pure resolved
    globals e=(case exprNode e of Var (Global n _)->S.singleton n;_->S.empty)
      <>getConst (mapChildrenM (Const . globals) e)

-- All templates come from checked owned programs in this checking namespace.
-- Cloned private code remains owned by the caller; referenced original code
-- remains owned by its provider and is carried only as an import declaration.
specializeProgramWith :: CallbackMode -> [ClosedProgram] -> ClosedProgram -> Either String ClosedProgram
specializeProgramWith PreserveCallbacks _ p=pure p
specializeProgramWith _ providers p=do
  -- Providers are opaque verified products. Check the new namespace/layout
  -- relationship here and verify the transformed output once below.
  mapM_ (\q->unless (programNamespace (closedInput q)==programNamespace input
    && constructorLayouts (closedLayouts q)==constructorLayouts layouts
    && shapeLayouts (closedLayouts q)==shapeLayouts layouts)
      (Left "typed pipeline: callback provider namespace/layout mismatch")) providers
  snapshot<-Callbacks.catalogPrograms (programTypes input) (map closedInput (p:providers)) catalog
  specializeSnapshot False S.empty snapshot (snapshotInterfaces snapshot) p
  where
    input=closedInput p;layouts=closedLayouts p
    catalog=M.unions (map closedDefinitions (p:providers))

-- Share a checked catalog across all linked artifacts. Constructor elision
-- selects a unique template owner without replacing an artifact's own stubs.
specializePrograms :: Ord key => CallbackMode -> M.Map key (S.Set String,ClosedProgram) -> Either String (M.Map key ClosedProgram)
specializePrograms=specializeProgramsWithDecisions False
specializeProgramsWithDecisions :: Ord key => Bool -> CallbackMode -> M.Map key (S.Set String,ClosedProgram) -> Either String (M.Map key ClosedProgram)
specializeProgramsWithDecisions _ PreserveCallbacks inputs=Right (M.map snd inputs)
specializeProgramsWithDecisions reporting _ inputs=case map snd (M.elems inputs) of
  []->Right M.empty
  base:programs->do
    mapM_ (\p->unless (programNamespace (closedInput p)==programNamespace (closedInput base)
      && constructorLayouts (closedLayouts p)==constructorLayouts (closedLayouts base)
      && shapeLayouts (closedLayouts p)==shapeLayouts (closedLayouts base))
        (Left "typed pipeline: callback provider namespace/layout mismatch")) programs
    let owned=[M.withoutKeys (closedDefinitions p) elided | (elided,p)<-M.elems inputs]
        owners=M.unions owned
    unless (M.size owners==sum (map M.size owned)) (Left "typed pipeline: duplicate callback source owner")
    snapshot<-Callbacks.catalogPrograms (programTypes (closedInput base)) (map (closedInput . snd) (M.elems inputs)) owners
    let interfaces=snapshotInterfaces snapshot
    traverse (\(elided,p)->specializeSnapshot reporting elided snapshot interfaces p) inputs

snapshotInterfaces :: Callbacks.Catalog -> M.Map CodeId (String,Function)
snapshotInterfaces snapshot=M.fromList (concat
  [[(CodeId name,(name,closedRoot f))]
    ++[(key,(name,codeAsFunction c)) | (key,c)<-M.toList (closedCode f)]
  | (name,f)<-M.toList (Callbacks.catalogOwners snapshot)])

-- Elided definitions are constructor stubs another artifact owns and emits;
-- every linked pass transforms them there and passes this artifact's copy
-- through unchanged. Verification still covers them.
specializeSnapshot :: Bool -> S.Set String -> Callbacks.Catalog -> M.Map CodeId (String,Function) -> ClosedProgram -> Either String ClosedProgram
specializeSnapshot reporting elided snapshot templates p=do
  let input=closedInput p
  changed<-M.traverseWithKey (\name original->if name `S.member` elided then pure (original,[]) else do
    output<-specializeClosedWithDecisions reporting (programNamespace input)
      (programTypes input) (programArities input) snapshot original
    pure (callbackClosed output,callbackDecisions output)) (closedDefinitions p)
  let definitions=M.map fst changed
  mapM_ (\origin->case M.lookup (cloneTemplate origin) templates of
    Just (owner,fn) | cloneSource origin==owner,
      map fst (cloneBindings origin)==map binderId (functionParameters fn)->pure ()
    _->Left "typed pipeline: clone source/parameter provenance disagrees")
    [origin | f<-M.elems definitions,origin<-M.elems (closedOrigins f)]
  -- Specialization rewrites callback products wholesale; only elided stubs
  -- pass through with their existing verification and erasure.
  let result=ClosedProgram input (closedLayouts p) definitions (closedDecisions p++concatMap snd (M.elems changed))
        (S.fromList [name | name<-M.keys definitions,S.notMember name elided])
  verifyLinkedStep result
  pure result

-- All owned artifacts advance against one immutable snapshot per round.
-- Forbidden globals are linker-private source entries from other artifacts;
-- their bodies cannot be copied into a caller without an import contract.
inlinePrograms :: Ord key => Int -> Int -> Int -> M.Map key (S.Set String,S.Set String,ClosedProgram) -> Either String (M.Map key ClosedProgram)
inlinePrograms=inlineProgramsWithDecisions False
inlineProgramsWithDecisions :: Ord key => Bool -> Int -> Int -> Int -> M.Map key (S.Set String,S.Set String,ClosedProgram) -> Either String (M.Map key ClosedProgram)
inlineProgramsWithDecisions reporting rounds limit loopLimit inputs=do
  unless (rounds>=0 && limit>=0 && loopLimit>=0) (Left "typed inline pipeline: negative round/node budget")
  let programs=[p | (_,_,p)<-M.elems inputs]
  case programs of
    []->pure M.empty
    base:_->do
      mapM_ (\p->unless (programNamespace (closedInput p)==programNamespace (closedInput base)
        && constructorLayouts (closedLayouts p)==constructorLayouts (closedLayouts base)
        && shapeLayouts (closedLayouts p)==shapeLayouts (closedLayouts base))
          (Left "typed inline pipeline: checking namespace/layout mismatch")) programs
      go rounds (M.map (\(_,_,p)->p) inputs)
  where
    -- A round that rewrote nothing is a fixed point: another round would
    -- rebuild the same catalogue and walk the same bodies to no effect.
    -- Touched names accumulate across rounds: the next erasure boundary diffs
    -- against the program as it was before the whole inline pass, not before
    -- the final round.
    go 0 programs=pure programs
    go remaining programs=do
      (advanced,anyChanged)<-step programs
      let merged=M.intersectionWith accumulate advanced programs
          accumulate (ClosedProgram i l ds dd t) (ClosedProgram _ _ _ _ prev)=ClosedProgram i l ds dd (t<>prev)
      if anyChanged then go (remaining-1) merged else pure merged
    step programs=do
      let allPrograms=M.elems programs
          owned=M.mapWithKey (\key p->let (_,elided,_)=inputs M.! key in M.withoutKeys (closedDefinitions p) elided) programs
          owners=M.unions (M.elems owned)
      unless (M.size owners==sum (map M.size (M.elems owned)))
        (Left "typed inline pipeline: duplicate source owner")
      let types=programTypes (closedInput (head allPrograms))
      snapshot<-Callbacks.catalogPrograms types (map closedInput allPrograms) owners
      inlining<-Inline.planInlining limit loopLimit snapshot
      advanced<-M.traverseWithKey (\key p->do
        let source=closedInput p
        let (forbidden,elided,_)=inputs M.! key
        changed<-M.traverseWithKey (\name original->if name `S.member` elided then pure (original,[],False) else do
          (output,decisions,touched)<-Inline.inlineClosedWithDecisions reporting forbidden (programNamespace source)
            (programTypes source) (programArities source) inlining original
          pure (output,decisions,touched)) (closedDefinitions p)
        let output=ClosedProgram source (closedLayouts p) (M.map (\(f,_,_)->f) changed)
              (closedDecisions p++concatMap (\(_,ds,_)->ds) (M.elems changed))
              (S.fromList [name | (name,(_,_,touched))<-M.toList changed,touched])
        verifyLinkedStep output
        pure output) programs
      pure (advanced,any (not . S.null . closedTouched) (M.elems advanced))

planVectorReads :: S.Set String -> ClosedProgram -> Either String ClosedProgram
planVectorReads elided input=do
  let types=programTypes (closedInput input)
      root f=let (body,planned)=VectorRead.planReads (functionBody f) in Right (f {functionBody=body},planned)
      code c=let (body,planned)=VectorRead.planReads (codeBody c) in Right (c {codeBody=body},planned)
  stepped<-M.traverseWithKey (\name f->if name `S.member` elided then pure (f,False)
    else mapClosedChanged types root code f) (closedDefinitions input)
  let output=ClosedProgram (closedInput input) (closedLayouts input) (M.map fst stepped) (closedDecisions input)
        (S.fromList [name | (name,(_,planned))<-M.toList stepped,planned])
  verifyLinkedStep output
  pure output

normalizeProgram :: S.Set String -> ClosedProgram -> Either String ClosedProgram
normalizeProgram elided input=do
  let types=programTypes (closedInput input)
  stepped<-M.traverseWithKey (\name f->if name `S.member` elided then pure (f,False)
    else Normalize.normalizeClosed types f) (closedDefinitions input)
  let output=ClosedProgram (closedInput input) (closedLayouts input) (M.map fst stepped) (closedDecisions input)
        (S.fromList [name | (name,(_,changed))<-M.toList stepped,changed])
  verifyLinkedStep output
  pure output

caseKnownProgram :: S.Set String -> ClosedProgram -> Either String ClosedProgram
caseKnownProgram elided input=do
  let types=programTypes (closedInput input)
  stepped<-M.traverseWithKey (\name f->if name `S.member` elided then pure (f,False)
    else CaseKnown.caseKnownClosed types f) (closedDefinitions input)
  let output=ClosedProgram (closedInput input) (closedLayouts input) (M.map fst stepped) (closedDecisions input)
        (S.fromList [name | (name,(_,changed))<-M.toList stepped,changed])
  verifyLinkedStep output
  pure output

fusePrograms :: Ord key => M.Map key (S.Set String,ClosedProgram) -> Either String (M.Map key (ClosedProgram,[Fusion.FusionNote]))
fusePrograms inputs=case map snd (M.elems inputs) of
  []->pure M.empty
  base:programs->do
    mapM_ (\p->unless (programNamespace (closedInput p)==programNamespace (closedInput base)
      && constructorLayouts (closedLayouts p)==constructorLayouts (closedLayouts base)
      && shapeLayouts (closedLayouts p)==shapeLayouts (closedLayouts base))
        (Left "typed fusion pipeline: checking namespace/layout mismatch")) programs
    let owned=[M.withoutKeys (closedDefinitions p) elided | (elided,p)<-M.elems inputs]
        owners=M.unions owned
        types=programTypes (closedInput base)
    unless (M.size owners==sum (map M.size owned)) (Left "typed fusion pipeline: duplicate source owner")
    snapshot<-Callbacks.catalogPrograms types (map (closedInput . snd) (M.elems inputs)) owners
    let plan=Fusion.planFusion snapshot
    traverse (\(elided,p)->do
      changed<-M.traverseWithKey (\name f->if S.member name elided then pure (f,[],False)
        else Fusion.fuseClosed (programNamespace (closedInput p)) types plan f) (closedDefinitions p)
      let output=ClosedProgram (closedInput p) (closedLayouts p) (M.map (\(f,_,_)->f) changed) (closedDecisions p)
            (S.fromList [name | (name,(_,_,fused))<-M.toList changed,fused])
      verifyLinkedStep output
      pure (output,concatMap (\(_,notes,_)->notes) (M.elems changed))) inputs

fuseListPrograms :: Ord key => M.Map key (S.Set String,ClosedProgram) -> Either String (M.Map key (ClosedProgram,[Fusion.FusionNote]))
fuseListPrograms inputs=case map snd (M.elems inputs) of
  []->pure M.empty
  base:programs->do
    mapM_ (\p->unless (programNamespace (closedInput p)==programNamespace (closedInput base)
      && constructorLayouts (closedLayouts p)==constructorLayouts (closedLayouts base)
      && shapeLayouts (closedLayouts p)==shapeLayouts (closedLayouts base))
        (Left "typed list fusion pipeline: checking namespace/layout mismatch")) programs
    let owned=[M.withoutKeys (closedDefinitions p) elided | (elided,p)<-M.elems inputs]
        owners=M.unions owned
        types=programTypes (closedInput base)
    unless (M.size owners==sum (map M.size owned)) (Left "typed list fusion pipeline: duplicate source owner")
    snapshot<-Callbacks.catalogPrograms types (map (closedInput . snd) (M.elems inputs)) owners
    traverse (\(elided,p)->do
      changed<-M.traverseWithKey (\name f->if S.member name elided then pure (f,[],False)
        else ListFusion.fuseListClosed (programNamespace (closedInput p)) types snapshot (Callbacks.catalogLibrary snapshot) f) (closedDefinitions p)
      let output=ClosedProgram (closedInput p) (closedLayouts p) (M.map (\(f,_,_)->f) changed) (closedDecisions p)
            (S.fromList [name | (name,(_,_,fused))<-M.toList changed,fused])
      verifyLinkedStep output
      pure (output,concatMap (\(_,notes,_)->notes) (M.elems changed))) inputs

verifyClosedProgram :: ClosedProgram -> Either String ()
verifyClosedProgram result=do
  verifyProgram input
  unless (M.keysSet definitions==M.keysSet source) (Left "typed pipeline: closed/source owner mismatch")
  unless (length labels==S.size (S.fromList labels)) (Left "typed pipeline: code label shared by definitions")
  unless (length ids==S.size (S.fromList ids)) (Left "typed pipeline: binder identity shared by definitions")
  mapM_ one (M.toList definitions)
  where
    input=closedInput result;definitions=closedDefinitions result;source=programFunctions input
    functions=concat [[closedRoot f]++map codeAsFunction (M.elems (closedCode f)) | f<-M.elems definitions]
    labels=map functionName functions
    ids=[binderId b | f<-functions,b<-functionParameters f++allBinders (functionBody f)]
    one (name,f)=do
      let expected=source M.! name;actual=closedRoot f
      unless (name==functionName actual && sameType (functionType expected) (functionType actual)
        && map binderId (functionParameters expected)==map binderId (functionParameters actual))
        (Left ("typed pipeline "++name++": changed root interface"))
      verifyClosed (programTypes input) f
      mapM_ (verifyProgramCalls input name . functionBody)
        (closedRoot f:map codeAsFunction (M.elems (closedCode f)))

-- A linked pass re-checks only what its producers do not already guarantee.
-- Every ClosedFunction arrives verified by the transform that built it
-- (mapClosed/rewriteClosed/closeFunctionWith), and the input program is
-- invariant across the pipeline and was checked by closeProgram. What
-- remains per pass: the cross-definition identity checks and, only for the
-- definitions the pass touched, the source interface and calling contracts.
verifyLinkedStep :: ClosedProgram -> Either String ()
verifyLinkedStep result=do
  unless (M.keysSet definitions==M.keysSet source) (Left "typed pipeline: closed/source owner mismatch")
  unless (length labels==S.size (S.fromList labels)) (Left "typed pipeline: code label shared by definitions")
  unless (length ids==S.size (S.fromList ids)) (Left "typed pipeline: binder identity shared by definitions")
  mapM_ one [(name,f) | (name,f)<-M.toList definitions,S.member name (closedTouched result)]
  where
    input=closedInput result;definitions=closedDefinitions result;source=programFunctions input
    functions=concat [[closedRoot f]++map codeAsFunction (M.elems (closedCode f)) | f<-M.elems definitions]
    labels=map functionName functions
    ids=[binderId b | f<-functions,b<-functionParameters f++allBinders (functionBody f)]
    one (name,f)=do
      let expected=source M.! name;actual=closedRoot f
      unless (name==functionName actual && sameType (functionType expected) (functionType actual)
        && map binderId (functionParameters expected)==map binderId (functionParameters actual))
        (Left ("typed pipeline "++name++": changed root interface"))
      mapM_ (verifyProgramCalls input name . functionBody)
        (closedRoot f:map codeAsFunction (M.elems (closedCode f)))
