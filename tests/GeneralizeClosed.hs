module Main where
-- generalize skips the snapshot for closed schemes; the scheme it returns
-- must equal the original formula (snapshot every environment entry), for
-- closed, open, solved-open and builtin environments.
import Infer
import Control.Monad (unless)
import Control.Monad.State.Strict (evalState)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

reference :: TEnv -> Type -> I Scheme
reference env t0 = do
  t <- zonk t0
  envFtv <- mconcat <$> mapM schemeFtv (M.elems env)
  let (tv, rv) = ftv t
      (etv, erv) = envFtv
  pure (Forall (S.toList (tv S.\\ etv)) (S.toList (rv S.\\ erv)) t)
  where
    schemeFtv sc = do
      Forall qs rqs ty' <- snapshotScheme sc
      let (tv, rv) = ftv ty'
      pure (tv S.\\ S.fromList qs, rv S.\\ S.fromList rqs)

scenario :: Bool -> I (Scheme, Scheme)
scenario solve = do
  a <- freshT; b <- freshT; c <- freshT
  let env = M.fromList
        [ ("closed", Forall [100] [] (TFn (TV 100) (TV 100)))
        , ("open", Forall [] [] (TFn a tInt))
        , ("mixed", Forall [101] [] (TFn (TV 101) b))
        ] `M.union` builtinEnv
  if solve then unify "test" b tInt else pure ()
  let t = TFn a (TFn b c)
  (,) <$> generalize env t <*> reference env t

main :: IO ()
main = do
  let same (x, y) = show x == show y
  unless (same (evalState (scenario False) (initialIEnv Nothing))) (error "generalize differs (unsolved)")
  unless (same (evalState (scenario True) (initialIEnv Nothing))) (error "generalize differs (solved)")
  unless (closedScheme (Forall [1] [] (TFn (TV 1) (TV 1)))) (error "closed")
  unless (not (closedScheme (Forall [1] [] (TFn (TV 1) (TV 2))))) (error "open")
  putStrLn "GeneralizeClosed: ok"
