-- Core up to binder names: the same body under any spelling of its
-- binders compares equal after `canonical` (P2 typed lowering: the stage
-- trace and the emission's reshaped-body test).
--
-- `substituteLiterals` replaces every let bound to an Int literal (or to an
-- alias of one) by the literal at its uses, the one rewrite the typed plan
-- shares with the optimizer's normIn.
module Core.Alpha (canonical, substituteLiterals) where
import Core.Syntax (Core (..))
import qualified Data.Map.Strict as M

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
