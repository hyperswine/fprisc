-- Core up to binder names: the same body under any spelling of its
-- binders compares equal after `canonical` (P2 typed lowering: the stage
-- trace and the emission's reshaped-body test).
--
-- `substituteLiterals` replaces every let bound to an Int literal (or to an
-- alias of one) by the literal at its uses, the one rewrite the typed plan
-- shares with the optimizer's normIn.
module Core.Alpha (canonical, substituteLiterals, firstTextDifference, diagnosticNormal, rewriteKind) where
import Core.Syntax (Core (..))
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- binders renamed in binding order, free names kept
canonical :: ([String], Core) -> ([String], Core)
canonical (params, body) = (fresh, go (M.fromList (zip params fresh)) (length params) body)
  where
    fresh = [binder i | i <- [0 .. length params - 1]]
    binder i = "%" ++ show (i :: Int)
    go env k e = case e of
      CVar n -> CVar (M.findWithDefault n n env)
      CApp a b -> CApp (go env k a) (go env k b)
      CLam ps b ->
        let names = [binder (k + i) | i <- [0 .. length ps - 1]]
         in CLam names (go (M.union (M.fromList (zip ps names)) env) (k + length ps) b)
      CLet x a b -> CLet (binder k) (go env k a) (go (M.insert x (binder k) env) (k + 1) b)
      CIf c t f -> CIf (go env k c) (go env k t) (go env k f)
      CMk t v fs -> CMk t v (map (go env k) fs)
      CTagEq t v x -> CTagEq t v (go env k x)
      CProj i x -> CProj i (go env k x)
      other -> other

substituteLiterals :: Core -> Core
substituteLiterals = go M.empty
  where
    go env e = case e of
      CVar n -> M.findWithDefault e n env
      CLet x a b -> case go env a of
        lit@(CInt _) -> go (M.insert x lit env) b
        a' -> CLet x a' (go (M.delete x env) b)
      CApp a b -> CApp (go env a) (go env b)
      CLam ps b -> CLam ps (go (foldr M.delete env ps) b)
      CIf c t f -> CIf (go env c) (go env t) (go env f)
      CMk t v fs -> CMk t v (map (go env) fs)
      CTagEq t v x -> CTagEq t v (go env x)
      CProj i x -> CProj i (go env x)
      other -> other

-- a diagnostic: where two Core values' printed forms first differ, with a
-- window of each around that point
firstTextDifference :: ([String], Core) -> ([String], Core) -> String
firstTextDifference a b =
  let x = show a; y = show b
      i = length (takeWhile id (zipWith (==) x y))
      window s = take 220 (drop (max 0 (i - 60)) s)
   in "at " ++ show i ++ " of " ++ show (length x) ++ "/" ++ show (length y) ++ "\n  plan:     " ++ window x ++ "\n  lowered:  " ++ window y

-- a diagnostic normal form: variable aliases substituted, and a let whose
-- value is itself a let floated out (both rewrites leave Lower's code
-- unchanged), so a difference shown is one that matters
-- (a global's name, e.g. a closure value with no captures, is not an alias)
diagnosticNormal :: [String] -> Core -> Core
diagnosticNormal params = go0 (S.fromList params) M.empty
  where
    go0 bound env e = case e of
      CVar n -> CVar (M.findWithDefault n n env)
      CLet x a b -> case go0 bound env a of
        CVar y | S.member y bound -> go0 bound (M.insert x y env) b
        CLet y a' b' -> go0 bound env (CLet y a' (CLet x b' b))
        a' -> CLet x a' (go0 (S.insert x bound) (M.delete x env) b)
      CApp a b -> CApp (go0 bound env a) (go0 bound env b)
      CLam ps b -> CLam ps (go0 (foldr S.insert bound ps) (foldr M.delete env ps) b)
      CIf c t f -> CIf (go0 bound env c) (go0 bound env t) (go0 bound env f)
      CMk t v fs -> CMk t v (map (go0 bound env) fs)
      CTagEq t v x -> CTagEq t v (go0 bound env x)
      CProj i x -> CProj i (go0 bound env x)
      other -> other

-- a diagnostic: what the first difference between a planned and a lowered
-- body is, at the first node where they differ (both canonical)
rewriteKind :: Core -> Core -> String
rewriteKind p q = maybe "same" (uncurry kind) (mismatch p q)
  where
    mismatch a b = case (a, b) of
      (CApp f x, CApp g y) | sameHead a b -> first [(f, g), (x, y)]
      (CLam ps x, CLam qs y) | length ps == length qs -> mismatch x y
      (CLet _ x u, CLet _ y v) | sameHead x y -> first [(x, y), (u, v)]
      (CIf c t f, CIf d u g) -> first [(c, d), (t, u), (f, g)]
      (CMk t v xs, CMk t' v' ys) | t == t' && v == v' && length xs == length ys -> first (zip xs ys)
      (CTagEq t v x, CTagEq t' v' y) | t == t' && v == v' -> mismatch x y
      (CProj i x, CProj j y) | i == j -> mismatch x y
      _ | a == b -> Nothing
        | otherwise -> Just (a, b)
    sameHead x y = case (spineHead x, spineHead y) of
      ((CVar h, k), (CVar h', k')) -> h == h' && k == k'
      ((h, k), (h', k')) -> node h == node h' && k == k'
    first = foldr (\(a, b) rest -> maybe rest Just (mismatch a b)) Nothing
    kind a b = case a of
      CLet x rhs body ->
        let n = uses x body
            what = case n of
              0 -> "dead let removed"
              1 -> "single-use let sunk"
              _ -> "let with " ++ show n ++ " uses differs"
         in what ++ closure rhs ++ " (lowered: " ++ node b ++ ")"
      _ -> "plan " ++ node a ++ " vs lowered " ++ node b
    closure rhs = case spineHead rhs of
      (CVar h, _) | "$typed_lifted" `isPrefixOf` h -> ", a closure value"
      _ -> ""
    spineHead e = case e of CApp f _ -> let (h, k) = spineHead f in (h, k + 1); _ -> (e, 0 :: Int)
    uses x e = case e of
      CVar n -> if n == x then 1 else 0
      CApp f y -> uses x f + uses x y
      CLam _ y -> uses x y
      CLet _ y z -> uses x y + uses x z
      CIf c t f -> uses x c + uses x t + uses x f
      CMk _ _ ys -> sum (map (uses x) ys)
      CTagEq _ _ y -> uses x y
      CProj _ y -> uses x y
      _ -> 0 :: Int
    node e = case e of
      CVar _ -> "var"; CInt _ -> "int"; CStr _ -> "string"; CApp {} -> "application"; CLam {} -> "lambda"
      CLet {} -> "let"; CIf {} -> "if"; CMk {} -> "constructor"; CTagEq {} -> "tag test"; CProj {} -> "projection"; CErr _ -> "error"
