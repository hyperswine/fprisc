{-# LANGUAGE FlexibleContexts #-}
-- The native compatibility boundary. Checked semantic programs remain owned
-- through layout/closing; only this adapter publishes erased Core downstream.
module Compiler.Native.Core
  (NativeCore,compileSelection,compileSelectionAt,specializeNativeWith,specializeNativePrograms,inlineNativePrograms,planNativeVectorReads,nativeProgram,nativeJoins,nativeClosed,nativeCompatibility,nativeDeclarations,nativeConstructors,nativeFresh,
   CheckedDefinition,nativeDefinitions,checkedOwner,checkedFunction,checkedContracts) where
import qualified Core.Typed.Syntax as T
import Core.Typed.Program
import Core.Typed.Pipeline
import Core.Typed.Close
import Core.Typed.Callback (CallbackMode(..))
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

data NativeCore=NativeCore ClosedProgram Prog (S.Set String) (M.Map String String) (M.Map String Calling.Calling) (S.Set String) Int
nativeProgram (NativeCore _ p _ _ _ _ _)=p
nativeJoins (NativeCore _ _ js _ _ _ _)=js
nativeClosed (NativeCore p _ _ _ _ _ _)=p
nativeCompatibility (NativeCore _ _ _ cs _ _ _)=cs
nativeDeclarations (NativeCore _ _ _ _ ds _ _)=ds
nativeConstructors (NativeCore _ _ _ _ _ ns _)=ns
nativeFresh (NativeCore _ _ _ _ _ _ n)=n

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
compileSelectionAt first mode layouts selected=do
  closed<-closeProgram mode layouts (selectionProgram selected)
  covered<-eraseClosed closed
  let compatibility=selectionCompatibility selected
      lower=do
        roots<-M.fromList <$> mapM (Legacy.compileGroup . fmap compatibilityClauses) (M.toAscList compatibility)
        Legacy.liftFix roots
      initial=Legacy.DEnv first (constructorLayouts layouts) (shapeLayouts layouts) [] []
      (fallback,state)=if M.null compatibility then (M.empty,initial) else runState lower initial
      collisions=M.keysSet covered `S.intersection` M.keysSet fallback
  unless (S.null collisions) (Left ("native Core: checked/compatibility symbol collision: "++unwords (S.toList collisions)))
  let roots=closedDefinitions closed
      joins=S.fromList [name | f<-M.elems roots,c<-M.elems (closedCode f),T.codeKind c==T.JoinCode,let T.CodeId name=T.codeId c]
        <>S.fromList (Legacy.dJoins state)
      output=covered `M.union` fallback
      declarations=M.mapMaybe compatibilityDeclaration compatibility
  mapM_ (\(name,d)->unless (Just (Calling.callingArity d)==(length . fst <$> M.lookup name fallback))
    (Left ("native Core: checked compatibility declaration changed physical arity: "++name))) (M.toList declarations)
  unless (all (noLambda . snd) (M.elems output)) (Left "native Core: implicit lambda remains at erasure boundary")
  pure (NativeCore closed output joins (M.map compatibilityReason compatibility) declarations (selectionConstructors selected) (Legacy.dFresh state))

specializeNativeWith :: CallbackMode -> [NativeCore] -> NativeCore -> Either String NativeCore
specializeNativeWith PreserveCallbacks _ input=pure input
specializeNativeWith mode providers (NativeCore closed p js compatibility declarations constructors serial)=do
  specialized<-specializeProgramWith mode (map nativeClosed providers) closed
  replaceClosed specialized (NativeCore closed p js compatibility declarations constructors serial)

specializeNativePrograms :: Ord key => CallbackMode -> M.Map key (S.Set String,NativeCore) -> Either String (M.Map key NativeCore)
specializeNativePrograms mode inputs=do
  changed<-specializePrograms mode (M.map (\(elided,core)->(elided,nativeClosed core)) inputs)
  M.traverseWithKey (\key (_,core)->replaceClosed (changed M.! key) core) inputs

inlineNativePrograms :: Ord key => Int -> Int -> M.Map key (S.Set String,S.Set String,NativeCore) -> Either String (M.Map key NativeCore)
inlineNativePrograms rounds limit inputs=do
  changed<-inlinePrograms rounds limit (M.map (\(forbidden,elided,core)->(forbidden,elided,nativeClosed core)) inputs)
  M.traverseWithKey (\key (_,_,core)->replaceClosed (changed M.! key) core) inputs

planNativeVectorReads :: NativeCore -> Either String NativeCore
planNativeVectorReads input=planVectorReads (nativeClosed input) >>= (`replaceClosed` input)

replaceClosed :: ClosedProgram -> NativeCore -> Either String NativeCore
replaceClosed specialized (NativeCore closed p js compatibility declarations constructors serial)=do
  let checkedNames=M.keysSet (closedDefinitions closed)<>
        S.fromList [name | f<-M.elems (closedDefinitions closed),T.CodeId name<-M.keys (closedCode f)]
  checkedAfter<-eraseClosed specialized
  let legacy=M.withoutKeys p checkedNames
      joins=S.fromList [name | f<-M.elems (closedDefinitions specialized),c<-M.elems (closedCode f),
        T.codeKind c==T.JoinCode,let T.CodeId name=T.codeId c]
        <> (js S.\\ checkedNames)
  unless (S.null (M.keysSet legacy `S.intersection` M.keysSet checkedAfter))
    (Left "native Core: callback clone collides with compatibility definition")
  pure (NativeCore specialized (checkedAfter `M.union` legacy) joins compatibility declarations constructors serial)

eraseClosed :: ClosedProgram -> Either String Prog
eraseClosed closed=do
  -- ClosedProgram's producers already verify every changed graph. Erasure
  -- checks each expression/interface through eraseFunctionWith below.
  outputs<-mapM one functions
  pure (M.fromList outputs)
  where
    input=closedInput closed;types=programTypes input;layouts=closedLayouts closed
    roots=M.elems (closedDefinitions closed)
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
      body<-evalStateT (eraseFunctionWith (closedContracts owner) types layout fn) 0 >>= id
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
