-- Kinds of the raw-word callback ABI, solved independently for every argument
-- and result. Conflicts/unsupported Core decline to the ordinary tagged path.
module KernelKinds (Kind(..), signature) where
import FPRISC (Core(..), Prog)
import Control.Monad.State.Strict
import Control.Monad (guard, zipWithM_)
import qualified Data.Map.Strict as M

data Kind = KI | KD | KS | KB deriving (Eq,Show)
data Term = Var Int | Known Kind deriving (Eq)
data Solve = Solve Int (M.Map Int Term) (M.Map String ([Term],Term))
type K = StateT Solve Maybe
fresh :: K Term
fresh = do Solve n s fs <- get; put (Solve (n+1) s fs); pure (Var n)
resolve :: Term -> K Term
resolve t@(Known _) = pure t
resolve t@(Var n) = do Solve _ s _ <- get; maybe (pure t) resolve (M.lookup n s)
unify :: Term -> Term -> K ()
unify a b = do
  x <- resolve a; y <- resolve b
  case (x,y) of
    _ | x == y -> pure ()
    (Var n,t) -> modify (\(Solve i s fs) -> Solve i (M.insert n t s) fs)
    (t,Var n) -> unify (Var n) t
    _ -> lift Nothing
spine :: Core -> (Core,[Core])
spine = go [] where go as (CApp f x) = go (x:as) f; go as f = (f,as)
function :: Prog -> String -> K ([Term],Term)
function prog f = do
  Solve _ _ fs <- get
  case M.lookup f fs of
    Just sig -> pure sig
    Nothing -> do
      (ps,b) <- lift (M.lookup f prog)
      args <- mapM (const fresh) ps; result <- fresh
      modify (\(Solve i s tab) -> Solve i s (M.insert f (args,result) tab))
      actual <- expr prog (M.fromList (zip ps args)) b
      unify result actual
      pure (args,result)
expr :: Prog -> M.Map String Term -> Core -> K Term
expr prog env e = case spine e of
  (CVar "f64frombits",[CInt _,CInt _]) -> pure (Known KD)
  (CVar "f32frombits",[CInt _]) -> pure (Known KS)
  (CVar op,[a,b]) | Just (input,output) <- primitive op -> do
    x <- expr prog env a; y <- expr prog env b
    unify x (Known input); unify y (Known input); pure (Known output)
  (CVar f,as@(_:_)) | M.member f prog, M.notMember f env -> do
    (ps,r) <- function prog f
    guard (length ps == length as)
    xs <- mapM (expr prog env) as; zipWithM_ unify ps xs; pure r
  _ -> case e of
    CVar n -> lift (M.lookup n env)
    CInt _ -> pure (Known KI)
    CMk 1 _ [] -> pure (Known KB)
    CTagEq 1 _ x -> do t <- expr prog env x; unify t (Known KB); pure (Known KB)
    CLet n a b -> do t <- expr prog env a; expr prog (M.insert n t env) b
    CIf c a b -> do
      t <- expr prog env c; unify t (Known KB)
      x <- expr prog env a; y <- expr prog env b; unify x y; pure x
    CErr _ -> fresh
    _ -> lift Nothing
primitive :: String -> Maybe (Kind,Kind)
primitive op = do
  (k,o) <- case splitAt 4 op of
    ("F64.",o) -> Just (KD,o)
    ("F32.",o) -> Just (KS,o)
    _ -> Just (KI,op)
  guard (o `elem` ["+","-","*","/","==","!=","<",">","<=",">="])
  pure (k,if o `elem` ["+","-","*","/"] then k else KB)
signature :: Prog -> [String] -> Core -> Maybe ([Kind],Kind)
signature prog ps body = evalStateT solve (Solve 0 M.empty M.empty)
  where
    solve = do
      args <- mapM (const fresh) ps
      result <- expr prog (M.fromList (zip ps args)) body
      let kind t = do r <- resolve t; pure (case r of Known k -> k; Var _ -> KI)
      ks <- mapM kind args; k <- kind result; pure (ks,k)
