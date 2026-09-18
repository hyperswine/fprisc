{-# LANGUAGE LambdaCase #-}
-- Conservative, first-order ownership lowering. Input is lambda-lifted Core.
-- All local bindings own a reference; evaluating a local produces a retained
-- reference. Calls/constructors consume their arguments and return owned values.
-- Cleanup is sequenced before tail transfers, never after them.
module Arc (lowerArc, arcExterns, arcRev, primitiveContracts) where

import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import FPRISC (Core(..), Prog)

-- Closed set of audited borrowed-input primitives with owned-result adapters.
-- The third component names the generated C adapter, not the original ABI.
primitiveContracts :: [(String, Int, String)]
primitiveContracts =
  [("+",2,"add"),("-",2,"sub"),("*",2,"mul"),("/",2,"div"),
   ("==",2,"eq"),("!=",2,"ne"),("<",2,"lt"),(">",2,"gt"),
   ("<=",2,"le"),(">=",2,"ge"),("print",1,"print"),("str",1,"str"),
   ("strcat",2,"strcat"),("String.len",1,"strlen"),("error",1,"error")]
  ++ [("Word." ++ n,a,"word" ++ n) | (n,a) <-
       [("fromInt",1),("toInt",1),("bits",1),("and",2),("or",2),("xor",2),
        ("add",2),("sub",2),("not",1),("shl",2),("shr",2),("mask",2),("eq",2),("bitSet",2),("bitClear",2),("bitTest",2)]]
  ++ [("Addr." ++ n,a,"addr" ++ n) | (n,a) <-
       [("fromWord",1),("toWord",1),("add",2),("null",1),("eq",2)]]
  ++ [("Mem." ++ n,a,"mem" ++ n) | (n,a) <-
       [("read8",1),("read16",1),("read32",1),("readWord",1),
        ("write8",2),("write16",2),("write32",2),("writeWord",2),
        ("atomicExchange",2),("compareExchange",3),("alloc",1),("realloc",2),("free",1),("fence",1),("liveAllocations",1)]]

  ++ [("CPU." ++ n,a,"cpu" ++ n) | (n,a) <-
       [("csrRead",1),("csrWrite",2),("irqSave",1),("irqRestore",1),
        ("irqEnable",1),("wait",1),("instructionFence",1)]]

arcExterns :: M.Map String Int
arcExterns = M.fromList $ [("$arc.retain",1),("$arc.release",1)] ++
  [("$arc." ++ adapter,arity) | (_,arity,adapter) <- primitiveContracts]

-- Bump when ownership lowering or its runtime ABI changes: keys unit caches.
arcRev :: Int
arcRev = 3

type G = StateT Int (Either String)
type Env = M.Map String String
fresh :: G String
fresh = do n <- get; put (n+1); pure ("$arc.local." ++ show n)
failArc :: String -> G a
failArc = lift . Left . ("automatic ARC: " ++)
call :: String -> [Core] -> Core
call n = foldl CApp (CVar n)
bind :: Core -> (Core -> G Core) -> G Core
bind e k = do n <- fresh; CLet n e <$> k (CVar n)
release :: [String] -> Core -> G Core
release [] body = pure body
release (n:ns) body = do
  rest <- release ns body
  ignored <- fresh
  pure (CLet ignored (call "$arc.release" [CVar n]) rest)
spine :: Core -> (Core,[Core])
spine = go [] where
  go as (CApp f x) = go (x:as) f
  go as f = (f,as)

lowerArc :: M.Map String Int -> Prog -> Either String Prog
lowerArc external prog = evalStateT (M.traverseWithKey lower prog) 0
  where
    arities = M.union (M.map (length . fst) prog) external
    prims = M.fromList [(n,(a,"$arc."++adapter)) | (n,a,adapter) <- primitiveContracts]
    lower _name (ps,body) = do
      ps' <- mapM (const fresh) ps
      body' <- tailE (M.fromList (zip ps ps')) ps' body
      pure (ps',body')
      -- Each function is independent; fresh names also prevent source shadowing
      -- from releasing a newer binding in place of an older owner.
    target env f args = case f of
      CVar n | M.notMember n env ->
        case M.lookup n arities of
          Just ar | ar == length args -> pure n
                  | otherwise -> failArc ("partial/over-application of " ++ n ++ " is not supported yet")
          Nothing -> case M.lookup n prims of
            Just (ar,adapter) | ar == length args -> pure adapter
            _ -> failArc ("unsupported primitive or application: " ++ n)
      _ -> failArc "indirect calls and closures are not supported yet"
    argsE _ [] k = k []
    argsE env (x:xs) k = eval env x $ \v -> argsE env xs (k . (v:))
    -- Non-tail evaluation supplies exactly one owned value to its continuation.
    eval env expr k = case expr of
      CVar n -> case M.lookup n env of
        Just owner -> bind (call "$arc.retain" [CVar owner]) k
        Nothing -> case M.lookup n arities of
          Just 0 -> bind (CVar n) k
          _ -> failArc ("function values or unsupported global: " ++ n)
      CInt _ -> k expr
      CStr _ -> k expr
      CLet x a b -> eval env a $ \v -> do
        owner <- fresh
        body <- eval (M.insert x owner env) b $ \result -> do
          rest <- k result
          release [owner] rest
        pure (CLet owner v body)
      CIf c t f -> eval env c $ \cv -> do
        yes <- eval env t pure >>= releaseValue cv
        no <- eval env f pure >>= releaseValue cv
        bind (CIf cv yes no) k
      CMk tid variant fields -> argsE env fields $ \vs -> bind (CMk tid variant vs) k
      CProj i obj -> eval env obj $ \v ->
        bind (call "$arc.retain" [CProj i v]) $ \r -> k r >>= releaseValue v
      CTagEq tid variant obj -> eval env obj $ \v ->
        bind (CTagEq tid variant v) $ \r -> k r >>= releaseValue v
      CApp {} -> let (f,as) = spine expr in do
        n <- target env f as
        argsE env as $ \vs -> bind (call n vs) k
      CErr _ -> pure expr -- panic terminates the whole standalone execution
      CLam {} -> failArc "lambda survived lifting"
    releaseValue (CVar n) body = release [n] body
    releaseValue _ body = pure body -- immediate or immortal literal
    -- Keep direct saturated calls in tail position after all owners are dropped.
    tailE env owners expr = case expr of
      CVar n | M.notMember n env, Just 0 <- M.lookup n arities -> release owners (CVar n)
      CLet x a b -> eval env a $ \v -> do
        owner <- fresh
        body <- tailE (M.insert x owner env) (owner:owners) b
        pure (CLet owner v body)
      CIf c t f -> eval env c $ \cv -> do
        yes <- tailE env owners t >>= releaseValue cv
        no <- tailE env owners f >>= releaseValue cv
        pure (CIf cv yes no)
      CApp {} -> let (f,as) = spine expr in do
        n <- target env f as
        argsE env as $ \vs -> release owners (call n vs)
      CErr _ -> pure expr
      _ -> eval env expr $ \v -> release owners v
