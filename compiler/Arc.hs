{-# LANGUAGE LambdaCase #-}
-- Conservative, first-order ownership lowering. Input is lambda-lifted Core.
-- Managed local bindings own a reference; evaluating one produces a retained
-- reference. Calls/constructors consume their arguments and return owned values.
-- Cleanup is sequenced before tail transfers, never after them.
module Arc
  ( lowerArc,
    lowerRaw,
    lowerArcWith,
    lowerRawWith,
    lowerArcWithOptions,
    lowerRawWithOptions,
    lowerArcWithLayouts,
    lowerArcWithEvidence,
    lowerArcWithProductEvidence,
    lowerRawWithEvidence,
    lowerRawWithProductEvidence,
    lowerRawWithLayouts,
    arcExterns,
    arcRev,
    primitiveContracts,
  ) where

import Control.Monad.State.Strict
import Control.Monad (unless)
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Interrupt (checkInterruptWithProducts, checkRawUnitWithProducts, checkLoweredProducts, rawRoots)
import Representation (representWithProductEvidence)
import qualified Arc.Products as Products
import qualified Arc.Uniform as Uniform
import Representation.Types
import Core.Syntax (Core(..), Prog)

-- Closed set of audited borrowed-input primitives with owned-result adapters.
-- The third component names the generated C adapter, not the original ABI.
primitiveContracts :: [(String, Int, String)]
primitiveContracts =
  [("+",2,"add"),("-",2,"sub"),("*",2,"mul"),("/",2,"div"),
   ("==",2,"eq"),("!=",2,"ne"),("<",2,"lt"),(">",2,"gt"),
   ("<=",2,"le"),(">=",2,"ge"),("print",1,"print"),("str",1,"str"),
   ("strcat",2,"strcat"),("String.len",1,"strlen"),("error",1,"error"),
   ("intMax",1,"intMax"),("intMin",1,"intMin"),
   ("$trmc.setTail",2,"trmcSetTail")]
  ++ [("$uniform."++direction++kind,1,"uniform"++capital++kind)
      | (direction,capital)<-[("box","Box"),("unbox","Unbox")],kind<-["Word","Addr","F64","F32"]]
  ++ [("$uniform."++direction++kind,arity,"uniform"++capital++kind)
      | (direction,capital)<-[("box","Box"),("unbox","Unbox")],(kind,arity)<-[("Aggregate",3),("Managed",1)]]
  ++ [("$uniform.unbox"++kind,arity,"uniformUnbox"++kind)
      | (kind,arity)<-[("Tagged",1),("Text",1),("Data",2)]]
  ++ [("$uniform.project",2,"uniformProject"),("$uniform.tagEq",3,"uniformTagEq")]
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
  ++ [("I32." ++ n,a,"I32" ++ adapter) | (n,a,adapter) <-
       [("+",2,"add"),("-",2,"sub"),("*",2,"mul"),("/",2,"div"),
        ("<",2,"lt"),(">",2,"gt"),("<=",2,"le"),(">=",2,"ge"),("==",2,"eq"),("!=",2,"ne"),
        ("rem",2,"rem"),("divU",2,"divU"),("remU",2,"remU"),
        ("ltU",2,"ltU"),("gtU",2,"gtU"),("leU",2,"leU"),("geU",2,"geU"),
        ("and",2,"and"),("or",2,"or"),("xor",2,"xor"),("not",1,"not"),("neg",1,"neg"),
        ("shl",2,"shl"),("shr",2,"shr"),("sar",2,"sar"),("rotl",2,"rotl"),("rotr",2,"rotr"),
        ("clz",1,"clz"),("ctz",1,"ctz"),("popcnt",1,"popcnt"),
        ("ofInt",1,"ofInt"),("toInt",1,"toInt"),("toIntU",1,"toIntU"),
        ("str",1,"str"),("strU",1,"strU"),("hex",1,"hex"),("parse",1,"parse")]]

arcExterns :: M.Map String Int
arcExterns = M.fromList $ [("$arc.retain",1),("$arc.release",1),("$arc.setLayout",2),("$arc.rawEq",2),("$arc.rawNe",2),("$arc.wordStr",1),("$arc.wordPrint",1)] ++
  [("$arc.F64print",1),("$arc.F32print",1)] ++
  [("$arc." ++ adapter,arity) | (_,arity,adapter) <- primitiveContracts]

-- Bump when ownership lowering or its runtime ABI changes: keys unit caches.
arcRev :: Int
arcRev = 24

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
lowerArc = lowerArcWith M.empty

lowerArcWith :: M.Map String CallSignature -> M.Map String Int -> Prog -> Either String Prog
lowerArcWith declarations external input =
  fst <$> lowerArcWithOptions True S.empty declarations external input

lowerArcWithOptions :: Bool -> S.Set String -> M.Map String CallSignature -> M.Map String Int -> Prog -> Either String (Prog, [(String, String)])
lowerArcWithOptions = lowerArcWithLayouts M.empty

lowerArcWithLayouts :: LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> M.Map String Int -> Prog -> Either String (Prog, [(String, String)])
lowerArcWithLayouts=lowerArcWithEvidence M.empty

lowerArcWithEvidence :: M.Map String Rep -> LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> M.Map String Int -> Prog -> Either String (Prog, [(String,String)])
lowerArcWithEvidence=lowerArcWithProductEvidence 0

lowerArcWithProductEvidence :: Int -> M.Map String Rep -> LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> M.Map String Int -> Prog -> Either String (Prog, [(String,String)])
lowerArcWithProductEvidence capacity evidence layouts typeSpec pinned declarations _external input = do
  (uniformDeclarations,uniformInput) <- Uniform.entriesWithLayouts layouts pinned declarations (exposeConstructors capacity evidence layouts input)
  ((prog,ann,paramKinds,immortals,immortalArgs,scalars,decls),products) <- representWithProductEvidence capacity evidence layouts typeSpec pinned uniformDeclarations uniformInput
  checkInterruptWithProducts scalars (productValues products) prog
  result <- if M.null (productValues products)
    then lowerRepresented True prog ann paramKinds immortals immortalArgs scalars
    else Products.lowerProducts True pinned prog ann paramKinds immortals immortalArgs scalars products primitiveContracts
  unless (M.null (productValues products) || M.notMember "machineInterrupt" result) $
    checkLoweredProducts True primitiveContracts ["machineInterrupt"] result
  let managed = maybe True ((== Managed) . (ann M.!)) (snd <$> M.lookup "main" prog)
  pure (M.insert "$arc.mainManaged" ([],CInt (if managed then 1 else 0)) result, decls)

-- a raw unit: representation kinds as under --arc (Word/Addr/floats
-- unboxed, prims through the raw adapters), the allocation-free contract
-- on every function (Interrupt.checkRawUnit), and NO ownership
-- instrumentation -- nothing here owns anything
lowerRaw :: M.Map String Int -> Prog -> Either String Prog
lowerRaw = lowerRawWith M.empty

lowerRawWith :: M.Map String CallSignature -> M.Map String Int -> Prog -> Either String Prog
lowerRawWith declarations external input =
  fst <$> lowerRawWithOptions True S.empty declarations external input

lowerRawWithOptions :: Bool -> S.Set String -> M.Map String CallSignature -> M.Map String Int -> Prog -> Either String (Prog, [(String, String)])
lowerRawWithOptions = lowerRawWithLayouts M.empty

lowerRawWithLayouts :: LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> M.Map String Int -> Prog -> Either String (Prog, [(String, String)])
lowerRawWithLayouts=lowerRawWithEvidence M.empty

lowerRawWithEvidence :: M.Map String Rep -> LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> M.Map String Int -> Prog -> Either String (Prog, [(String,String)])
lowerRawWithEvidence=lowerRawWithProductEvidence 0

lowerRawWithProductEvidence :: Int -> M.Map String Rep -> LayoutTable -> Bool -> S.Set String -> M.Map String CallSignature -> M.Map String Int -> Prog -> Either String (Prog, [(String,String)])
lowerRawWithProductEvidence capacity evidence layouts typeSpec pinned declarations _external input = do
  ((prog,ann,paramKinds,_,_,scalars,decls),products) <- representWithProductEvidence capacity evidence layouts typeSpec pinned declarations (exposeConstructors capacity evidence layouts input)
  checkRawUnitWithProducts scalars (productValues products) pinned prog
  result <- if M.null (productValues products)
    then lowerRepresented False prog ann paramKinds S.empty M.empty scalars
    else do
      lowered <- Products.lowerProducts False pinned prog ann paramKinds S.empty M.empty scalars products primitiveContracts
      checkLoweredProducts False primitiveContracts
        (map (Products.productEntryName pinned products) (rawRoots pinned prog)) lowered
      pure lowered
  pure (M.insert "$arc.mainManaged" ([],CInt 0) result, decls)

-- Only the builtin pipeline, after scheduling decisions, may expose these
-- exact constructor bodies. No effect, entry tick or boundary adapter is
-- copied or dropped. The checked definition establishes eligible nominal ids;
-- the solver still selects each instantiated layout (including boxed ones).
exposeScalarConstructors :: M.Map String Rep -> LayoutTable -> Prog -> Prog
exposeScalarConstructors=exposeConstructors 0

exposeConstructors :: Int -> M.Map String Rep -> LayoutTable -> Prog -> Prog
exposeConstructors capacity evidence layouts input=M.map (\(ps,b)->(ps,walk (S.fromList ps) b)) input
  where
    eligible=S.fromList ([(tid,v) | ScalarLayoutDef tid v _<-M.elems layouts]
      ++ [(tid,v) | shape<-M.elems (productLayouts capacity layouts),let (tid,v,_)=productParts shape])
    stubs=M.mapMaybe (\(ps,b)->case strip b of
      CMk tid v fs | S.member (tid,v) eligible,map strip fs==map CVar ps->Just (tid,v,length ps)
      _->Nothing) input
    strip (CApp (CVar marker) value) | M.member marker evidence=strip value
    strip value=value
    walk bound e=case e of
      CApp {}->case spine e of
        (CVar n,args) | S.notMember n bound,Just (tid,v,arity)<-M.lookup n stubs,arity==length args->
          CMk tid v (map (walk bound) args)
        _->case e of CApp f x->CApp (walk bound f) (walk bound x);_->e
      CLet n a b->CLet n (walk bound a) (walk (S.insert n bound) b)
      CIf c a b->CIf (walk bound c) (walk bound a) (walk bound b)
      CMk t v fs->CMk t v (map (walk bound) fs)
      CProj i x->CProj i (walk bound x)
      CTagEq t v x->CTagEq t v (walk bound x)
      CLam ps b->CLam ps (walk (bound `S.union` S.fromList ps) b)
      _->e

lowerRepresented :: Bool -> Prog -> M.Map Core Kind -> M.Map String [Kind] -> S.Set Core -> M.Map String [Bool] -> M.Map Core (Int,Int) -> Either String Prog
lowerRepresented instrument prog ann paramKinds immortals immortalArgs scalars = evalStateT (M.traverseWithKey lower prog) 0
  where
    managed e = instrument && ann M.! e == Managed
    owned e = managed e && S.notMember e immortals
    rel ns body = if instrument then release ns body else pure body
    ownersFor n ps = [p | (p,k,immortal) <- zip3 ps (paramKinds M.! n) (M.findWithDefault (repeat False) n immortalArgs), k == Managed, not immortal]
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
                  Just RawF64 -> "$arc.F64" ++ if op == "==" then "eq" else "ne"
                  Just RawF32 -> "$arc.F32" ++ if op == "==" then "eq" else "ne"
                  _ -> if op == "==" then "$arc.rawEq" else "$arc.rawNe")
              (op,[a]) | op `elem` ["str","print"], not (managed a) ->
                if M.lookup a ann `elem` [Just RawWord,Just RawAddr]
                  then pure (if op == "str" then "$arc.wordStr" else "$arc.wordPrint")
                  else pure ("$arc." ++ (if M.lookup a ann==Just RawF64 then "F64" else "F32") ++ op)
              _ -> pure adapter
            _ -> failArc ("unsupported primitive or application: " ++ n)
      _ -> failArc "indirect calls and partial applications are not supported yet"
    argsE _ [] k = k []
    argsE env (x:xs) k = eval env x $ \v -> argsE env xs (k . (v:))
    -- Non-tail evaluation supplies exactly one owned value to its continuation.
    eval env expr k = case expr of
      CVar n -> case M.lookup n env of
        Just owner -> if owned expr then bind (call "$arc.retain" [CVar owner]) k else k (CVar owner)
        Nothing | "$sym." `isPrefixOf` n -> k expr -- a link-time address: raw, never owned
        Nothing -> case M.lookup n arities of
          Just 0 -> bind (CVar n) k
          _ -> failArc ("function values or unsupported global: " ++ n)
      CInt _ -> k expr
      CStr _ -> k expr
      CLet x a b -> eval env a $ \v -> do
        owner <- fresh
        body <- eval (M.insert x owner env) b $ \result -> do
          rest <- k result
          rel [owner | owned a] rest
        pure (CLet owner v body)
      CIf c t f -> eval env c $ \cv -> do
        yes <- eval env t pure >>= releaseValue c cv
        no <- eval env f pure >>= releaseValue c cv
        bind (CIf cv yes no) k
      CMk tid variant [field] | Just shape<-M.lookup expr scalars ->
        if shape==(tid,variant) then eval env field k else failArc "scalar constructor disagrees with checked layout"
      CMk tid variant fields -> argsE env fields $ \vs -> bind (CMk tid variant vs) $ \v ->
        if null fields || not instrument then k v else bind (call "$arc.setLayout" [v,CStr [kindTag (ann M.! f) | f <- fields]]) (const (k v))
      CProj i obj | M.member obj scalars ->
        if i==0 then eval env obj k else failArc "scalar projection exceeds checked layout"
      CProj i obj -> eval env obj $ \v ->
        bind (if owned expr then call "$arc.retain" [CProj i v] else CProj i v) $ \r -> k r >>= releaseValue obj v
      CTagEq tid variant obj | Just shape<-M.lookup obj scalars ->
        eval env obj (const (k (CMk 1 (if shape==(tid,variant) then 1 else 0) [])))
      CTagEq tid variant obj -> eval env obj $ \v ->
        bind (CTagEq tid variant v) $ \r -> k r >>= releaseValue obj v
      CApp {} -> let (f,as) = spine expr in do
        n <- target env f as
        argsE env as $ \vs -> bind (call n vs) k
      CErr _ -> pure expr -- panic terminates the whole standalone execution
      CLam {} -> failArc "lambda survived lifting"
    releaseValue original (CVar n) body = rel [n | owned original] body
    releaseValue _ _ body = pure body -- immediate or immortal literal
    -- Keep direct saturated calls in tail position after all owners are dropped.
    tailE env owners expr = case expr of
      CVar n | M.notMember n env, Just 0 <- M.lookup n arities -> rel owners (CVar n)
      CLet x a b -> eval env a $ \v -> do
        owner <- fresh
        body <- tailE (M.insert x owner env) (if owned a then owner:owners else owners) b
        pure (CLet owner v body)
      CIf c t f -> eval env c $ \cv -> do
        yes <- tailE env owners t >>= releaseValue c cv
        no <- tailE env owners f >>= releaseValue c cv
        pure (CIf cv yes no)
      CApp {} -> let (f,as) = spine expr in do
        n <- target env f as
        argsE env as $ \vs -> rel owners (call n vs)
      CErr _ -> pure expr
      _ -> eval env expr $ \v -> rel owners v
