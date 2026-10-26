{-# LANGUAGE FlexibleContexts #-}
-- Native semantic passes operate on a complete owned program before erasure.
-- Layout authority stays attached to the closed product it helped construct.
module Core.Typed.Pipeline
  (ClosedProgram,closeProgram,specializeProgramWith,specializePrograms,inlinePrograms,planVectorReads,normalizeProgram,fusePrograms,closedInput,closedDefinitions,closedLayouts,verifyClosedProgram) where
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
import qualified Core.Typed.Fusion as Fusion
import Core.Typed.Verify (sameType)
import Core.Typed.Walk (allBinders,mapChildrenM)
import Compiler.DataLayout
import Control.Monad.State.Strict
import Control.Monad (unless,foldM)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data ClosedProgram=ClosedProgram Program Layouts (M.Map String ClosedFunction)
closedInput (ClosedProgram p _ _)=p
closedDefinitions (ClosedProgram _ _ fs)=fs
closedLayouts (ClosedProgram _ layouts _)=layouts

closeProgram :: CallbackMode -> Layouts -> Program -> Either String ClosedProgram
closeProgram mode layouts input=do
  verifyProgram input
  definitions<-M.traverseWithKey one (programFunctions input)
  let result=ClosedProgram input layouts definitions
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
  specializeSnapshot S.empty snapshot (snapshotInterfaces snapshot) p
  where
    input=closedInput p;layouts=closedLayouts p
    catalog=M.unions (map closedDefinitions (p:providers))

-- Share a checked catalog across all linked artifacts. Constructor elision
-- selects a unique template owner without replacing an artifact's own stubs.
specializePrograms :: Ord key => CallbackMode -> M.Map key (S.Set String,ClosedProgram) -> Either String (M.Map key ClosedProgram)
specializePrograms PreserveCallbacks inputs=Right (M.map snd inputs)
specializePrograms _ inputs=case map snd (M.elems inputs) of
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
    traverse (\(elided,p)->specializeSnapshot elided snapshot interfaces p) inputs

snapshotInterfaces :: Callbacks.Catalog -> M.Map CodeId (String,Function)
snapshotInterfaces snapshot=M.fromList (concat
  [[(CodeId name,(name,closedRoot f))]
    ++[(key,(name,codeAsFunction c)) | (key,c)<-M.toList (closedCode f)]
  | (name,f)<-M.toList (Callbacks.catalogOwners snapshot)])

-- Elided definitions are constructor stubs another artifact owns and emits;
-- every linked pass transforms them there and passes this artifact's copy
-- through unchanged (see ownedOnly). Verification still covers them.
specializeSnapshot :: S.Set String -> Callbacks.Catalog -> M.Map CodeId (String,Function) -> ClosedProgram -> Either String ClosedProgram
specializeSnapshot elided snapshot templates p=do
  let input=closedInput p
  definitions<-ownedOnly elided (\original->callbackClosed <$> specializeClosedFromCatalog (programNamespace input)
    (programTypes input) (programArities input) snapshot original) (closedDefinitions p)
  mapM_ (\origin->case M.lookup (cloneTemplate origin) templates of
    Just (owner,fn) | cloneSource origin==owner,
      map fst (cloneBindings origin)==map binderId (functionParameters fn)->pure ()
    _->Left "typed pipeline: clone source/parameter provenance disagrees")
    [origin | f<-M.elems definitions,origin<-M.elems (closedOrigins f)]
  let result=ClosedProgram input (closedLayouts p) definitions
  verifyClosedProgram result
  pure result

-- All owned artifacts advance against one immutable snapshot per round.
-- Forbidden globals are linker-private source entries from other artifacts;
-- their bodies cannot be copied into a caller without an import contract.
inlinePrograms :: Ord key => Int -> Int -> M.Map key (S.Set String,S.Set String,ClosedProgram) -> Either String (M.Map key ClosedProgram)
inlinePrograms rounds limit inputs=do
  unless (rounds>=0 && limit>=0) (Left "typed inline pipeline: negative round/node budget")
  let programs=[p | (_,_,p)<-M.elems inputs]
  case programs of
    []->pure M.empty
    base:_->do
      mapM_ (\p->unless (programNamespace (closedInput p)==programNamespace (closedInput base)
        && constructorLayouts (closedLayouts p)==constructorLayouts (closedLayouts base)
        && shapeLayouts (closedLayouts p)==shapeLayouts (closedLayouts base))
          (Left "typed inline pipeline: checking namespace/layout mismatch")) programs
      foldM step (M.map (\(_,_,p)->p) inputs) [1..rounds]
  where
    step programs _=do
      let allPrograms=M.elems programs
          owned=M.mapWithKey (\key p->let (_,elided,_)=inputs M.! key in M.withoutKeys (closedDefinitions p) elided) programs
          owners=M.unions (M.elems owned)
      unless (M.size owners==sum (map M.size (M.elems owned)))
        (Left "typed inline pipeline: duplicate source owner")
      let types=programTypes (closedInput (head allPrograms))
      snapshot<-Callbacks.catalogPrograms types (map closedInput allPrograms) owners
      inlining<-Inline.planInlining limit snapshot
      M.traverseWithKey (\key p->do
        let source=closedInput p
        let (forbidden,elided,_)=inputs M.! key
        definitions<-ownedOnly elided (Inline.inlineClosed forbidden (programNamespace source)
          (programTypes source) (programArities source) inlining) (closedDefinitions p)
        let output=ClosedProgram source (closedLayouts p) definitions
        verifyClosedProgram output
        pure output) programs

planVectorReads :: S.Set String -> ClosedProgram -> Either String ClosedProgram
planVectorReads elided input=do
  let types=programTypes (closedInput input)
      root f=Right f {functionBody=VectorRead.planReads (functionBody f)}
      code c=Right c {codeBody=VectorRead.planReads (codeBody c)}
  definitions<-ownedOnly elided (mapClosed types root code) (closedDefinitions input)
  let output=ClosedProgram (closedInput input) (closedLayouts input) definitions
  verifyClosedProgram output
  pure output

normalizeProgram :: S.Set String -> ClosedProgram -> Either String ClosedProgram
normalizeProgram elided input=do
  definitions<-ownedOnly elided (Normalize.normalizeClosed (programTypes (closedInput input))) (closedDefinitions input)
  let output=ClosedProgram (closedInput input) (closedLayouts input) definitions
  verifyClosedProgram output
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
      changed<-M.traverseWithKey (\name f->if S.member name elided then pure (f,[])
        else Fusion.fuseClosed (programNamespace (closedInput p)) types plan f) (closedDefinitions p)
      let output=ClosedProgram (closedInput p) (closedLayouts p) (M.map fst changed)
      verifyClosedProgram output
      pure (output,concatMap snd (M.elems changed))) inputs

-- Transform the definitions this artifact owns. Each artifact's program
-- carries a stub for every constructor of the program (the inliner and the
-- compatibility lowering read them), but only the owner emits one; the
-- others elide it. Transforming those copies in every artifact was most of
-- each linked pass's work (docs/2026-10-26-COMPILE-TIME-BUDGET.md).
ownedOnly :: Monad m => S.Set String -> (a -> m a) -> M.Map String a -> m (M.Map String a)
ownedOnly elided f=M.traverseWithKey (\name x->if S.member name elided then pure x else f x)

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
