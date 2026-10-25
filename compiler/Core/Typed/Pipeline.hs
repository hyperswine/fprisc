{-# LANGUAGE FlexibleContexts #-}
-- Native semantic passes operate on a complete owned program before erasure.
-- Layout authority stays attached to the closed product it helped construct.
module Core.Typed.Pipeline
  (ClosedProgram,closeProgram,specializeProgramWith,closedInput,closedDefinitions,closedLayouts,verifyClosedProgram) where
import Core.Typed.Program
import Core.Typed.Syntax
import Core.Typed.Layout
import Core.Typed.Close
import Core.Typed.Stage
import Core.Typed.Resolve
import Core.Typed.Callback
import qualified Core.Typed.Callback.Catalog as Callbacks
import Core.Typed.Verify (sameType)
import Core.Typed.Walk (allBinders,mapChildrenM)
import Compiler.DataLayout
import Control.Monad.State.Strict
import Control.Monad (unless)
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
specializeProgramWith mode providers p=do
  -- Providers are opaque verified products. Check the new namespace/layout
  -- relationship here and verify the transformed output once below.
  mapM_ (\q->unless (programNamespace (closedInput q)==programNamespace input
    && constructorLayouts (closedLayouts q)==constructorLayouts layouts
    && shapeLayouts (closedLayouts q)==shapeLayouts layouts)
      (Left "typed pipeline: callback provider namespace/layout mismatch")) providers
  snapshot<-Callbacks.catalogPrograms (programTypes input) (map closedInput (p:providers)) catalog
  definitions<-M.traverseWithKey (\name _->callbackClosed <$> specializeFromCatalog (programNamespace input)
    (programTypes input) (programArities input) snapshot name) (closedDefinitions p)
  mapM_ (\origin->case M.lookup (cloneTemplate origin) templates of
    Just (owner,fn) | cloneSource origin==owner,
      map fst (cloneBindings origin)==map binderId (functionParameters fn)->pure ()
    _->Left "typed pipeline: clone source/parameter provenance disagrees")
    [origin | f<-M.elems definitions,origin<-M.elems (closedOrigins f)]
  let result=ClosedProgram input layouts definitions
  verifyClosedProgram result
  pure result
  where
    input=closedInput p;layouts=closedLayouts p
    catalog=M.unions (map closedDefinitions (p:providers))
    templates=M.fromList (concat
      [[(CodeId name,(name,closedRoot f))]
        ++[(key,(name,codeAsFunction c)) | (key,c)<-M.toList (closedCode f)]
      | (name,f)<-M.toList catalog])

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
