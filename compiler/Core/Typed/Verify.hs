-- Check existing annotations and lexical identity. This never solves an
-- untyped body or guesses a representation from an optimized expression.
module Core.Typed.Verify (verifyFunction, instanceOf, sameType) where
import Core.Typed.Syntax
import Ownership.TypeShape (linShapeT)
import Type.Syntax (Type(..), Row(..), Scheme(..))
import Control.Monad (unless, foldM)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

sameType :: Type -> Type -> Bool
sameType a b = key a == key b
  where
    key t = case t of
      TAp x y -> TAp (key x) (key y)
      TFn x y -> TFn (key x) (key y)
      TTupT xs -> TTupT (map key xs)
      TRec r -> let (fs,tail')=fields r in TRec (foldr (uncurry RExt) tail' (M.toList (M.fromList fs)))
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

verifyFunction :: TypeContext -> Function -> Either String ()
verifyFunction (TypeContext linearTypes) f = do
  (env,used) <- introduce M.empty S.empty (functionParameters f)
  _ <- check env used (functionBody f)
  pure ()
  where
    bad reason = Left ("typed Core " ++ functionName f ++ ": " ++ reason)
    require reason ok = unless ok (bad reason)
    introduce env used bs = foldM step (env,used) bs
      where
        step (scope,seen) b = do
          require "binder ownership shape" (binderShape b == linShapeT linearTypes (binderType b))
          require "duplicate binder identity" (S.notMember (binderId b) seen)
          pure (M.insert (binderId b) b scope,S.insert (binderId b) seen)
    check env used e = do
      require "expression ownership shape" (exprShape e == linShapeT linearTypes (exprType e))
      node env used e
    node env used e = case exprNode e of
      Var (Local uid) -> do
        b <- maybe (bad "out-of-scope local identity") Right (M.lookup uid env)
        require "local reference type disagrees with its scheme" (instanceOf (binderScheme b) (exprType e))
        pure used
      Var (Global _ sc) -> do
        require "global reference type disagrees with its scheme" (instanceOf sc (exprType e))
        pure used
      IntValue _ -> fixed (TC "Int")
      StringValue _ -> fixed (TC "String")
      BoolValue _ -> fixed (TC "Bool")
      Apply fn arg -> do
        u <- check env used fn >>= \u -> check env u arg
        case exprType fn of
          TFn a r -> do
            require "application argument type" (sameType a (exprType arg))
            require "application result type" (sameType r (exprType e))
          _ -> bad "application head is not a function"
        pure u
      Lambda ps body -> do
        (scope,u) <- introduce env used ps
        u' <- check scope u body
        require "lambda type" (sameType (exprType e) (foldr (TFn . binderType) (exprType body) ps))
        pure u'
      Let b rhs body -> do
        u <- check env used rhs
        require "let right-hand side type" (instanceOf (binderScheme b) (exprType rhs))
        (scope,u') <- introduce env u [b]
        u'' <- check scope u' body
        require "let result type" (sameType (exprType e) (exprType body))
        pure u''
      If cond yes no -> do
        u <- check env used cond >>= \u -> check env u yes >>= \u -> check env u no
        require "condition is not Bool" (sameType (exprType cond) (TC "Bool"))
        require "conditional arm type" (all (sameType (exprType e) . exprType) [yes,no])
        pure u
      BoolTest _ arg -> do
        u <- check env used arg
        require "Bool test type" (sameType (exprType arg) (TC "Bool") && sameType (exprType e) (TC "Bool"))
        pure u
      Note body -> do
        u <- check env used body
        require "note changes type" (sameType (exprType body) (exprType e))
        pure u
      where
        fixed ty = require "literal type" (sameType ty (exprType e)) >> pure used
