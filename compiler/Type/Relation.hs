-- Relations over checked types: instantiation, row equality and field paths.
-- Shared by source inference and Core lint; no AST or inference-state dependency.
module Type.Relation (sameType, instanceOf, fieldType) where
import Type.Syntax
import Data.List (sortOn)
import Control.Monad (foldM)
import qualified Data.Map.Strict as M

sameType :: Type -> Type -> Bool
sameType a b = key a == key b
  where
    key t = case t of
      TAp x y -> TAp (key x) (key y)
      TFn x y -> TFn (key x) (key y)
      TTupT xs -> TTupT (map key xs)
      TLayout x -> TLayout (key x)
      TRec r -> let (fs,tail')=fields r in TRec (foldr (uncurry RExt) tail' (sortOn fst fs))
      _ -> t
    fields (RExt n t rest) = let (fs,tail')=fields rest in ((n,key t):fs,tail')
    fields r = ([],r)

-- Match quantified variables, leaving free solver variables rigid. Row fields
-- are unordered; a quantified row tail receives exactly the residual row.
instanceOf :: Scheme -> Type -> Bool
instanceOf (Forall qs rs template) actual = case go M.empty M.empty template actual of
  Just _ -> True
  Nothing -> False
  where
    go ts rows (TV v) t | v `elem` qs = do
      ts' <- bind sameType v t ts
      pure (ts',rows)
    go ts rows (TAp f a) (TAp g b) = do
      (ts',rows') <- go ts rows f g
      go ts' rows' a b
    go ts rows (TFn a b) (TFn x y) = do
      (ts',rows') <- go ts rows a x
      go ts' rows' b y
    go ts rows (TTupT xs) (TTupT ys) | length xs == length ys =
      foldM (\(t,r) (a,b) -> go t r a b) (ts,rows) (zip xs ys)
    go ts rows (TRec a) (TRec b) = row ts rows a b
    go ts rows (TLayout a) (TLayout b) = go ts rows a b
    go ts rows a b | sameType a b = Just (ts,rows)
    go _ _ _ _ = Nothing
    row ts rows a b = do
      let (af,at)=fields a; (bf,bt)=fields b
      (ts',rows') <- foldM (\(t,r) (n,ty) -> M.lookup n bf >>= go t r ty) (ts,rows) (M.toList af)
      let extra = bf `M.difference` af
          residual = foldr (uncurry RExt) bt (M.toList extra)
      case at of
        RV v | v `elem` rs -> do
          r <- bind (\x y -> sameType (TRec x) (TRec y)) v residual rows'
          pure (ts',r)
        _ | M.null extra && at == bt -> Just (ts',rows')
        _ -> Nothing
    fields (RExt n t rest) = let (fs,tail')=fields rest in (M.insert n t fs,tail')
    fields r = (M.empty,r)
    bind eq v t env = case M.lookup v env of
      Nothing -> Just (M.insert v t env)
      Just old | eq old t -> Just env
      _ -> Nothing

fieldType :: Type -> [String] -> Maybe Type
fieldType t [] = Just t
fieldType (TRec row) (n:rest) = find row >>= (\t -> fieldType t rest)
  where
    find (RExt name ty more) | name==n = Just ty
                            | otherwise = find more
    find _ = Nothing
fieldType _ _ = Nothing
