{-# LANGUAGE LambdaCase #-}

-- Inline small non-recursive supercombinators at saturated call sites.
--
-- The builtin code generator is deliberately naive: every call stages
-- its arguments through frame slots and every callee opens a frame of
-- its own, so a one-line helper such as `rd a o = Mem.readWord
-- (Addr.add a o)` costs a call, a prologue, a dozen slot moves and an
-- epilogue for two instructions of work.  Inlining the helper's body
-- at the site turns that into two instructions plus the let-bindings
-- of its arguments, which the peephole then folds away.
--
-- Semantics are preserved exactly: the arguments are let-bound in call
-- order before the body (so each is evaluated once, left to right, as
-- a call would), every binder of the callee is renamed fresh, and a
-- site is skipped when a caller local shadows a global the callee
-- refers to.  ARC instrumentation was already lowered into the bodies,
-- so an inlined body retains and releases exactly what the callee did.
-- Recursive functions are never inlined; a bounded number of rounds
-- keeps mutual recursion and growth finite.  Definitions stay in the
-- program (exports, constructor stubs and function values still need
-- their symbols); only the sites change.

module Inline (inlineSmall) where

import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC (Core (..), Name, Prog)

-- | rounds, then the largest callee body (in Core nodes) worth inlining
inlineSmall :: Int -> Int -> Prog -> Prog
inlineSmall rounds limit prog0 = evalState (foldM (const . step) prog0 [1 .. rounds]) 0
  where
    step prog = M.traverseWithKey (\n (ps, b) -> (,) ps <$> site prog n (S.fromList ps) b) prog
    candidate prog n = case M.lookup n prog of
      Just (ps, body)
        | not (null ps),
          size body <= limit,
          noLam body,
          n `S.notMember` globals ps body ->
            Just (ps, body)
      _ -> Nothing
    site :: Prog -> Name -> S.Set Name -> Core -> State Int Core
    site prog self locals = go locals
      where
        go env e = case spineOf e of
          (CVar f, args@(_ : _))
            | f /= self,
              f `S.notMember` env,
              Just (ps, body) <- candidate prog f,
              length args == length ps,
              S.null (globals ps body `S.intersection` env) -> do
                args' <- mapM (go env) args
                k <- get
                put (k + 1)
                let fresh v = "$i" ++ show k ++ "." ++ v
                    body' = rename (M.fromList [(p, fresh p) | p <- ps]) fresh body
                pure (foldr (\(p, a) rest -> CLet (fresh p) a rest) body' (zip ps args'))
          _ -> descend env e
        descend env = \case
          CApp a b -> CApp <$> go env a <*> go env b
          CLam ps b -> CLam ps <$> go (S.union (S.fromList ps) env) b
          CLet x a b -> CLet x <$> go env a <*> go (S.insert x env) b
          CIf c t f -> CIf <$> go env c <*> go env t <*> go env f
          CMk t v fs -> CMk t v <$> mapM (go env) fs
          CTagEq t v x -> CTagEq t v <$> go env x
          CProj i x -> CProj i <$> go env x
          e -> pure e

spineOf :: Core -> (Core, [Core])
spineOf = go []
  where
    go acc (CApp f a) = go (a : acc) f
    go acc f = (f, acc)

size :: Core -> Int
size = \case
  CApp a b -> 1 + size a + size b
  CLam _ b -> 1 + size b
  CLet _ a b -> 1 + size a + size b
  CIf c t f -> 1 + size c + size t + size f
  CMk _ _ fs -> 1 + sum (map size fs)
  CTagEq _ _ x -> 1 + size x
  CProj _ x -> 1 + size x
  _ -> 1

noLam :: Core -> Bool
noLam = \case
  CLam {} -> False
  CApp a b -> noLam a && noLam b
  CLet _ a b -> noLam a && noLam b
  CIf c t f -> noLam c && noLam t && noLam f
  CMk _ _ fs -> all noLam fs
  CTagEq _ _ x -> noLam x
  CProj _ x -> noLam x
  _ -> True

-- the names a body refers to that are not its own binders
globals :: [Name] -> Core -> S.Set Name
globals ps = go (S.fromList ps)
  where
    go bound = \case
      CVar n -> if n `S.member` bound then S.empty else S.singleton n
      CApp a b -> go bound a `S.union` go bound b
      CLam xs b -> go (S.union (S.fromList xs) bound) b
      CLet x a b -> go bound a `S.union` go (S.insert x bound) b
      CIf c t f -> S.unions [go bound c, go bound t, go bound f]
      CMk _ _ fs -> S.unions (map (go bound) fs)
      CTagEq _ _ x -> go bound x
      CProj _ x -> go bound x
      _ -> S.empty

-- rename every binder (params via the initial map, lets as met) so an
-- inlined body can never capture or be captured
rename :: M.Map Name Name -> (Name -> Name) -> Core -> Core
rename m fresh = \case
  CVar n -> CVar (M.findWithDefault n n m)
  CApp a b -> CApp (rename m fresh a) (rename m fresh b)
  CLam ps b -> CLam (map fresh ps) (rename (M.union (M.fromList [(p, fresh p) | p <- ps]) m) fresh b)
  CLet x a b -> CLet (fresh x) (rename m fresh a) (rename (M.insert x (fresh x) m) fresh b)
  CIf c t f -> CIf (rename m fresh c) (rename m fresh t) (rename m fresh f)
  CMk t v fs -> CMk t v (map (rename m fresh) fs)
  CTagEq t v x -> CTagEq t v (rename m fresh x)
  CProj i x -> CProj i (rename m fresh x)
  e -> e
