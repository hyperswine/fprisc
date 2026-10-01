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

module Inline (inlineSmall, inlineWith, vecPeek) where

import Control.Monad (foldM)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC (Core (..), Name, Prog)

-- | rounds, then the largest callee body (in Core nodes) worth inlining
inlineSmall :: Int -> Int -> Prog -> Prog
inlineSmall = inlineGo False (const False)

-- | The base profile's inliner: as inlineSmall, plus function-valued
-- arguments (below), and SAFEPOINT-PRESERVING: an inlined body starts with
-- the fuel tick the callee's entry had (`$fuel`, Codegen.hs).  A call is a
-- preemption point, so removing one without its tick lengthened the
-- longest path between safepoints -- the kernel's WCET ratchet saw 408
-- instructions against its ceiling of 200.  With the tick, every path is
-- exactly as long between safepoints as it was through the call; what goes
-- is the frame, the argument staging and the stack check.
inlineWith :: (Name -> Bool) -> Int -> Int -> Prog -> Prog
inlineWith = inlineGo True

-- | The same, with a predicate naming the globals outside this unit that
-- are FUNCTION VALUES (primitives, other units' functions of arity > 0).
-- An argument that names one -- or a function of this unit -- is
-- substituted into the body instead of let-bound: naming a function is
-- pure, and `f x` with f known is a direct (or inline) call where `$i.f x`
-- was a generic apply.  A zero-arity global is never substituted: it is
-- evaluated where it is named, so it is let-bound like any argument.
inlineGo :: Bool -> (Name -> Bool) -> Int -> Int -> Prog -> Prog
inlineGo tick pureOutside rounds limit prog0 = evalState (foldM (const . step') prog0 [1 .. rounds]) 0
  where
    -- each round: inline at the sites, then propagate function-value
    -- aliases (clause desugaring rebinds a parameter under its source
    -- name, `f = a1`, so a substituted parameter reappears as one)
    step' prog = M.mapWithKey (\_ (ps, b) -> (ps, propagate prog (S.fromList ps) b)) <$> step prog
    funValue prog g = case M.lookup g prog of
      Just (ps, _) -> not (null ps)
      Nothing -> pureOutside g
    propagate prog = propagateWith (funValue prog)
    step prog = M.traverseWithKey (\n (ps, b) -> (,) ps <$> site prog n (S.fromList ps) b) prog
    candidate prog n = case M.lookup n prog of
      Just (ps, body)
        | not (null ps),
          size body <= limit || (straight body && size body <= 4 * limit),
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
                    -- a function-valued argument (a global the caller does
                    -- not shadow) replaces its parameter outright
                    subst = [(p, g) | (p, CVar g) <- zip ps args', g `S.notMember` env, funValue prog g]
                    substd = S.fromList (map fst subst)
                    body' = rename (M.union (M.fromList subst) (M.fromList [(p, fresh p) | p <- ps])) fresh body
                    -- the callee entry's safepoint, after its arguments
                    entry = if tick then CLet (fresh "$tick") (CApp (CVar "$fuel") (CInt 0)) body' else body'
                pure (foldr (\(p, a) rest -> CLet (fresh p) a rest) entry [(p, a) | (p, a) <- zip ps args', p `S.notMember` substd])
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

-- `x = g` where g is a function value that nothing in scope shadows:
-- replace x by g.  Naming a function is pure, so this changes no
-- evaluation; it turns `x a` into a known call.
propagateWith :: (Name -> Bool) -> S.Set Name -> Core -> Core
propagateWith funValue = go
  where
    go env = \case
      CLet x (CVar g) b
        | g `S.notMember` env, funValue g, g `S.notMember` bindersOf b ->
            go env (subst x g b)
      CLet x a b -> CLet x (go env a) (go (S.insert x env) b)
      CApp a b -> CApp (go env a) (go env b)
      CLam ps b -> CLam ps (go (S.union (S.fromList ps) env) b)
      CIf c t f -> CIf (go env c) (go env t) (go env f)
      CMk t v fs -> CMk t v (map (go env) fs)
      CTagEq t v x -> CTagEq t v (go env x)
      CProj i x -> CProj i (go env x)
      e -> e
    -- x := g, stopping where x is rebound
    subst x g = \case
      CVar n | n == x -> CVar g
      CLet y a b -> CLet y (subst x g a) (if y == x then b else subst x g b)
      CLam ps b -> CLam ps (if x `elem` ps then b else subst x g b)
      CApp a b -> CApp (subst x g a) (subst x g b)
      CIf c t f -> CIf (subst x g c) (subst x g t) (subst x g f)
      CMk t v fs -> CMk t v (map (subst x g) fs)
      CTagEq t v e -> CTagEq t v (subst x g e)
      CProj i e -> CProj i (subst x g e)
      e -> e

bindersOf :: Core -> S.Set Name
bindersOf = \case
  CLet x a b -> S.insert x (bindersOf a `S.union` bindersOf b)
  CLam ps b -> S.fromList ps `S.union` bindersOf b
  CApp a b -> bindersOf a `S.union` bindersOf b
  CIf c t f -> S.unions [bindersOf c, bindersOf t, bindersOf f]
  CMk _ _ fs -> S.unions (map bindersOf fs)
  CTagEq _ _ x -> bindersOf x
  CProj _ x -> bindersOf x
  _ -> S.empty

-- A STRAIGHT body: no branch, and nothing applied but lowered primitives
-- (`$arc.*`).  Such a body is a fixed run of machine operations, so copying
-- it into a site can only remove a call -- there is no callee in it to
-- duplicate.  It gets a larger allowance than `limit` because ARC's
-- let-normal form inflates it: a Layout's one-line setter
-- (FPRISC.expandLayout) lowers to ~29 nodes, just past 24, and stayed a call
-- in every ARC-managed program until this rule.
straight :: Core -> Bool
straight = \case
  CIf {} -> False
  CLam {} -> False
  e@(CApp _ _) -> case spineOf e of
    (CVar f, args) -> take 5 f == "$arc." && all straight args
    _ -> False
  CLet _ a b -> straight a && straight b
  CMk _ _ fs -> all straight fs
  CTagEq _ _ x -> straight x
  CProj _ x -> straight x
  _ -> True

spineOf :: Core -> (Core, [Core])
spineOf = go []
  where
    go acc (CApp f a) = go (a : acc) f
    go acc f = (f, acc)

-- Core nodes, not counting what the generator emits nothing for: an alias
-- `x = y` (normalization substitutes a local; a slot is shared) -- base
-- clause desugaring adds one per parameter, which would otherwise price a
-- three-line helper out of the limit
size :: Core -> Int
size = \case
  CLet _ (CVar _) b -> size b
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

-- ---------------------------------------------------------------------
-- vecPeek: a vector read whose pair is taken apart at once allocates
-- nothing.  `(x, v2) = Vec.at i v` desugars to
--
--   let t = Vec.at i v in if tag(t) == Tup2 then let x = t.0; v2 = t.1 in ...
--
-- and the runtime builds a 48-byte (value, handle) pair per read -- in
-- every vector loop, and for good in a long-lived actor's pool.  The
-- handle returned is always the one passed in (vec.c), so the pair is
-- redundant: this rewrites the site to `let t = $vec.at i v` -- the value
-- alone -- with t.0 read as t and t.1 as v.  Vec.get and Vec.len likewise.
--
-- Run on the base pipeline after the linearity check (which sees the
-- source), so aliasing the handle breaks no ownership rule; not under
-- --arc, whose ownership lowering would count the alias.  A site is left
-- alone unless the handle is a variable, the pair is used only through
-- its projections, and neither name is rebound before those uses.
vecPeek :: Prog -> Prog
vecPeek = M.map (\(ps, b) -> (ps, peek b))
  where
    peek = \case
      CLet t rhs body
        | Just (op, args, v) <- peekable rhs,
          Just body' <- retarget t v body ->
            CLet t (foldl CApp (CVar op) (map peek args ++ [CVar v])) (peek body')
      CLet x a b -> CLet x (peek a) (peek b)
      CApp a b -> CApp (peek a) (peek b)
      CLam ps b -> CLam ps (peek b)
      CIf c a b -> CIf (peek c) (peek a) (peek b)
      CMk t v fs -> CMk t v (map peek fs)
      CTagEq t v e -> CTagEq t v (peek e)
      CProj i e -> CProj i (peek e)
      e -> e
    peekable = \case
      CApp (CApp (CVar "Vec.at") i) (CVar v) -> Just ("$vec.at", [i], v)
      CApp (CApp (CVar "Vec.get") i) (CVar v) -> Just ("$vec.get", [i], v)
      CApp (CVar "Vec.len") (CVar v) -> Just ("$vec.len", [], v)
      _ -> Nothing
    -- the pattern's shape check is on the pair (Tup2 = tid 4): drop it,
    -- then read t.0 as t and t.1 as v; Nothing when that is not sound
    retarget t v = \case
      CIf (CTagEq 4 0 (CVar t')) yes _ | t' == t -> subst t v yes
      _ -> Nothing
    subst t v = go
      where
        go = \case
          CProj 0 (CVar x) | x == t -> Just (CVar t)
          CProj 1 (CVar x) | x == t -> Just (CVar v)
          CVar x | x == t -> Nothing -- the pair itself is used
          e@(CVar _) -> Just e
          CLet x a b
            | x == t -> (\a' -> CLet x a' b) <$> go a -- t rebound: b sees the new one
            | x == v, mentions t b -> Nothing      -- v rebound before a use of t.1
            | otherwise -> CLet x <$> go a <*> go b
          CLam ps b
            | t `elem` ps -> Just (CLam ps b)
            | v `elem` ps, mentions t b -> Nothing
            | otherwise -> CLam ps <$> go b
          CApp a b -> CApp <$> go a <*> go b
          CIf c a b -> CIf <$> go c <*> go a <*> go b
          CMk tg vr fs -> CMk tg vr <$> mapM go fs
          CTagEq tg vr e -> CTagEq tg vr <$> go e
          CProj i e -> CProj i <$> go e
          e -> Just e
    mentions n = \case
      CVar x -> x == n
      CLet _ a b -> mentions n a || mentions n b
      CApp a b -> mentions n a || mentions n b
      CLam _ b -> mentions n b
      CIf c a b -> mentions n c || mentions n a || mentions n b
      CMk _ _ fs -> any (mentions n) fs
      CTagEq _ _ e -> mentions n e
      CProj _ e -> mentions n e
      _ -> False
