{-# LANGUAGE FlexibleContexts #-}
-- Record-update branching precedes lifting: every layout alternative owns its
-- own typed expression occurrences, just as the old layout-then-lift path did.
module Core.Typed.Layout (LayoutFunction, planFunction, plannedFunction, recordShapes, closedRowShape) where
import Core.Typed.Syntax
import Core.Typed.Walk
import Core.Typed.Verify (verifyFunction)
import Core.Identity
import Control.Monad.State.Strict
import Control.Monad.Except
import Control.Monad (forM,when)
import Data.List (nub,sort)
import qualified Data.Map.Strict as M
import Type.Syntax (Type(..),Row(..))
import Type.Relation (fieldType)

recordFields (Just (TRec row))=collect row
  where collect RNil=([],True)
        collect (RV _)=([],False)
        collect (RExt n t rest)=let (fs,closed)=collect rest in ((n,t):fs,closed)
recordFields _=([],False)

-- Shared with erasure's independent stale-plan check. Only the checked row
-- type and the unit's complete shape catalog determine admissible branches.
closedRowShape :: Maybe Type -> Bool
closedRowShape = snd . recordFields

recordShapes :: M.Map [String] Int -> Maybe Type -> [String] -> [([String],Int)]
recordShapes shapes recordType roots=
  let (known,closed)=recordFields recordType
      required=nub (roots++map fst known)
  in [(sort fs,tid) | (fs,tid)<-M.toList shapes,all (`elem` fs) required,
                     not closed || sort fs==sort (map fst known)]

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
        tree<-plan (Just (exprType base)) fields
        pure e {exprNode=PlannedUpdate base' tree}
      PlannedUpdate _ _->throwError "typed layout: record update already planned"
      _->mapChildrenM go e
    -- A closed checked row has one nominal shape. Planning unrelated shapes
    -- creates impossible representation joins after type instantiation.
    -- An open row keeps all shapes extending its required fields.
    plan recordType assigns=do
      let roots=nub [root | (root:_,_)<-assigns]
          candidates=recordShapes shapes recordType roots
      when (null candidates) (throwError ("typed layout: no record shape has fields "++show roots))
      branches<-forM candidates $ \(fs,tid)->do
        fields<-forM fs $ \name->do
          value<-case [(p,x) | (p@(root:_),x)<-assigns,root==name] of
            []->pure KeepField
            [([_],x)]->ReplaceField <$> (clone x >>= go)
            deeper->NestedUpdate <$> plan (recordType >>= (\t->fieldType t [name])) [(drop 1 p,x) | (p,x)<-deeper]
          pure (name,value)
        pure (UpdateBranch tid fields)
      pure (UpdatePlan roots branches)
