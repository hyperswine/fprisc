{-# LANGUAGE FlexibleContexts #-}
-- Whole-program, type-directed instantiation before layout/erasure. A clone's
-- identity is its source entry plus its complete checked type, never a first
-- caller, allocation graph, fresh variable or traversal ordinal. This pass
-- also supports separately emitted Base units when all original entries are
-- retained. Their ordinary tagged ABI remains the boundary fallback.
module Core.Typed.Monomorphize (monomorphize, monomorphizeWithNotes, monomorphizeWithOrigins, monomorphizeKeepingEntriesWithOrigins, monomorphizeSelectedWithOrigins, typeKey, typeEmbeds) where

import Core.Typed.Syntax
import Core.Typed.Program
import Core.Typed.Instantiate
import Core.Typed.Walk (mapChildrenM)
import Core.Identity (Namespace(..))
import Type.Syntax
import qualified Type.Substitution as U
import Control.Monad.State.Strict
import Control.Monad (unless, when)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- Length-delimited, injective spelling, including nominal source identities.
-- Record field order is not a type distinction. No truncated hash can silently
-- alias two ABI identities. Open types deliberately have no concrete key.
typeKey :: Type -> Either String String
typeKey ty = case ty of
  TV _ -> Left "open type variable"
  TC n -> pure ("c" ++ atom n)
  TAp f x -> ("a" ++) <$> ((++) <$> typeKey f <*> typeKey x)
  TFn a b -> ("f" ++) <$> ((++) <$> typeKey a <*> typeKey b)
  TTupT ts -> (("p" ++ show (length ts) ++ "_") ++) . concat <$> mapM typeKey ts
  TLayout t -> ("l" ++) <$> typeKey t
  TRec row -> do
    fs <- fields row
    let ordered = sortOn fst fs
    unless (length fs == S.size (S.fromList (map fst fs))) (Left "duplicate record label")
    encoded <- mapM (\(n,t) -> (atom n ++) <$> typeKey t) ordered
    pure ("r" ++ show (length fs) ++ "_" ++ concat encoded)
  where
    atom s = show (length s) ++ "_" ++ s
    fields RNil = pure []
    fields (RV _) = Left "open record row"
    fields (RExt n t rest) = ((n,t) :) <$> fields rest

data Tree = Tree String [Tree] deriving Eq
tree ty = case ty of
  TV _ -> Tree "v" []
  TC n -> Tree ("c" ++ n) []
  TAp f x -> Tree "a" [tree f,tree x]
  TFn a b -> Tree "f" [tree a,tree b]
  TTupT xs -> Tree "p" (map tree xs)
  TLayout x -> Tree "l" [tree x]
  TRec r -> Tree "r" [Tree n [tree t] | (n,t) <- sortOn fst (fields r)]
  where
    fields (RExt n t rest) = (n,t):fields rest
    fields _ = []
embeds a@(Tree n xs) (Tree m ys) =
  (n == m && length xs == length ys && and (zipWith embeds xs ys)) || any (embeds a) ys

typeEmbeds :: Type -> Type -> Bool
typeEmbeds a b = embeds (tree a) (tree b)

data Work = Work
  { originals :: M.Map String Function,
    instances :: M.Map String Function,
    instanceSchemas :: M.Map String Scheme,
    instanceOrigins :: M.Map String String,
    wanted :: S.Set String,
    active :: [(String, Tree)],
    fallbacks :: S.Set (String, String) }

-- Retained entries include constructor layout authorities and references from
-- compatibility callers. They remain available at their original names;
-- concrete typed callers still use checked instantiations. Pinned generic
-- exports retain the original fallback as well as their internal instances;
-- runtime roots are never privately instantiated.
monomorphize :: S.Set String -> S.Set String -> Program -> Either String Program
monomorphize pinned retained = fmap fst . monomorphizeWithNotes pinned retained

monomorphizeWithNotes :: S.Set String -> S.Set String -> Program -> Either String (Program, [(String, String)])
monomorphizeWithNotes pinned retained input = do
  (result,notes,_)<-monomorphizeWithOrigins pinned retained input
  pure (result,notes)

monomorphizeWithOrigins :: S.Set String -> S.Set String -> Program -> Either String (Program, [(String,String)], M.Map String String)
monomorphizeWithOrigins=monomorphizeConfigured False (const (const True))

-- The consumer admits complete function types for which its representation
-- lowering has a benefit. Unselected uses keep the unchanged generic entry.
-- This policy is independent of the finite-instance termination proof and
-- target/compiler-cost admission; it is not an arbitrary cloning budget.
monomorphizeKeepingEntriesWithOrigins :: (Type -> Bool) -> S.Set String -> S.Set String -> Program -> Either String (Program, [(String,String)], M.Map String String)
monomorphizeKeepingEntriesWithOrigins admitted=monomorphizeConfigured True (const admitted)

monomorphizeSelectedWithOrigins :: (String -> Type -> Bool) -> S.Set String -> S.Set String -> Program -> Either String (Program, [(String,String)], M.Map String String)
monomorphizeSelectedWithOrigins=monomorphizeConfigured True

monomorphizeConfigured keepEntries admitted pinned retained input = do
  -- Program is opaque and already verified at construction. Do not re-verify
  -- the unchanged input graph. A changed output is checked before publication.
  let roots = if keepEntries then M.keysSet source else
        retained `S.union` pinned `S.union` M.keysSet (M.filterWithKey (\n f -> not (candidate n f)) source)
  (_, work) <- runStateT drain (Work M.empty M.empty M.empty M.empty roots [] S.empty)
  let output = originals work `M.union` instances work
      schemes = instanceSchemas work `M.union` programSchemas input
      arities = M.map (length . functionParameters) output `M.union` programArities input
  result <- if keepEntries && M.null (instances work) then pure input else
    programWithAssumptions (programNamespace input) types schemes arities output (programAssumptions input)
  pure (result, S.toAscList (fallbacks work),instanceOrigins work)
  where
    source = programFunctions input
    types = programTypes input
    fixed = S.fromList ["main", "machineInterrupt"]
    concrete t = U.variables t == mempty
    candidate n f = n `S.notMember` fixed && not (concrete (functionType f))
    bad = lift . Left . ("typed monomorphization: " ++)
    enqueue n w
      | M.member n (originals w)=w
      | otherwise=w {wanted=S.insert n (wanted w)}
    drain = do
      pending <- gets wanted
      case S.minView pending of
        Nothing -> pure ()
        Just (n, rest) -> do
          modify (\w -> w {wanted=rest})
          case M.lookup n source of
            Nothing -> pure ()
            Just fn -> do
              -- Reserve recursive originals before walking their references.
              modify (\w -> w {originals = M.insert n fn (originals w)})
              fn' <- if keepEntries && candidate n fn then pure fn else walkFunction fn
              modify (\w -> w {originals = M.insert n fn' (originals w)})
          drain
    walkFunction fn = do
      body <- walk (functionBody fn)
      pure fn {functionBody = body}
    walk e = case exprNode e of
      Var (Global n _) | Just fn <- M.lookup n source ->
        if candidate n fn && concrete (exprType e) && admitted n (exprType e)
          then do
            (name, sc) <- instantiate n fn (exprType e)
            pure e {exprNode = Var (Global name sc)}
          else do
            modify (enqueue n)
            pure e
      _ -> mapChildrenM walk e
    instantiate n fn ty = do
      key <- either bad pure (typeKey ty)
      let name = n ++ "$typespec$type$" ++ key
          sc = Forall [] [] ty
      found <- gets (M.member name . instances)
      if found then pure (name, sc) else do
        when (name `M.member` programSchemas input || name `M.member` source) $
          bad ("reserved instance identity collides with source: " ++ name)
        stack <- gets active
        let shape = tree ty
        if any (\(origin, prior) -> origin == n && embeds prior shape) stack
          then do
            -- The original generic entry has a real tagged ABI. Stop this
            -- expanding instance chain there; representation lowering inserts
            -- the required conversions. Unsupported boundaries still refuse.
            modify (\w -> (enqueue n w) {fallbacks = S.insert (n, "expanding recursive type specialization; using tagged generic entry") (fallbacks w)})
            case M.lookup n (programSchemas input) of
              Just originalSchema -> pure (n, originalSchema)
              Nothing -> bad ("missing generic entry schema for " ++ n)
          else do
            (sub, _) <- either bad pure (U.unifyTypes (U.variables (functionType fn)) 0 [(functionType fn, ty)])
            let Namespace ns = programNamespace input
                cloned = (instantiateFunction (Namespace (ns ++ "/typespec/" ++ name)) types sub fn)
                  {functionName = name}
            -- The reserved typed instance closes regular recursion without a
            -- depth or clone-count limit. Type evidence is checked again when
            -- the complete transformed Program is published.
            modify (\w -> w {instances = M.insert name cloned (instances w),
                              instanceSchemas = M.insert name sc (instanceSchemas w),
                              instanceOrigins = M.insert name n (instanceOrigins w),
                              active = (n, shape) : stack})
            cloned' <- walkFunction cloned
            modify (\w -> w {instances = M.insert name cloned' (instances w), active = stack})
            pure (name, sc)
