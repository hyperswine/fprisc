{-# LANGUAGE FlexibleContexts #-}
-- Record-update branching precedes lifting: every layout alternative owns its
-- own typed expression occurrences, just as the old layout-then-lift path did.
module Core.Typed.Layout (LayoutFunction, planFunction, plannedFunction) where
import Core.Typed.Syntax
import Core.Typed.Walk
import Core.Typed.Verify (verifyFunction)
import Core.Identity
import Control.Monad.State.Strict
import Control.Monad.Except
import Control.Monad (forM,when)
import Data.List (nub,sort)
import qualified Data.Map.Strict as M

newtype LayoutFunction=LayoutFunction Function
plannedFunction :: LayoutFunction -> Function
plannedFunction (LayoutFunction f)=f

planFunction :: Namespace -> M.Map [String] Int -> TypeContext -> Function -> Either String LayoutFunction
planFunction (Namespace ns) shapes types input=do
  verifyFunction types input
  body<-evalStateT (go (functionBody input)) (0::Int)
  let output=input {functionBody=body}
  verifyFunction types output
  pure (LayoutFunction output)
  where
    namespace=Namespace (ns++"/layout/"++functionName input)
    clone x=do
      names<-forM (allBinders x) $ \b->do
        n<-get; put (n+1)
        pure (binderId b,BinderId namespace n)
      pure (renameBinders (M.fromList names) x)
    go e=case exprNode e of
      RecordUpdate base fields->do
        base'<-go base
        tree<-plan fields
        pure e {exprNode=PlannedUpdate base' tree}
      PlannedUpdate _ _->throwError "typed layout: record update already planned"
      _->mapChildrenM go e
    plan assigns=do
      let roots=nub [root | (root:_,_)<-assigns]
          candidates=[(sort fs,tid) | (fs,tid)<-M.toList shapes,all (`elem` fs) roots]
      when (null candidates) (throwError ("typed layout: no record shape has fields "++show roots))
      branches<-forM candidates $ \(fs,tid)->do
        fields<-forM fs $ \name->do
          value<-case [(p,x) | (p@(root:_),x)<-assigns,root==name] of
            []->pure KeepField
            [([_],x)]->ReplaceField <$> (clone x >>= go)
            deeper->NestedUpdate <$> plan [(drop 1 p,x) | (p,x)<-deeper]
          pure (name,value)
        pure (UpdateBranch tid fields)
      pure (UpdatePlan roots branches)
