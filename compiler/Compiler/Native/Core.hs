{-# LANGUAGE FlexibleContexts #-}
-- The native compatibility boundary. Checked semantic programs remain owned
-- through layout/closing; only this adapter publishes erased Core downstream.
module Compiler.Native.Core
  (NativeCore,compileSelection,compileSelectionAt,nativeProgram,nativeJoins,nativeClosed,nativeCompatibility,nativeFresh) where
import qualified Core.Typed.Syntax as T
import Core.Typed.Program
import Core.Typed.Pipeline
import Core.Typed.Close
import Core.Typed.Callback (CallbackMode)
import Core.Typed.Erase
import Core.Typed.Walk (allBinders,mapChildrenM)
import Core.Syntax
import Compiler.DataLayout
import Frontend.Desugar.Typed
import qualified Frontend.Desugar as Legacy
import Control.Monad.State.Strict
import Control.Monad (unless,forM)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data NativeCore=NativeCore ClosedProgram Prog (S.Set String) (M.Map String String) Int
nativeProgram (NativeCore _ p _ _ _)=p
nativeJoins (NativeCore _ _ js _ _)=js
nativeClosed (NativeCore p _ _ _ _)=p
nativeCompatibility (NativeCore _ _ _ cs _)=cs
nativeFresh (NativeCore _ _ _ _ n)=n

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
  unless (all (noLambda . snd) (M.elems output)) (Left "native Core: implicit lambda remains at erasure boundary")
  pure (NativeCore closed output joins (M.map compatibilityReason compatibility) (Legacy.dFresh state))

eraseClosed :: ClosedProgram -> Either String Prog
eraseClosed closed=do
  verifyClosedProgram closed
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
