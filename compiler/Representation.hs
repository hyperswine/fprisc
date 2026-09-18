{-# LANGUAGE FlexibleContexts #-}
-- Whole-program representation unification for the standalone ARC ABI.
-- This deliberately rejects representation-polymorphic code until cloning is
-- implemented. Unknowns default to managed only after all call sites agree.
module Representation (represent, Kind, primitiveShape) where
import FPRISC (Core(..), Prog)
import Control.Monad (forM_, replicateM_, unless, zipWithM_)
import Data.List (isPrefixOf)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M

type Kind = Char -- t: tagged/managed, w: Word, a: Addr, d: F64, f: F32
data Ty = Var Int | Scalar Kind | Data Int deriving (Eq,Show)
data St = St { next :: Int, subs :: M.Map Int Ty, marks :: M.Map Core Ty,
               fields :: M.Map (Int,Int,Int) Ty, projections :: [(Ty,Int,Ty)] }
type G = StateT St (Either String)
fresh :: G Ty
fresh = do s <- get; put s{next=next s+1}; pure (Var (next s))
err :: String -> G a
err = lift . Left . ("automatic ARC: " ++)
resolve :: Ty -> G Ty
resolve (Var n) = gets (M.lookup n . subs) >>= maybe (pure (Var n)) resolve
resolve t = pure t
unify :: Ty -> Ty -> G ()
unify a b = do
  x <- resolve a; y <- resolve b
  case (x,y) of
    _ | x == y -> pure ()
    (Var n,t) -> modify (\s -> s{subs=M.insert n t (subs s)})
    (t,Var n) -> modify (\s -> s{subs=M.insert n t (subs s)})
    _ -> err ("incompatible representations " ++ show x ++ " and " ++ show y ++
              "; specialize the function or data type for each representation")
kind :: Ty -> G Kind
kind t = resolve t >>= \x -> pure $ case x of Scalar 's' -> 't'; Scalar k -> k; _ -> 't'
field :: (Int,Int,Int) -> G Ty
field key = do
  m <- gets fields
  case M.lookup key m of
    Just t -> pure t
    Nothing -> do t <- fresh; modify (\s -> s{fields=M.insert key t (fields s)}); pure t

-- '?' is instantiated freshly per primitive application; matching occurrences
-- share a type. b/u are the ordinary immortal Bool/Unit algebraic values.
primitiveShape :: String -> Maybe String
primitiveShape n = M.lookup n shapes
  where
    shapes = M.fromList $ [(x,"ttt") | x <- ["+","-","*","/"]] ++
      [(x,"ttb") | x <- ["<",">","<=",">="]] ++
      [("==","??b"),("!=","??b"),("str","?s"),("print","?u"),
       ("strcat","sss"),("String.len","st"),("error","s?")] ++
      [("Word."++x,y) | (x,y) <- [("fromInt","tw"),("toInt","wt"),("bits","ut"),
       ("and","www"),("or","www"),("xor","www"),("add","www"),("sub","www"),
       ("not","ww"),("shl","wtw"),("shr","wtw"),("mask","ttw"),("eq","wwb"),
       ("bitSet","wtw"),("bitClear","wtw"),("bitTest","wtb")]] ++
      [("Addr."++x,y) | (x,y) <- [("fromWord","wa"),("toWord","aw"),("add","ata"),
       ("null","ua"),("eq","aab")]] ++
      [("Mem."++x,y) | (x,y) <- [("read8","at"),("read16","at"),("read32","aw"),
       ("readWord","aw"),("write8","atu"),("write16","atu"),("write32","awu"),
       ("writeWord","awu"),("atomicExchange","aww"),("compareExchange","awww"),
       ("alloc","ta"),("realloc","ata"),("free","au"),("fence","uu"),("liveAllocations","ut")]] ++
      [("CPU."++x,y) | (x,y) <- [("csrRead","tw"),("csrWrite","twu"),("irqSave","ut"),
       ("irqRestore","tu"),("irqEnable","uu"),("wait","uu"),("instructionFence","uu")]] ++
      [("f64frombits","ttd"),("f32frombits","tf"),("F64.ofF32","fd"),("F32.ofF64","df")] ++
      concat [[(p++x,[k,k,k]) | x <- ["+","-","*","/","pow"]] ++
              [(p++x,[k,k,'b']) | x <- ["<",">","<=",">=","==","!="]] ++
              [(p++x,[k,k]) | x <- ["sqrt","log","log2","exp","sin","cos"]] ++
              [(p++"ofInt",['t',k]),(p++"toInt",[k,'t']),(p++"str",[k,'s'])]
             | (p,k) <- [("F64.",'d'),("F32.",'f')]]

represent :: Prog -> Either String (Prog, M.Map Core Kind, M.Map String [Kind])
represent input = evalStateT work (St 0 M.empty M.empty M.empty [])
  where
    -- Alpha-renaming makes expression annotations unambiguous across scopes.
    work = do
      prog <- M.traverseWithKey (\_ (ps,b) -> do
        ns <- mapM (const name) ps
        b' <- rename (M.fromList (zip ps ns)) b
        pure (ns,b')) input
      sig <- traverse (\(ps,_) -> do as <- mapM (const fresh) ps; r <- fresh; pure (as,r)) prog
      case M.lookup "machineInterrupt" sig of
        Nothing -> pure ()
        Just (as,result) -> do
          unless (length as == 3) $ err "machineInterrupt requires cause, pc and trap-value Word arguments"
          mapM_ (`unify` Scalar 'w') as
          unify result (Data 0)
      forM_ (M.toList prog) $ \(n,(ps,b)) -> do
        let (as,r) = sig M.! n
        t <- infer sig (M.fromList (zip ps as)) b
        unify r t
      -- Projections may only acquire a data type through another projection.
      ps <- gets projections
      replicateM_ (length ps + 1) $ forM_ ps $ \(obj,i,result) -> do
        t <- resolve obj
        case t of
          Data tid -> do
            fs <- gets fields
            let candidates = [v | ((t',_,i'),v) <- M.toList fs,t'==tid,i'==i]
            mapM_ (unify result) candidates
          Var _ -> pure ()
          _ -> err "projection from a non-algebraic representation"
      forM_ ps $ \(obj,_,_) -> resolve obj >>= \t -> case t of
        Var _ -> err "cannot determine projected data layout; use a concrete data type"
        _ -> pure ()
      ann <- gets marks >>= traverse kind
      args <- traverse (mapM kind . fst) sig
      pure (prog,ann,args)
    name = do n <- gets next; _ <- fresh; pure ("$rep." ++ show n)
    rename env e = case e of
      CVar n -> pure (CVar (M.findWithDefault n n env))
      CLet n a b -> do a' <- rename env a; n' <- name; b' <- rename (M.insert n n' env) b; pure (CLet n' a' b')
      CApp f x -> CApp <$> rename env f <*> rename env x
      CIf c t f -> CIf <$> rename env c <*> rename env t <*> rename env f
      CMk t v fs -> CMk t v <$> mapM (rename env) fs
      CProj i x -> CProj i <$> rename env x
      CTagEq t v x -> CTagEq t v <$> rename env x
      CLam {} -> err "lambda survived lifting"
      _ -> pure e
    infer sig env e = do
      t <- case e of
        CInt _ -> pure (Scalar 't')
        CStr _ -> pure (Scalar 's')
        CVar n -> case M.lookup n env of
          Just t -> pure t
          Nothing -> apply sig n []
        CLet n a b -> do t <- infer sig env a; infer sig (M.insert n t env) b
        CIf c a b -> do
          tc <- infer sig env c; unify tc (Data 1)
          ta <- infer sig env a; tb <- infer sig env b; unify ta tb; pure ta
        CMk tid v fs -> do
          forM_ (zip [0..] fs) $ \(i,f) -> do a <- infer sig env f; b <- field (tid,v,i); unify a b
          pure (Data tid)
        CTagEq tid _ x -> do t <- infer sig env x; unify t (Data tid); pure (Data 1)
        CProj i x -> do
          a <- infer sig env x; b <- fresh
          modify (\s -> s{projections=(a,i,b):projections s}); pure b
        CApp {} -> let (f,as) = spine e in case f of
          CVar n | M.notMember n env -> mapM (infer sig env) as >>= apply sig n
          _ -> err "indirect calls and partial applications are not supported yet"
        CErr _ -> fresh
        CLam {} -> err "lambda survived lifting"
      modify (\s -> s{marks=M.insert e t (marks s)})
      pure t
    apply sig n actual = do
      (expected,result) <- case M.lookup n sig of
        Just s -> pure s
        Nothing | "$sym." `isPrefixOf` n -> pure ([], Scalar 'a') -- a link-time address
        Nothing -> case primitiveShape n of
          Nothing -> err ("unsupported primitive or function value: " ++ n)
          Just shape -> do
            anyT <- fresh
            let ty '?' = anyT; ty 'b' = Data 1; ty 'u' = Data 0; ty k = Scalar k
            pure (map ty (init shape),ty (last shape))
      unless (length actual == length expected) $ err ("partial/over-application of " ++ n ++ " is not supported yet")
      zipWithM_ unify actual expected
      pure result
    spine = go [] where
      go as (CApp f x) = go (x:as) f
      go as f = (f,as)
