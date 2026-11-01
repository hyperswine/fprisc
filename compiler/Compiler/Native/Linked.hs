-- Linked native inputs retain their checked owners until an explicit erased
-- projection. Constructor stubs may be visible in several inputs, but exactly
-- one artifact emits each symbol. Private code keeps its source owner/contract.
module Compiler.Native.Linked
  (ArtifactId(..),NativeArtifact,artifact,artifactId,artifactCore,artifactExports,artifactElided,
   LinkedProgram,linkArtifacts,specializeLinked,specializeLinkedWithDecisions,inlineLinked,inlineLinkedWithDecisions,planVectorReadsLinked,normalizeLinked,fuseLinked,fuseListLinked,linkedArtifacts,linkedSymbols,SymbolKey(..),SymbolOwner(..),Definition(..)) where
import Compiler.Native.Core
import Compiler.DataLayout
import Core.Typed.Program
import Core.Typed.Pipeline
import Core.Typed.Close
import Core.Typed.Contract (sameContract)
import Core.Typed.Callback (CallbackMode(..))
import Core.Typed.Fusion (FusionNote)
import Core.Typed.Syntax
import Core.Typed.Verify (instanceOf)
import Core.Typed.Walk (allBinders,mapChildrenM)
import Core.Identity
import Type.Syntax
import Control.Monad (unless,forM_)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data ArtifactId=RootArtifact | PreludeArtifact String | DependencyArtifact String
  deriving (Eq,Ord,Show)
data NativeArtifact=NativeArtifact ArtifactId (S.Set String) (S.Set String) NativeCore
artifactId :: NativeArtifact -> ArtifactId
artifactId (NativeArtifact k _ _ _)=k
artifactExports :: NativeArtifact -> S.Set String
artifactExports (NativeArtifact _ ns _ _)=ns
artifactElided :: NativeArtifact -> S.Set String
artifactElided (NativeArtifact _ _ ns _)=ns
artifactCore :: NativeArtifact -> NativeCore
artifactCore (NativeArtifact _ _ _ p)=p

-- Compatibility definitions deliberately have no invented typed contract.
data Definition=SourceDefinition String Scheme Int
  | PrivateDefinition String CodeId CodeContract
  | CompatibilityDefinition Int
  deriving Show
data SymbolKey=ExportedSymbol String | ArtifactSymbol ArtifactId String deriving (Eq,Ord,Show)
data SymbolOwner=SymbolOwner {symbolArtifact :: ArtifactId,symbolDefinition :: Definition}
  deriving Show
data LinkedProgram=LinkedProgram (M.Map ArtifactId NativeArtifact) (M.Map SymbolKey SymbolOwner)
linkedArtifacts :: LinkedProgram -> M.Map ArtifactId NativeArtifact
linkedArtifacts (LinkedProgram as _)=as
linkedSymbols :: LinkedProgram -> M.Map SymbolKey SymbolOwner
linkedSymbols (LinkedProgram _ ns)=ns

artifact :: ArtifactId -> S.Set String -> S.Set String -> NativeCore -> Either String NativeArtifact
artifact key exports elided core=do
  -- NativeCore is opaque and already verifies its closed graph before
  -- publication. Check only the new artifact boundary here.
  unless (exports `S.isSubsetOf` emitted) (bad "export lacks an emitted definition")
  -- Only layout-owned constructor stubs can be suppressed. Arbitrarily
  -- eliding a source or private function would discard its semantic owner.
  unless (elided `S.isSubsetOf` M.keysSet (constructorLayouts (closedLayouts closed))
    && (elided `S.intersection` M.keysSet (nativeProgram core)) `S.isSubsetOf` nativeConstructors core)
    (bad "elision lacks generated constructor authority")
  pure (NativeArtifact key exports elided core)
  where
    closed=nativeClosed core
    emitted=M.keysSet (nativeProgram core) S.\\ elided
    bad why=Left ("native artifact "++show key++": "++why)

linkArtifacts :: [NativeArtifact] -> Either String LinkedProgram
linkArtifacts inputs=do
  unless (length inputs==M.size artifacts) (bad "duplicate artifact identity")
  forM_ inputs $ \a->do
    unless (programNamespace (source a)==namespace) (bad "artifacts have different checking namespaces")
    unless (constructorLayouts (layouts a)==constructorLayouts common
      && shapeLayouts (layouts a)==shapeLayouts common) (bad "artifacts disagree on layout authority")
  unless (length definitions==M.size symbols) (bad "symbol has more than one emitting artifact")
  unless (length identities==S.size (S.fromList identities)) (bad "binder identity shared by artifacts")
  -- An elided constructor must actually have an owner in this image.
  unless (elisions `S.isSubsetOf` S.fromList [name | ExportedSymbol name<-M.keys symbols]) (bad "elided definition has no emitting owner")
  forM_ inputs $ \a->do
    checkReferences a
    forM_ (owned a) $ \(_,f)->forM_ (M.toList (closedImports f)) $ \(key@(CodeId name),contract)->
      case [c | (_,SymbolOwner _ (PrivateDefinition _ k c))<-M.toList symbols,k==key] of
        [published] | sameContract contract published->pure ()
        _->bad ("imported private contract disagrees with its home at "++name)
  pure (LinkedProgram artifacts symbols)
  where
    bad why=Left ("native link: "++why)
    artifacts=M.fromList [(artifactId a,a) | a<-inputs]
    source=closedInput . nativeClosed . artifactCore
    layouts=closedLayouts . nativeClosed . artifactCore
    namespace=case inputs of a:_->programNamespace (source a);[]->Namespace "empty"
    common=case inputs of a:_->layouts a;[]->Layouts M.empty M.empty
    emitted a=M.withoutKeys (nativeProgram (artifactCore a)) (artifactElided a)
    owned a=[(name,f) | (name,f)<-M.toList (closedDefinitions (nativeClosed (artifactCore a))),name `S.notMember` artifactElided a]
    functions a=concat [[closedRoot f]++map codeAsFunction (M.elems (closedCode f)) | (_,f)<-owned a]
    identities=[binderId b | a<-inputs,f<-functions a,b<-functionParameters f++allBinders (functionBody f)]
    definitions=concatMap entries inputs
    entries a=
      let p=source a
          typed=M.fromList ([(name,SourceDefinition name (programSchemas p M.! name) (length (functionParameters (closedRoot f)))) | (name,f)<-owned a]
            ++[(name,PrivateDefinition owner k c) | (owner,f)<-owned a,(k@(CodeId name),c)<-M.toList (closedOwnedContracts f)])
      in [(key name,SymbolOwner (artifactId a) (M.findWithDefault (CompatibilityDefinition (length ps)) name typed))
          | (name,(ps,_))<-M.toList (emitted a)]
      where key name=if name `S.member` artifactExports a then ExportedSymbol name else ArtifactSymbol (artifactId a) name
    symbols=M.fromList definitions
    privateNames=S.fromList [name | ArtifactSymbol _ name<-M.keys symbols]
    elisions=S.unions [artifactElided a `S.intersection` M.keysSet (nativeProgram (artifactCore a)) | a<-inputs]
    references e=(case exprNode e of Var (Global name _)->S.singleton name;_->S.empty)
      <>getConst (mapChildrenM (Const . references) e)
    equivalent a@(Forall _ _ at) b@(Forall _ _ bt)=instanceOf a bt && instanceOf b at
    checkReferences a=forM_ (S.toList (S.unions (map (references . functionBody) (functions a)))) $ \name->
      case M.lookup (ArtifactSymbol (artifactId a) name) symbols of
        Just _->pure ()
        Nothing->external a name
    external a name=case M.lookup (ExportedSymbol name) symbols of
        Just (SymbolOwner home definition) | home/=artifactId a->do
          let provider=artifacts M.! home
          unless (name `S.member` artifactExports provider) (bad ("cross-artifact reference to private symbol "++name))
          case definition of
            SourceDefinition _ published arity->do
              case M.lookup name (programSchemas (source a)) of
                Just declared | equivalent published declared->pure ()
                _->bad ("imported calling scheme disagrees at "++name)
              unless (M.lookup name (programArities (source a))==Just arity)
                (bad ("imported physical arity disagrees at "++name))
            -- This boundary cannot promote compatibility code or a private
            -- closure contract into a checked public source interface.
            CompatibilityDefinition arity->unless (M.lookup name (programArities (source a))==Just arity)
              (bad ("compatibility physical arity disagrees at "++name))
            PrivateDefinition {}->bad ("private code needs an explicit imported declaration: "++name)
        Just _->pure ()
        Nothing->unless (name `S.notMember` privateNames)
          (bad ("cross-artifact reference to private symbol "++name))

-- Re-link after cloning so every new entry receives its emitting owner and
-- every imported original code reference is checked against its actual home.
specializeLinked :: CallbackMode -> LinkedProgram -> Either String LinkedProgram
specializeLinked=specializeLinkedWithDecisions False
specializeLinkedWithDecisions :: Bool -> CallbackMode -> LinkedProgram -> Either String LinkedProgram
specializeLinkedWithDecisions _ PreserveCallbacks p=pure p
specializeLinkedWithDecisions reporting mode p=do
  let as=linkedArtifacts p
  cores<-specializeNativeProgramsWithDecisions reporting mode (M.map (\a->(artifactElided a,artifactCore a)) as)
  changed<-M.traverseWithKey (\key a->artifact key (artifactExports a) (artifactElided a) (cores M.! key)) as
  linkArtifacts (M.elems changed)

-- Link visibility, not a spelling heuristic, governs imported templates.
-- rounds, the node budget at an ordinary call site, the budget inside a loop
inlineLinked :: Int -> Int -> Int -> LinkedProgram -> Either String LinkedProgram
inlineLinked=inlineLinkedWithDecisions False
inlineLinkedWithDecisions :: Bool -> Int -> Int -> Int -> LinkedProgram -> Either String LinkedProgram
inlineLinkedWithDecisions reporting rounds limit loopLimit p=do
  let inputs=M.mapWithKey (\key a->(S.fromList [name | (ArtifactSymbol home name,_)<-M.toList (linkedSymbols p),home/=key],artifactElided a,artifactCore a)) (linkedArtifacts p)
  changed<-inlineNativeProgramsWithDecisions reporting rounds limit loopLimit inputs
  artifacts<-M.traverseWithKey (\key a->artifact key (artifactExports a) (artifactElided a) (changed M.! key)) (linkedArtifacts p)
  linkArtifacts (M.elems artifacts)

planVectorReadsLinked :: LinkedProgram -> Either String LinkedProgram
planVectorReadsLinked p=do
  changed<-mapM (\a->do
    core<-planNativeVectorReads (artifactElided a) (artifactCore a)
    artifact (artifactId a) (artifactExports a) (artifactElided a) core) (M.elems (linkedArtifacts p))
  linkArtifacts changed

normalizeLinked :: LinkedProgram -> Either String LinkedProgram
normalizeLinked p=do
  changed<-mapM (\a->do
    core<-normalizeNative (artifactElided a) (artifactCore a)
    artifact (artifactId a) (artifactExports a) (artifactElided a) core) (M.elems (linkedArtifacts p))
  linkArtifacts changed

fuseListLinked :: LinkedProgram -> Either String (LinkedProgram,[FusionNote])
fuseListLinked p=do
  changed<-fuseListNativePrograms (M.map (\a->(artifactElided a,artifactCore a)) (linkedArtifacts p))
  artifacts<-M.traverseWithKey (\key a->artifact key (artifactExports a) (artifactElided a) (fst (changed M.! key))) (linkedArtifacts p)
  output<-linkArtifacts (M.elems artifacts)
  pure (output,concatMap snd (M.elems changed))

fuseLinked :: LinkedProgram -> Either String (LinkedProgram,[FusionNote])
fuseLinked p=do
  changed<-fuseNativePrograms (M.map (\a->(artifactElided a,artifactCore a)) (linkedArtifacts p))
  artifacts<-M.traverseWithKey (\key a->artifact key (artifactExports a) (artifactElided a) (fst (changed M.! key))) (linkedArtifacts p)
  output<-linkArtifacts (M.elems artifacts)
  pure (output,concatMap snd (M.elems changed))
