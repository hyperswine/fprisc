{-# LANGUAGE FlexibleContexts #-}
-- Whole-program representation unification for the standalone ARC ABI.
-- This deliberately rejects representation-polymorphic code until cloning is
-- implemented. Unknowns default to managed only after all call sites agree.
module Representation (represent, representWith, Kind(..), primitiveShape) where
import Representation.Types
import Core.Syntax (Core(..), Prog)
import Control.Monad (forM_, replicateM_, unless, zipWithM_)
import Data.List (isPrefixOf)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M

data Ty = Var Int | Scalar Kind | Text | Data Int deriving (Eq,Show)
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
    -- Strings and tagged/managed values share the same one-word ARC
    -- representation. Result Ok/Err projections may meet both variants;
    -- the source type checker already enforces their semantic types.
    (Text, Scalar Managed) -> pure ()
    (Scalar Managed, Text) -> pure ()
    (Var n,t) -> modify (\s -> s{subs=M.insert n t (subs s)})
    (t,Var n) -> modify (\s -> s{subs=M.insert n t (subs s)})
    _ -> err ("incompatible representations " ++ show x ++ " and " ++ show y ++
              "; specialize the function or data type for each representation")
kind :: Ty -> G Kind
kind t = resolve t >>= \x -> pure $ case x of Scalar k -> k; _ -> Managed
field :: (Int,Int,Int) -> G Ty
field key = do
  m <- gets fields
  case M.lookup key m of
    Just t -> pure t
    Nothing -> do t <- fresh; modify (\s -> s{fields=M.insert key t (fields s)}); pure t

-- Repeated AnyValue slots share one fresh type per application. Primitive
-- signatures use the same representation constructors as checked interfaces.
primitiveShape :: String -> Maybe PrimitiveShape
primitiveShape n = M.lookup n shapes
  where
    t=KnownValue (ScalarRep Managed);w=KnownValue (ScalarRep RawWord)
    a=KnownValue (ScalarRep RawAddr);d=KnownValue (ScalarRep RawF64);f=KnownValue (ScalarRep RawF32)
    s=KnownValue TextRep;b=KnownValue (DataRep 1);u=KnownValue (DataRep 0);r=KnownValue (DataRep 3)
    sh=PrimitiveShape
    shapes = M.fromList $ [(x,sh [t,t] t) | x <- ["+","-","*","/"]] ++
      [(x,sh [t,t] b) | x <- ["<",">","<=",">="]] ++
      [("==",sh [AnyValue,AnyValue] b),("!=",sh [AnyValue,AnyValue] b),("str",sh [AnyValue] s),("print",sh [AnyValue] u),
       ("strcat",sh [s,s] s),("String.len",sh [s] t),("error",sh [s] AnyValue),("intMax",sh [u] t),("intMin",sh [u] t)] ++
      [("Word."++x,sh ps result) | (x,ps,result) <- [("fromInt",[t],w),("toInt",[w],t),("bits",[u],t),
       ("and",[w,w],w),("or",[w,w],w),("xor",[w,w],w),("add",[w,w],w),("sub",[w,w],w),
       ("not",[w],w),("shl",[w,t],w),("shr",[w,t],w),("mask",[t,t],w),("eq",[w,w],b),
       ("bitSet",[w,t],w),("bitClear",[w,t],w),("bitTest",[w,t],b)]] ++
      [("Addr."++x,sh ps result) | (x,ps,result) <- [("fromWord",[w],a),("toWord",[a],w),("add",[a,t],a),
       ("null",[u],a),("eq",[a,a],b)]] ++
      [("Mem."++x,sh ps result) | (x,ps,result) <- [("read8",[a],t),("read16",[a],t),("read32",[a],w),
       ("readWord",[a],w),("write8",[a,t],u),("write16",[a,t],u),("write32",[a,w],u),
       ("writeWord",[a,w],u),("atomicExchange",[a,w],w),("compareExchange",[a,w,w],w),
       ("alloc",[t],a),("realloc",[a,t],a),("free",[a],u),("fence",[u],u),("liveAllocations",[u],t)]] ++
      [("CPU."++x,sh ps result) | (x,ps,result) <- [("csrRead",[t],w),("csrWrite",[t,w],u),("irqSave",[u],t),
       ("irqRestore",[t],u),("irqEnable",[u],u),("wait",[u],u),("instructionFence",[u],u)]] ++
      [("f64frombits",sh [t,t] d),("f32frombits",sh [t] f),("F64.ofF32",sh [f] d),("F32.ofF64",sh [d] f)] ++
      concat [[(p++x,sh [k,k] k) | x <- ["+","-","*","/","pow"]] ++
              [(p++x,sh [k,k] b) | x <- ["<",">","<=",">=","==","!="]] ++
              [(p++x,sh [k] k) | x <- ["sqrt","log","log2","exp","sin","cos"]] ++
              [(p++"ofInt",sh [t] k),(p++"toInt",sh [k] t),(p++"str",sh [k] s)]
             | (p,k) <- [("F64.",d),("F32.",f)]] ++
      [("I32."++x,sh [t,t] t) | x <- ["+","-","*","/","rem","divU","remU","and","or","xor",
                                  "shl","shr","sar","rotl","rotr"]] ++
      [("I32."++x,sh [t,t] b) | x <- ["<",">","<=",">=","==","!=","ltU","gtU","leU","geU"]] ++
      [("I32."++x,sh [t] t) | x <- ["not","neg","clz","ctz","popcnt","ofInt"]] ++
      [("I32."++x,sh [t] s) | x <- ["str","strU","hex"]] ++
      [("I32.toInt",sh [t] r),("I32.toIntU",sh [t] r),("I32.parse",sh [s] r)]

repType :: Rep -> Ty
repType rep=case rep of ScalarRep k->Scalar k;TextRep->Text;DataRep tid->Data tid

represent :: Prog -> Either String (Prog, M.Map Core Kind, M.Map String [Kind])
represent = representWith M.empty

representWith :: M.Map String CallSignature -> Prog -> Either String (Prog, M.Map Core Kind, M.Map String [Kind])
representWith declarations input = evalStateT work (St 0 M.empty M.empty M.empty [])
  where
    -- Alpha-renaming makes expression annotations unambiguous across scopes.
    work = do
      prog <- M.traverseWithKey (\_ (ps,b) -> do
        ns <- mapM (const name) ps
        b' <- rename (M.fromList (zip ps ns)) b
        pure (ns,b')) input
      sig <- traverse (\(ps,_) -> do as <- mapM (const fresh) ps; r <- fresh; pure (as,r)) prog
      forM_ (M.toList declarations) $ \(name,CallSignature params result)->case M.lookup name sig of
        Nothing->err ("checked representation declaration has no function: "++name)
        Just (as,r)->do
          unless (length as==length params) (err ("checked representation declaration changed physical arity: "++name))
          zipWithM_ (\a known->maybe (pure ()) (unify a . repType) known) as params
          maybe (pure ()) (unify r . repType) result
      case M.lookup "machineInterrupt" sig of
        Nothing -> pure ()
        Just (as,result) -> do
          unless (length as == 3) $ err "machineInterrupt requires cause, pc and trap-value Word arguments"
          mapM_ (`unify` Scalar RawWord) as
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
        CInt _ -> pure (Scalar Managed)
        CStr _ -> pure (Text)
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
        Nothing | "$sym." `isPrefixOf` n -> pure ([], Scalar RawAddr) -- a link-time address
        Nothing -> case primitiveShape n of
          Nothing -> err ("unsupported primitive or function value: " ++ n)
          Just (PrimitiveShape params result) -> do
            anyT <- fresh
            let ty AnyValue=anyT;ty (KnownValue rep)=repType rep
            pure (map ty params,ty result)
      unless (length actual == length expected) $ err ("partial/over-application of " ++ n ++ " is not supported yet")
      zipWithM_ unify actual expected
      pure result
    spine = go [] where
      go as (CApp f x) = go (x:as) f
      go as f = (f,as)
