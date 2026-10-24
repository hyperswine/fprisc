{-# LANGUAGE LambdaCase #-}
module Core.Opt.Normalize (normArc, normIn, indexedMemory) where
import Core.Syntax
import Core.Utils (spineOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Maybe (fromMaybe)
import Data.List (isPrefixOf)

normArc :: Core -> Core
normArc = normIn S.empty

-- `ps`: the function's parameters.  A variable is LOCAL when it is a
-- parameter or bound inside the body; only a local is a pure value.  A
-- global of arity 0 is evaluated where it is named (base code: a CAF
-- that prints), so an alias of one is never substituted -- that would
-- drop the evaluation, or repeat it at every use.
normIn :: S.Set String -> Core -> Core
normIn ps body0 = go M.empty body0
  where
    locals = S.union ps (S.fromList (binders body0))
    -- `env`: the substitutions pending (an Int literal or an alias for a
    -- let-bound name), applied as the walk reaches each variable.  ONE
    -- pass: substituting with substE and re-walking the result cost a
    -- whole traversal per let, and a let per element made an 8000-
    -- element list literal take 86 s to compile (quadratic); the free-
    -- variable tests use `occurs`, which stops at the first hit, where
    -- `freeVars` built the whole list and filtered it by the parameter
    -- list at every lambda (a 400-parameter function took 67 s: cubic).
    go env e = case e of
      CLet x a b -> letChain env (counts e) [] x a b -- rw is applied inside, per let
      _ -> rw (descend env e)
    descend env = \case
      CVar n -> fromMaybe (CVar n) (M.lookup n env)
      CApp a b -> CApp (go env a) (go env b)
      CLam qs b -> CLam qs (go (foldr M.delete env qs) b)
      CLet x a b -> letChain env (counts (CLet x a b)) [] x a b
      CIf c t e -> CIf (go env c) (go env t) (go env e)
      CMk t v fs -> CMk t v (map (go env) fs)
      CTagEq t v x -> CTagEq t v (go env x)
      CProj i x -> CProj i (go env x)
      e -> e
    -- A chain of lets (every block is one) is walked top-down ONCE.
    -- Each let's right-hand side is normalized under the substitutions
    -- so far; the let then vanishes (an Int, or an alias of a local),
    -- or stays as a PENDING binding.  A pending binding used only by
    -- the next let's right-hand side sinks into it (the rule
    -- `let x = a in let y = b in r -> let y = (let x = a in b) in r`),
    -- which the nest of earlier sinks may repeat: `absorb` pops the
    -- pending bindings from the innermost while each sinks.  Applying
    -- the sink rule per let, bottom-up, re-descended the nest the inner
    -- sinks had built at every level: cubic, 114 s for a 4000-statement
    -- block.  "Used later" is answered from `left`, the raw occurrence
    -- counts of every variable in what remains of the chain, kept as
    -- the walk passes each right-hand side (a scan of the remainder per
    -- let was still quadratic); an alias that vanishes hands its
    -- remaining uses to the variable it named.
    letChain env left pend x a b =
      let a' = go env a
          here = counts a
          left1 = M.differenceWith (\l h -> Just (l - h)) left here
       in case a' of
            -- let x = <int> in b  ->  b[x := <int>]
            CInt _ -> chainOn (M.insert x a' env) left1 pend b
            -- let x = y in b  ->  b[x := y]: a local alias, when nothing
            -- in the body rebinds y (so the substitution is not captured)
            CVar y | S.member y locals, not (rebinds y b) ->
              chainOn (M.insert x a' env) (M.insertWith (+) y (M.findWithDefault 0 x left1) left1) pend b
            _ -> let (n, pend') = absorb env left1 here pend a' in chainOn (M.delete x env) left1 ((x, n) : pend') b
    chainOn env left pend b = case b of
      CLet y c rest -> letChain env left pend y c rest
      _ -> foldl (\acc (x, a') -> rw (CLet x a' acc)) (go env b) pend
    absorb env left here pend n = case pend of
      (y, c) : more | usedHere env here y, M.findWithDefault 0 y left == 0 -> absorb env left here more (rw (CLet y c n))
      _ -> (n, pend)
    -- is y used in the right-hand side just passed, by name or through
    -- an alias that vanished into it?
    usedHere env here y = M.member y here || any (\v -> M.lookup v env == Just (CVar y)) (M.keys here)
    -- raw occurrence counts of the variables in e (accumulator form:
    -- `concatMap` would copy the deep last child at every level)
    counts e = M.fromListWith (+) [(v, 1 :: Int) | v <- varsInto e []]
    varsInto e acc = case e of
      CVar n -> n : acc
      CApp a b -> varsInto a (varsInto b acc)
      CLam _ b -> varsInto b acc
      CLet _ a b -> varsInto a (varsInto b acc)
      CIf c t f -> varsInto c (varsInto t (varsInto f acc))
      CMk _ _ fs -> foldr varsInto acc fs
      CTagEq _ _ x -> varsInto x acc
      CProj _ x -> varsInto x acc
      _ -> acc
    -- accumulator form, like varsInto (the `++` form copied the deep
    -- part of a nest at every level)
    binders e = bindersInto e []
    bindersInto e acc = case e of
      CLet x a b -> x : bindersInto a (bindersInto b acc)
      CLam qs b -> qs ++ bindersInto b acc
      CApp a b -> bindersInto a (bindersInto b acc)
      CIf c t f -> bindersInto c (bindersInto t (bindersInto f acc))
      CMk _ _ fs -> foldr bindersInto acc fs
      CTagEq _ _ x -> bindersInto x acc
      CProj _ x -> bindersInto x acc
      _ -> acc
    rebinds y = \case
      CLet x a b -> x == y || rebinds y a || rebinds y b
      CLam qs b -> y `elem` qs || rebinds y b
      CApp a b -> rebinds y a || rebinds y b
      CIf c t e -> rebinds y c || rebinds y t || rebinds y e
      CMk _ _ fs -> any (rebinds y) fs
      CTagEq _ _ x -> rebinds y x
      CProj _ x -> rebinds y x
      _ -> False
    rw = \case
      CLet x a (CVar y) | x == y -> a
      CLet x a (CIf (CTagEq t v (CVar y)) th el)
        | x == y, not (occurs x th), not (occurs x el) -> rw (CIf (CTagEq t v a) th el)
      CLet x a (CIf (CVar y) th el)
        | x == y, not (occurs x th), not (occurs x el) -> rw (CIf a th el)
      -- (a binding used only by the next binding sinks into it: the
      -- same evaluation order, a, then b, then the rest -- done by
      -- letChain over the whole chain, not here)
      CIf (CLet x a c) th el
        | not (occurs x th), not (occurs x el) -> rw (CLet x a (rw (CIf c th el)))
      e -> e

-- Manual Builtin only: a private address used for one volatile access and
-- immediately released has no observable identity. Keep the base/offset
-- evaluation order, access checks and result representation, but avoid the
-- temporary box. No alias, intervening effect, shadowed primitive, retained
-- address or effectful write argument is accepted by this deliberately small
-- pattern. The release still yields Unit when its result is used.
indexedMemory :: S.Set String -> S.Set String -> Core -> Core
indexedMemory globals initial body = go initial body
  where
    -- One occurrence ledger for the function, not a scan of the remaining
    -- let chain per candidate. Reused/shadowed names conservatively decline.
    uses = M.fromListWith (+) [(n, 1 :: Int) | n <- vars body []]
    vars e acc = case e of
      CVar n -> n : acc
      CApp a b -> vars a (vars b acc)
      CLet _ a b -> vars a (vars b acc)
      CIf c t f -> vars c (vars t (vars f acc))
      CLam _ b -> vars b acc
      CMk _ _ fs -> foldr vars acc fs
      CTagEq _ _ x -> vars x acc
      CProj _ x -> vars x acc
      _ -> acc
    primitive bound h = S.notMember h bound && S.notMember h globals
    call h = foldl CApp (CVar h)
    access h = lookup h [("Mem." ++ op ++ width, "$mem." ++ op ++ width ++ "at")
                        | op <- ["read", "write"], width <- ["8", "16", "32", "Word"]]
    release bound addr e = case e of
      CLet r a rest | spineOf a == (CVar "Rc.release", [CVar addr]),
                      primitive bound "Rc.release", r /= addr ->
        Just (CLet r (CMk 0 0 []) rest)
      _ | spineOf e == (CVar "Rc.release", [CVar addr]), primitive bound "Rc.release" -> Just (CMk 0 0 [])
      _ -> Nothing
    pureArg bound (CVar n) = S.member n bound
    pureArg _ (CInt _) = True
    pureArg _ _ = False
    fuse bound e = case e of
      CLet addr a (CLet v mem rest)
        | (CVar "Addr.add", [base, offset]) <- spineOf a,
          primitive bound "Addr.add", addr /= v,
          M.findWithDefault 0 addr uses == 2,
          (CVar h, args) <- spineOf mem, primitive (S.insert addr bound) h,
          Just fused <- access h,
          CVar p : values <- args, p == addr,
          (null values && "Mem.read" `isPrefixOf` h)
            || (length values == 1 && "Mem.write" `isPrefixOf` h && all (pureArg bound) values),
          Just tail' <- release (S.insert v (S.insert addr bound)) addr rest ->
            CLet v (call fused (base : offset : values)) tail'
      _ -> e
    go bound e = fuse bound $ case e of
      CLet x a b -> CLet x (go bound a) (go (S.insert x bound) b)
      CApp a b -> CApp (go bound a) (go bound b)
      CIf c t f -> CIf (go bound c) (go bound t) (go bound f)
      CLam ps b -> CLam ps (go (S.union bound (S.fromList ps)) b)
      CMk t v fs -> CMk t v (map (go bound) fs)
      CTagEq t v x -> CTagEq t v (go bound x)
      CProj k x -> CProj k (go bound x)
      _ -> e

