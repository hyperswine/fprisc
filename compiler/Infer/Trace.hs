-- Capture the types that inference actually proves; never infer a rewritten
-- body again to reconstruct them. Disabled for compatibility-only API calls.
module Infer.Trace (withExprEvidence, extendScoped, refineScoped, finishEvidence) where
import Source.Span (SourceOffset(..))
import Infer.State
import qualified Infer.Evidence as E
import Core.Syntax (Name)
import Frontend.Syntax (SExpr(..))
import Type.Syntax (Type, Scheme)
import Ownership.Shape (LShape)
import Control.Monad.State.Strict
import Control.DeepSeq (force)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

withExprEvidence :: ICtx -> SExpr -> I (Type,SExpr) -> I (Type,SExpr)
withExprEvidence ctx source action = do
  token <- open
  result@(ty,rewritten) <- action
  case token of
    Nothing -> pure ()
    Just uid -> modify (\s -> s {iEvidenceBuilder=fmap (E.endExpr uid ty rewritten) (iEvidenceBuilder s)})
  pure result
  where
    open = do
      st <- get
      case iEvidenceBuilder st of
        Nothing -> pure Nothing
        Just builder -> do
          let off = case source of SMark n _ -> Just (SourceOffset n); _ -> iHere st
              ref = case source of
                SVar name -> Just $ case M.lookup name (icLocalIds ctx) of
                  Just uid -> E.LocalReference name uid
                  Nothing | name `S.member` icBound ctx -> E.MissingReference name
                  Nothing -> case M.lookup name (icEnv ctx) `orElse` M.lookup name (icCons ctx) of
                    Just sc -> case M.lookup name (icRecursiveSignatures ctx) of
                      Just published -> E.RecursiveReference name sc published
                      Nothing -> E.GlobalReference name sc
                    Nothing -> E.MissingReference name
                _ -> Nothing
              (uid,builder') = E.beginExpr (icOwner ctx) off source (icLocalIds ctx) ref builder
          put st {iEvidenceBuilder=Just builder'}
          pure (Just uid)
    orElse (Just x) _ = Just x
    orElse Nothing b = b

extendScoped :: E.BindingRole -> TEnv -> ICtx -> I ICtx
extendScoped role env ctx = do
  st <- get
  case iEvidenceBuilder st of
    Nothing -> pure (extend env ctx)
    Just builder -> do
      let (ids,builder') = E.bindNames role (icOwner ctx) env builder
      put st {iEvidenceBuilder=Just builder'}
      pure ((extend env ctx) {icLocalIds=M.union ids (icLocalIds ctx)})

-- A recursive local's monomorphic placeholder becomes its generalized scheme;
-- it is still the same binding, not a new shadow with the same spelling.
refineScoped :: Name -> Scheme -> ICtx -> I ICtx
refineScoped name sc ctx = do
  case M.lookup name (icLocalIds ctx) of
    Nothing -> pure () -- compatibility calls do not allocate term identities
    Just uid -> modify (\s -> s {iEvidenceBuilder=fmap (E.refineName uid sc) (iEvidenceBuilder s)})
  pure (extend (M.singleton name sc) ctx)

finishEvidence :: (Type -> I Type) -> (Scheme -> I Scheme) -> (Type -> LShape) -> I (Either String (Maybe E.Evidence))
finishEvidence solve solveScheme shape = do
  mb <- gets iEvidenceBuilder
  case mb of
    Nothing -> pure (Right Nothing)
    Just builder -> do
      solved <- E.mapBuilderTypesM detachedType solveScheme builder
      pure (Just <$> E.sealEvidence shape solved)

  where
    detachedType t = do
      checked <- solve t
      let detached = force checked
      detached `seq` pure detached
