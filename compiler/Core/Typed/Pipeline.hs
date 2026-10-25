{-# LANGUAGE FlexibleContexts #-}
-- Native semantic passes operate on a complete owned program before erasure.
-- Layout authority stays attached to the closed product it helped construct.
module Core.Typed.Pipeline
  (ClosedProgram,closeProgram,closedInput,closedDefinitions,closedLayouts,verifyClosedProgram) where
import Core.Typed.Program
import Core.Typed.Syntax
import Core.Typed.Layout
import Core.Typed.Close
import Core.Typed.Stage
import Core.Typed.Resolve
import Core.Typed.Callback
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
  pure result
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
      callbackClosed <$> specializeCallbacks mode (programNamespace input) types (programArities input) resolved
    globals e=(case exprNode e of Var (Global n _)->S.singleton n;_->S.empty)
      <>getConst (mapChildrenM (Const . globals) e)

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
