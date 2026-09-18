{-# LANGUAGE LambdaCase #-}
-- Conservative, first-order ownership lowering. Input is lambda-lifted Core.
-- Managed local bindings own a reference; evaluating one produces a retained
-- reference. Calls/constructors consume their arguments and return owned values.
-- Cleanup is sequenced before tail transfers, never after them.
module Arc (lowerArc, arcExterns, arcRev, primitiveContracts) where

import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import Interrupt (checkInterrupt)
import Representation (Kind, represent)
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

  ++ [("F64.+",2,"F64add"),
      ("F64.-",2,"F64sub"),
      ("F64.*",2,"F64mul"),
      ("F64./",2,"F64div"),
      ("F64.<",2,"F64lt"),
      ("F64.>",2,"F64gt"),
      ("F64.<=",2,"F64le"),
      ("F64.>=",2,"F64ge"),
      ("F64.==",2,"F64eq"),
      ("F64.!=",2,"F64ne"),
      ("F64.sqrt",1,"F64sqrt"),
      ("F64.ofInt",1,"F64ofInt"),
      ("F64.toInt",1,"F64toInt"),
      ("F64.str",1,"F64str"),
      ("F64.log",1,"F64log"),
      ("F64.log2",1,"F64log2"),
      ("F64.exp",1,"F64exp"),
      ("F64.pow",2,"F64pow"),
      ("F64.sin",1,"F64sin"),
      ("F64.cos",1,"F64cos"),
      ("F32.+",2,"F32add"),
      ("F32.-",2,"F32sub"),
      ("F32.*",2,"F32mul"),
      ("F32./",2,"F32div"),
      ("F32.<",2,"F32lt"),
      ("F32.>",2,"F32gt"),
      ("F32.<=",2,"F32le"),
      ("F32.>=",2,"F32ge"),
      ("F32.==",2,"F32eq"),
      ("F32.!=",2,"F32ne"),
      ("F32.sqrt",1,"F32sqrt"),
      ("F32.ofInt",1,"F32ofInt"),
      ("F32.toInt",1,"F32toInt"),
      ("F32.str",1,"F32str"),
      ("F32.log",1,"F32log"),
      ("F32.log2",1,"F32log2"),
      ("F32.exp",1,"F32exp"),
      ("F32.pow",2,"F32pow"),
      ("F32.sin",1,"F32sin"),
      ("F32.cos",1,"F32cos"),
      ("f64frombits",2,"f64frombits"),
      ("f32frombits",1,"f32frombits"),
      ("F64.ofF32",1,"F64ofF32"),
      ("F32.ofF64",1,"F32ofF64")]

arcExterns :: M.Map String Int
arcExterns = M.fromList $ [("$arc.retain",1),("$arc.release",1),("$arc.setLayout",2),("$arc.rawEq",2),("$arc.rawNe",2),("$arc.wordStr",1),("$arc.wordPrint",1)] ++
  [("$arc." ++ adapter,arity) | (_,arity,adapter) <- primitiveContracts]

-- Bump when ownership lowering or its runtime ABI changes: keys unit caches.
arcRev :: Int
arcRev = 4

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
lowerArc _external input = do
  (prog,ann,paramKinds) <- represent input
  checkInterrupt prog
  result <- lowerRepresented prog ann paramKinds
  let managed = maybe True ((== 't') . (ann M.!)) (snd <$> M.lookup "main" prog)
  pure (M.insert "$arc.mainManaged" ([],CInt (if managed then 1 else 0)) result)

lowerRepresented :: Prog -> M.Map Core Kind -> M.Map String [Kind] -> Either String Prog
lowerRepresented prog ann paramKinds = evalStateT (M.traverseWithKey lower prog) 0
  where
    managed e = ann M.! e == 't'
    ownersFor n ps = [p | (p,k) <- zip ps (paramKinds M.! n), k == 't']
    arities = M.map (length . fst) prog
    prims = M.fromList [(n,(a,"$arc."++adapter)) | (n,a,adapter) <- primitiveContracts]
    lower name (ps,body) = do
      ps' <- mapM (const fresh) ps
      body' <- tailE (M.fromList (zip ps ps')) (ownersFor name ps') body
      pure (ps',body')
      -- Each function is independent; fresh names also prevent source shadowing
      -- from releasing a newer binding in place of an older owner.
    target env f args = case f of
      CVar n | M.notMember n env ->
        case M.lookup n arities of
          Just ar | ar == length args -> pure n
                  | otherwise -> failArc ("partial/over-application of " ++ n ++ " is not supported yet")
          Nothing -> case M.lookup n prims of
            Just (ar,adapter) | ar == length args -> case (n,args) of
              (op,[a,_]) | op `elem` ["==","!="], not (managed a) ->
                pure (case M.lookup a ann of
                  Just 'd' -> "$arc.F64" ++ if op == "==" then "eq" else "ne"
                  Just 'f' -> "$arc.F32" ++ if op == "==" then "eq" else "ne"
                  _ -> if op == "==" then "$arc.rawEq" else "$arc.rawNe")
              (op,[a]) | op `elem` ["str","print"], not (managed a) ->
                if M.lookup a ann `elem` [Just 'w',Just 'a']
                  then pure (if op == "str" then "$arc.wordStr" else "$arc.wordPrint")
                  else failArc "use F32.str or F64.str to render a raw float"
              _ -> pure adapter
            _ -> failArc ("unsupported primitive or application: " ++ n)
      _ -> failArc "indirect calls and partial applications are not supported yet"
    argsE _ [] k = k []
    argsE env (x:xs) k = eval env x $ \v -> argsE env xs (k . (v:))
    -- Non-tail evaluation supplies exactly one owned value to its continuation.
    eval env expr k = case expr of
      CVar n -> case M.lookup n env of
        Just owner -> if managed expr then bind (call "$arc.retain" [CVar owner]) k else k (CVar owner)
        Nothing -> case M.lookup n arities of
          Just 0 -> bind (CVar n) k
          _ -> failArc ("function values or unsupported global: " ++ n)
      CInt _ -> k expr
      CStr _ -> k expr
      CLet x a b -> eval env a $ \v -> do
        owner <- fresh
        body <- eval (M.insert x owner env) b $ \result -> do
          rest <- k result
          release [owner | managed a] rest
        pure (CLet owner v body)
      CIf c t f -> eval env c $ \cv -> do
        yes <- eval env t pure >>= releaseValue cv
        no <- eval env f pure >>= releaseValue cv
        bind (CIf cv yes no) k
      CMk tid variant fields -> argsE env fields $ \vs -> bind (CMk tid variant vs) $ \v ->
        if null fields then k v else bind (call "$arc.setLayout" [v,CStr [ann M.! f | f <- fields]]) (const (k v))
      CProj i obj -> eval env obj $ \v ->
        bind (if managed expr then call "$arc.retain" [CProj i v] else CProj i v) $ \r -> k r >>= releaseValue v
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
        body <- tailE (M.insert x owner env) (if managed a then owner:owners else owners) b
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
