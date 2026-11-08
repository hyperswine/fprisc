{-# LANGUAGE FlexibleContexts #-}
-- The native compatibility boundary. Checked semantic programs remain owned
-- through layout/closing; only this adapter publishes erased Core downstream.
module Compiler.Native.Core
  (NativeCore,eraseDefinitions,compileSelection,compileSelectionAt,compileSelectionBase,compileSelectionTypeSpecialized,compileSelectionTypeSpecializedKeepingEntries,specializeNativeWith,specializeNativePrograms,specializeNativeProgramsWithDecisions,inlineNativePrograms,inlineNativeProgramsWithDecisions,planNativeVectorReads,normalizeNative,caseKnownNative,fuseNativePrograms,fuseListNativePrograms,fuseListNativeProgramsWithHelpers,trmcNativePrograms,nativeProgram,nativeJoins,nativeClosed,nativeCompatibility,nativeDeclarations,nativeConstructors,nativeFresh,nativeTypeSpecNotes,nativeTypeInstances,annotatedProgram,
   CheckedDefinition,nativeDefinitions,checkedOwner,checkedFunction,checkedContracts,nativeTypeInstanceDeclarations) where
import qualified Core.Typed.Syntax as T
import Core.Typed.Program
import Core.Typed.Pipeline
import Core.Typed.Close
import Core.Typed.Callback (CallbackMode(..))
import qualified Core.Typed.BaseTransport as BaseTransport
import qualified Core.Typed.Carrier as Carrier
import Core.Typed.Parametric (Catalog)
import qualified Core.Typed.Monomorphize as Monomorphize
import Core.Typed.Fusion (FusionNote)
import Core.Typed.Erase
import Core.Typed.Walk (allBinders,mapChildrenM)
import Core.Syntax
import qualified Core.Calling as Calling
import Compiler.DataLayout
import Frontend.Desugar.Typed
import qualified Frontend.Desugar as Legacy
import Control.Monad.State.Strict
import Control.Monad (unless,forM)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Type.Syntax (Type,Scheme)

data NativeCore=NativeCore ClosedProgram Prog (S.Set String) (M.Map String String) (M.Map String Calling.Calling) (S.Set String) Int [(String,String)] (M.Map String (String,Scheme,Int))
nativeProgram (NativeCore _ p _ _ _ _ _ _ _)=p
nativeJoins (NativeCore _ _ js _ _ _ _ _ _)=js
nativeClosed (NativeCore p _ _ _ _ _ _ _ _)=p
nativeCompatibility (NativeCore _ _ _ cs _ _ _ _ _)=cs
nativeDeclarations (NativeCore _ _ _ _ ds _ _ _ _)=ds
nativeConstructors (NativeCore _ _ _ _ _ ns _ _ _)=ns
nativeFresh (NativeCore _ _ _ _ _ _ n _ _)=n
nativeTypeSpecNotes (NativeCore _ _ _ _ _ _ _ notes _)=notes
-- Includes local instances and declarations from the shared checked catalog.
-- Transformations must not discard imported provenance:
-- otherwise a lost home could be mistaken for an undeclared runtime external.
nativeTypeInstances=M.map (\(origin,_,_)->origin) . typeInstanceCatalog
nativeTypeInstanceDeclarations=M.map (\(_,schema,arity)->(schema,arity)) . typeInstanceCatalog
typeInstanceCatalog (NativeCore _ _ _ _ _ _ _ _ instances)=instances

inheritTypeInstances available (NativeCore closed p js cs ds ns serial notes instances)=
  NativeCore closed p js cs ds ns serial notes (instances `M.union` available)

-- A flattened checked entry retains its language owner and complete code
-- context. Consumers do not assemble body/owner/contract tuples themselves.
data CheckedDefinition=CheckedDefinition Name T.Function (M.Map T.CodeId T.CodeContract)
checkedOwner (CheckedDefinition owner _ _)=owner
checkedFunction (CheckedDefinition _ function _)=function
checkedContracts (CheckedDefinition _ _ contracts)=contracts
nativeDefinitions :: NativeCore -> M.Map Name CheckedDefinition
nativeDefinitions native=M.fromList (concatMap entries (M.toList (closedDefinitions (nativeClosed native))))
  where
    entries (owner,f)=entry (closedRoot f):map (entry . T.codeAsFunction) (M.elems (closedCode f))
      where
        contracts=closedContracts f
        entry fn=(T.functionName fn,CheckedDefinition owner fn contracts)

compileSelection :: CallbackMode -> Layouts -> SourceSelection -> Either String NativeCore
compileSelection=compileSelectionAt 0

-- The compatibility facade may share a legacy fresh supply with its caller.
-- Fully checked programs never consume it.
compileSelectionAt :: Int -> CallbackMode -> Layouts -> SourceSelection -> Either String NativeCore
compileSelectionAt first=compileSelectionWith first Nothing

compileSelectionTypeSpecialized :: S.Set String -> CallbackMode -> Layouts -> SourceSelection -> Either String NativeCore
compileSelectionTypeSpecialized pinned=compileSelectionWith 0 (Just (Monomorphize.monomorphizeWithOrigins pinned))

-- Separately emitted units keep their complete original entry set. Private
-- checked instances may be added, but callers in other units, function values
-- and dynamic entries continue to enter through the original tagged contract.
-- Instance identities still depend only on the source name and complete type.
-- The consumer selects only types that its representation lowering can use.
compileSelectionTypeSpecializedKeepingEntries :: (Type -> Bool) -> S.Set String -> CallbackMode -> Layouts -> SourceSelection -> Either String NativeCore
compileSelectionTypeSpecializedKeepingEntries admitted pinned=compileSelectionWith 0 (Just (Monomorphize.monomorphizeKeepingEntriesWithOrigins admitted pinned))

compileSelectionBase :: Maybe (String,Catalog) -> Bool -> S.Set String -> CallbackMode -> Layouts -> SourceSelection -> Either String NativeCore
compileSelectionBase catalog reporting pinned=compileSelectionWith 0 (Just specialize)
  where
    specialize retained input=do
      (carried,notes,origins)<-case catalog of
        Nothing->pure (input,[],M.empty)
        Just (home,evidence)->Carrier.specializeCarriers reporting home evidence pinned input
      (output,more,instances)<-BaseTransport.specializeTransport reporting pinned retained carried
      pure (output,notes++more,origins `M.union` instances)

compileSelectionWith first specialization mode layouts selected=do
  let compatibility=selectionCompatibility selected
      lower=do
        roots<-M.fromList <$> mapM (Legacy.compileGroup . fmap compatibilityClauses) (M.toAscList compatibility)
        Legacy.liftFix roots
      initial=Legacy.DEnv first (constructorLayouts layouts) (shapeLayouts layouts) [] []
      (fallback,state)=if M.null compatibility then (M.empty,initial) else runState lower initial
      retained=selectionConstructors selected `S.union` S.fromList (concatMap (freeVars . snd) (M.elems fallback))
  (input,notes,typeInstances)<-case specialization of
    Nothing->pure (selectionProgram selected,[],M.empty)
    Just specialize->specialize retained (selectionProgram selected)
  closed<-closeProgram mode layouts input
  covered<-eraseClosed closed
  let collisions=M.keysSet covered `S.intersection` M.keysSet fallback
  unless (S.null collisions) (Left ("native Core: checked/compatibility symbol collision: "++unwords (S.toList collisions)))
  let roots=closedDefinitions closed
      joins=S.fromList [name | f<-M.elems roots,c<-M.elems (closedCode f),T.codeKind c==T.JoinCode,let T.CodeId name=T.codeId c]
        <>S.fromList (Legacy.dJoins state)
      output=covered `M.union` fallback
      declarations=M.mapMaybe compatibilityDeclaration compatibility
  mapM_ (\(name,d)->unless (Just (Calling.callingArity d)==(length . fst <$> M.lookup name fallback))
    (Left ("native Core: checked compatibility declaration changed physical arity: "++name))) (M.toList declarations)
  unless (all (noLambda . snd) (M.elems output)) (Left "native Core: implicit lambda remains at erasure boundary")
  let instances=M.mapWithKey (\name origin->(origin,programSchemas input M.! name,programArities input M.! name)) typeInstances
  pure (NativeCore closed output joins (M.map compatibilityReason compatibility) declarations (selectionConstructors selected) (Legacy.dFresh state) notes instances)

specializeNativeWith :: CallbackMode -> [NativeCore] -> NativeCore -> Either String NativeCore
specializeNativeWith PreserveCallbacks _ input=pure input
specializeNativeWith mode providers (NativeCore closed p js compatibility declarations constructors serial notes typeInstances)=do
  specialized<-specializeProgramWith mode (map nativeClosed providers) closed
  inheritTypeInstances (M.unions (map typeInstanceCatalog providers)) <$> replaceClosed specialized (NativeCore closed p js compatibility declarations constructors serial notes typeInstances)

specializeNativePrograms :: Ord key => CallbackMode -> M.Map key (S.Set String,NativeCore) -> Either String (M.Map key NativeCore)
specializeNativePrograms=specializeNativeProgramsWithDecisions False
specializeNativeProgramsWithDecisions :: Ord key => Bool -> CallbackMode -> M.Map key (S.Set String,NativeCore) -> Either String (M.Map key NativeCore)
specializeNativeProgramsWithDecisions reporting mode inputs=do
  changed<-specializeProgramsWithDecisions reporting mode (M.map (\(elided,core)->(elided,nativeClosed core)) inputs)
  let available=M.unions [typeInstanceCatalog c | (_,c)<-M.elems inputs]
  M.traverseWithKey (\key (_,core)->inheritTypeInstances available
    <$> replaceClosed (changed M.! key) core) inputs

inlineNativePrograms :: Ord key => Int -> Int -> Int -> M.Map key (S.Set String,S.Set String,NativeCore) -> Either String (M.Map key NativeCore)
inlineNativePrograms=inlineNativeProgramsWithDecisions False
inlineNativeProgramsWithDecisions :: Ord key => Bool -> Int -> Int -> Int -> M.Map key (S.Set String,S.Set String,NativeCore) -> Either String (M.Map key NativeCore)
inlineNativeProgramsWithDecisions reporting rounds limit loopLimit inputs=do
  changed<-inlineProgramsWithDecisions reporting rounds limit loopLimit (M.map (\(forbidden,elided,core)->(forbidden,elided,nativeClosed core)) inputs)
  let available=M.unions [typeInstanceCatalog c | (_,_,c)<-M.elems inputs]
  M.traverseWithKey (\key (_,_,core)->inheritTypeInstances available
    <$> replaceClosed (changed M.! key) core) inputs

planNativeVectorReads :: S.Set String -> NativeCore -> Either String NativeCore
planNativeVectorReads elided input=planVectorReads elided (nativeClosed input) >>= (`replaceClosed` input)

normalizeNative :: S.Set String -> NativeCore -> Either String NativeCore
normalizeNative elided input=normalizeProgram elided (nativeClosed input) >>= (`replaceClosed` input)

-- Nothing when the pass resolved no case, so the product is kept as is.
caseKnownNative :: S.Set String -> NativeCore -> Either String (Maybe NativeCore)
caseKnownNative elided input=do
  stepped<-caseKnownProgram elided (nativeClosed input)
  if S.null (closedTouched stepped) then pure Nothing else Just <$> replaceClosed stepped input

fuseListNativePrograms :: Ord key => M.Map key (S.Set String,NativeCore) -> Either String (M.Map key (NativeCore,[FusionNote]))
fuseListNativePrograms=fuseListNativeProgramsWithHelpers False False . M.map (\(elided,core)->(S.empty,elided,core))

fuseListNativeProgramsWithHelpers :: Ord key => Bool -> Bool -> M.Map key (S.Set String,S.Set String,NativeCore) -> Either String (M.Map key (NativeCore,[FusionNote]))
fuseListNativeProgramsWithHelpers reporting helpers inputs=do
  changed<-fuseListProgramsWithHelpers reporting helpers (M.map (\(forbidden,elided,core)->(forbidden,elided,nativeClosed core)) inputs)
  let available=M.unions [typeInstanceCatalog c | (_,_,c)<-M.elems inputs]
  M.traverseWithKey (\key (_,_,core)->do
    let (closed,notes)=changed M.! key
    result<-inheritTypeInstances available <$> replaceClosed closed core
    pure (result,notes)) inputs

trmcNativePrograms :: Ord key => M.Map key (S.Set String,NativeCore) -> Either String (M.Map key (NativeCore,(Int,Int)))
trmcNativePrograms inputs=do
  changed<-trmcPrograms (M.map (\(elided,core)->(elided,nativeClosed core)) inputs)
  M.traverseWithKey (\key (_,core)->do
    let (closed,notes)=changed M.! key
    result<-replaceClosed closed core
    pure (result,notes)) inputs

fuseNativePrograms :: Ord key => M.Map key (S.Set String,NativeCore) -> Either String (M.Map key (NativeCore,[FusionNote]))
fuseNativePrograms inputs=do
  changed<-fusePrograms (M.map (\(elided,core)->(elided,nativeClosed core)) inputs)
  let available=M.unions [typeInstanceCatalog c | (_,c)<-M.elems inputs]
  M.traverseWithKey (\key (_,core)->do
    let (closed,notes)=changed M.! key
    result<-inheritTypeInstances available <$> replaceClosed closed core
    pure (result,notes)) inputs

replaceClosed :: ClosedProgram -> NativeCore -> Either String NativeCore
replaceClosed specialized (NativeCore closed p js compatibility declarations constructors serial notes typeInstances)=do
  let checkedNames=M.keysSet (closedDefinitions closed)<>
        S.fromList [name | f<-M.elems (closedDefinitions closed),T.CodeId name<-M.keys (closedCode f)]
      newDefinitions=closedDefinitions specialized
      touched=closedTouched specialized `S.intersection` M.keysSet newDefinitions
      -- Erased entries of untouched definitions carry over from the previous
      -- program; per-definition fresh supplies make a partial erase identical.
      kept=S.fromList [label | (name,f)<-M.toList newDefinitions,S.notMember name touched,
        label<-name:[n | T.CodeId n<-M.keys (closedCode f)]]
  erasedChanged<-eraseDefinitions specialized (S.toList touched)
  let legacy=M.withoutKeys p checkedNames
      checkedAfter=erasedChanged `M.union` M.restrictKeys p kept
      joins=S.fromList [name | f<-M.elems newDefinitions,c<-M.elems (closedCode f),
        T.codeKind c==T.JoinCode,let T.CodeId name=T.codeId c]
        <> (js S.\\ checkedNames)
  unless (S.null (M.keysSet legacy `S.intersection` M.keysSet checkedAfter))
    (Left "native Core: callback clone collides with compatibility definition")
  pure (NativeCore specialized (checkedAfter `M.union` legacy) joins compatibility declarations constructors serial notes typeInstances)

eraseClosed :: ClosedProgram -> Either String Prog
eraseClosed closed=eraseDefinitions closed (M.keys (closedDefinitions closed))

-- Erase only the named owners and their code. Each definition's fresh supply
-- starts at zero, so partial erasure yields the same entries as a full one.
eraseDefinitions :: ClosedProgram -> [String] -> Either String Prog
eraseDefinitions=eraseDefinitionsWith (\_ -> id)

-- Re-erase the retained checked owners with a boundary-specific annotation;
-- compatibility owners keep their existing projection and never borrow it.
annotatedProgram :: (T.Expr -> Core -> Core) -> NativeCore -> Either String Prog
annotatedProgram annotation native=do
  let closed=nativeClosed native
  checked<-eraseDefinitionsWith annotation closed (M.keys (closedDefinitions closed))
  pure (checked `M.union` M.withoutKeys (nativeProgram native) (M.keysSet checked))

eraseDefinitionsWith annotation closed owners=do
  -- ClosedProgram's producers already verify every changed graph. Erasure
  -- checks each expression/interface through eraseFunctionWith below.
  outputs<-mapM one functions
  pure (M.fromList outputs)
  where
    input=closedInput closed;types=programTypes input;layouts=closedLayouts closed
    wanted=S.fromList owners
    roots=[f | (name,f)<-M.toList (closedDefinitions closed),S.member name wanted]
    functions=[(f,T.functionName (closedRoot f),closedRoot f) | f<-roots]
      ++[(f,name,T.codeAsFunction code) | f<-roots,code<-M.elems (closedCode f),let T.CodeId name=T.codeId code]
    globals e=(case T.exprNode e of T.Var (T.Global n _)->S.singleton n;_->S.empty)
      <>getConst (mapChildrenM (Const . globals) e)
    one (owner,name,fn)=do
      let reserved=M.keysSet (programSchemas input)<>globals (T.functionBody fn)
            <>S.fromList (map T.binderName (T.functionParameters fn++allBinders (T.functionBody fn)))
          fresh stem=do
            n<-get;put (n+1)
            let spelling="$typed.erase."++show (length name)++"."++name++"."++stem++"."++show (n::Int)
            if spelling `S.member` reserved then fresh stem else pure spelling
          constructor n=case M.lookup n (constructorLayouts layouts) of Just c->Just c;Nothing->wideTup n
          -- Closed Core contains explicit joins. Erasure cannot secretly
          -- manufacture another untyped function or invoke lambda lifting.
          layout=Layout fresh constructor (shapeLayouts layouts) (\_ _ _->lift (Left "native Core: erasure manufactured an implicit join"))
      body<-evalStateT (eraseFunctionAnnotated annotation (closedContracts owner) types layout fn) 0 >>= id
      pure (name,body)

noLambda e=case e of
  CLam _ _->False
  CApp a b->noLambda a && noLambda b
  CLet _ a b->noLambda a && noLambda b
  CIf a b c->all noLambda [a,b,c]
  CMk _ _ xs->all noLambda xs
  CTagEq _ _ x->noLambda x
  CProj _ x->noLambda x
  _->True
