-- Evidence of source checking, before surface elaboration is lowered to Core.
-- This is not a substitute for typed Core: generated Core still needs its own
-- typed constructors and evidence-preserving transformations.
module Infer.Evidence
  ( BindingRole(..), Reference(..), BinderFact(..), ExprFact(..), Evidence,
    evidenceNamespace, evidenceBinders, evidenceExpressions, evidenceRoots,
    Builder, emptyBuilder, currentExpression, bindNames, refineName, beginExpr, endExpr,
    mapBuilderTypesM, sealEvidence ) where
import Core.Identity
import Frontend.Syntax (SExpr)
import Type.Syntax (Type, Scheme(..))
import Ownership.Shape (LShape)
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import Control.Monad (unless)

data BindingRole = ClauseParameter | LambdaParameter | LocalBinding
                 | PatternBinding | GuardBinding deriving (Eq, Show)
data Reference = LocalReference String BinderId | GlobalReference String Scheme
               | MissingReference String deriving (Show)
data BinderFact = BinderFact
  { binderIdentity :: BinderId, binderSpelling :: String,
    binderOwner :: Maybe String, binderRole :: BindingRole,
    binderScheme :: Scheme, binderTypeShape :: LShape } deriving (Show)
data ExprFact = ExprFact
  { expressionIdentity :: ExprId, expressionOwner :: Maybe String,
    expressionOffset :: Maybe Int, expressionSource :: SExpr,
    expressionType :: Type, expressionTypeShape :: LShape,
    expressionReference :: Maybe Reference,
    expressionScope :: M.Map String BinderId,
    expressionChildren :: [ExprId] } deriving (Show)
-- Ordinary accessors, not exported record fields: clients cannot record-update
-- a sealed result to mix evidence from unrelated namespaces/checking runs.
data Evidence = Evidence Namespace [BinderFact] [ExprFact] [ExprId]
evidenceNamespace :: Evidence -> Namespace
evidenceNamespace (Evidence ns _ _ _) = ns
evidenceBinders :: Evidence -> [BinderFact]
evidenceBinders (Evidence _ bs _ _) = bs
evidenceExpressions :: Evidence -> [ExprFact]
evidenceExpressions (Evidence _ _ es _) = es
evidenceRoots :: Evidence -> [ExprId]
evidenceRoots (Evidence _ _ _ roots) = roots

-- Force context projections when entering a node, so a pending expression
-- does not retain an entire historical inference state through a lazy selector.
data PendingBinder = PendingBinder !BinderId String !(Maybe String) !BindingRole !Scheme
data PendingExpr = PendingExpr !ExprId !(Maybe String) !(Maybe Int) !SExpr
  !(M.Map String BinderId) !(Maybe Reference) !(Maybe Type) [ExprId]
data Builder = Builder Namespace Int Int (IM.IntMap PendingBinder)
  (IM.IntMap PendingExpr) [ExprId] [ExprId] [String]

emptyBuilder :: Namespace -> Builder
emptyBuilder ns = Builder ns 0 0 IM.empty IM.empty [] [] []

currentExpression :: Builder -> Maybe ExprId
currentExpression (Builder _ _ _ _ _ stack _ _) = case stack of
  uid:_ -> Just uid
  [] -> Nothing

bindNames :: BindingRole -> Maybe String -> M.Map String Scheme -> Builder
          -> (M.Map String BinderId, Builder)
bindNames role owner env builder = M.foldlWithKey' step (M.empty,builder) env
  where
    -- The explicit argument below avoids giving this supply any connection to
    -- freshT/freshR. Binding names are presentation, identities are keys.
    step (ids, Builder ns next ne bs es stack roots issues) name sc =
      let uid = BinderId ns next
      in (M.insert name uid ids, Builder ns (next+1) ne
            (IM.insert next (PendingBinder uid name owner role sc) bs) es stack roots issues)

refineName :: BinderId -> Scheme -> Builder -> Builder
refineName (BinderId wanted key) sc (Builder ns nb ne bs es stack roots issues) =
  case IM.lookup key bs of
    Just (PendingBinder uid n o r _) | wanted == ns ->
      Builder ns nb ne (IM.insert key (PendingBinder uid n o r sc) bs) es stack roots issues
    _ -> Builder ns nb ne bs es stack roots ("refining an absent binder":issues)

beginExpr :: Maybe String -> Maybe Int -> SExpr -> M.Map String BinderId
          -> Maybe Reference -> Builder -> (ExprId,Builder)
beginExpr owner off source scope ref (Builder ns nb next bs es stack roots issues) =
  let uid = ExprId ns next
      node = PendingExpr uid owner off source scope ref Nothing []
      addChild (PendingExpr i o p s env r t kids) = PendingExpr i o p s env r t (uid:kids)
      es' = case stack of ExprId _ parent:_ -> IM.adjust addChild parent es; [] -> es
      roots' = case stack of [] -> uid:roots; _ -> roots
  in (uid,Builder ns nb (next+1) bs (IM.insert next node es') (uid:stack) roots' issues)

endExpr :: ExprId -> Type -> Builder -> Builder
endExpr uid@(ExprId wanted key) ty (Builder ns nb ne bs es stack roots issues) =
  case (stack, IM.lookup key es) of
    (top:rest,Just (PendingExpr i o p s env r Nothing kids)) | top==uid && wanted==ns ->
      Builder ns nb ne bs (IM.insert key (PendingExpr i o p s env r (Just ty) kids) es) rest roots issues
    _ -> Builder ns nb ne bs es stack roots ("unbalanced expression evidence":issues)

mapBuilderTypesM :: Monad m => (Type -> m Type) -> (Scheme -> m Scheme) -> Builder -> m Builder
mapBuilderTypesM solve solveScheme (Builder ns nb ne bs es stack roots issues) = do
  bs' <- traverse binder bs
  es' <- traverse expr es
  pure (Builder ns nb ne bs' es' stack roots issues)
  where
    binder (PendingBinder uid n o r sc) = PendingBinder uid n o r <$> solveScheme sc
    reference (GlobalReference n sc) = GlobalReference n <$> solveScheme sc
    reference r = pure r
    expr (PendingExpr i o p s env r t kids) =
      PendingExpr i o p s env <$> traverse reference r <*> traverse solve t <*> pure kids

sealEvidence :: (Type -> LShape) -> Builder -> Either String Evidence
sealEvidence shape (Builder ns _ _ bs es stack roots issues) = do
  unless (null stack && null issues) (Left ("unfinished inference evidence: " ++ show issues))
  binders <- traverse binder bs
  expressions <- traverse expr es
  pure (Evidence ns (IM.elems binders) (IM.elems expressions) (reverse roots))
  where
    binder (PendingBinder uid name owner role sc@(Forall _ _ ty)) =
      pure (BinderFact uid name owner role sc (shape ty))
    expr (PendingExpr uid owner off source scope ref typ kids) = do
      ty <- maybe (Left "expression is missing its checked type") Right typ
      case ref of
        Just (MissingReference name) -> Left ("unresolved checked reference " ++ name)
        Just (LocalReference name bid@(BinderId bns key)) -> do
          unless (bns==ns && M.lookup name scope==Just bid)
            (Left ("out-of-scope checked reference " ++ name))
          case IM.lookup key bs of
            Just (PendingBinder actual spelling home _ _) ->
              unless (actual==bid && spelling==name && home==owner)
                (Left ("checked binder identity mismatch for " ++ name))
            Nothing -> Left ("absent checked binder " ++ name)
        _ -> pure ()
      mapM_ child kids
      pure (ExprFact uid owner off source ty (shape ty) ref scope (reverse kids))
    child (ExprId childNs key) = unless (childNs==ns && IM.member key es)
      (Left "absent checked child expression")
