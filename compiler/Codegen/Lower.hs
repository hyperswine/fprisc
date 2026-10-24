{-# LANGUAGE LambdaCase #-}
-- Codegen.Lower: Core -> typed IR for the scalar subset of M1.
--
-- The input is the Core a function has when `Codegen.compileFnBody`
-- receives it: after inlining, fusion, workers, `normIn` and reuse.  The
-- lowering accepts scalar arithmetic, control flow, immutable aggregates,
-- byte strings, generic apply, and runtime value-ABI calls (including floats).
-- Private workers retain their representation signatures and all entries
-- retain their declared stack/fuel obligations.  Everything else is refused
-- with a reason naming the form, and the function stays on the legacy
-- path: an unsupported form is a reported fallback, never a partial IR.
--
-- Evaluation order is the legacy generator's: arguments left to right,
-- each fully evaluated before the next; a branch's arms are their own
-- blocks; a trap happens where its operation is.
module Codegen.Lower (lowerFn, lowerProgram, Reason, Prim (..)) where

import Codegen.IR
import Codegen.Policy
import Codegen.Target.Common (mangleName, functionSymbol)
import Control.Monad (when)
import Control.Monad.Except (ExceptT, catchError, runExceptT, throwError)
import Control.Monad.State.Strict
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import KernelKinds (Kind (..))
import Workers (ScalarSignatures)
import Core.Syntax (Core (..), Prog)

type Reason = String

-- a primitive the unit may name: its arity, the direct C entry a saturated
-- call takes (fpr_prim_fn_<name> for a core primitive, fpr_g_<name>_call<n>
-- for a declared HAL/foreign one of arity up to six; none beyond), and the
-- immortal object its value is (fpr_prim_obj_<name>, fpr_g_<name>; none for
-- the names without one)
data Prim = Prim {primArity :: Int, primEntry :: Maybe String, primObject :: Maybe String}
  deriving (Eq, Show)

data Cur = Cur BId [(VId, Ty)] [Instr] -- instructions reversed

data St = St {stV :: Int, stB :: Int, stCur :: Maybe Cur, stDone :: [Block]}

-- A terminated expression has no value. Keep its closed blocks and prior
-- effects; a lowering refusal still discards the whole function.
type L = ExceptT () (StateT St (Either Reason))

data Cx = Cx
  { cxProg :: Prog,
    cxExt :: M.Map String Int,
    cxHal :: M.Map String Prim, -- the primitives: core and declared HAL names (the legacy generator's `known` and tgtHal tables)
    cxPolicy :: Policy,
    cxSelf :: Name,
    cxEntry :: BId,
    cxEntryTys :: [Ty],
    cxResult :: Ty,
    cxSigs :: M.Map Name ([Ty], Ty) -- the scalar workers' raw conventions
  }

type Env = M.Map Name (VId, Ty)

refuse :: String -> L a
refuse = lift . lift . Left

ended :: L a -> L (Maybe a)
ended action = catchError (Just <$> action) (\() -> pure Nothing)

fresh :: L VId
fresh = do
  n <- gets stV
  modify (\s -> s {stV = n + 1})
  pure (VId n)

freshB :: L BId
freshB = do
  n <- gets stB
  modify (\s -> s {stB = n + 1})
  pure (BId n)

newBlock :: [Ty] -> L (BId, [VId])
newBlock tys = do
  b <- freshB
  vs <- mapM (const fresh) tys
  pure (b, vs)

newBlock1 :: Ty -> L (BId, VId)
newBlock1 t = do
  b <- freshB
  v <- fresh
  pure (b, v)

open :: BId -> [(VId, Ty)] -> L ()
open b ps = do
  cur <- gets stCur
  case cur of
    Nothing -> modify (\s -> s {stCur = Just (Cur b ps [])})
    Just _ -> refuse "internal: a block is already open"

suspend :: L Cur
suspend = do
  cur <- gets stCur
  case cur of
    Just c -> modify (\s -> s {stCur = Nothing}) >> pure c
    Nothing -> refuse "internal: no block to suspend"

resume :: Cur -> L ()
resume c = do
  cur <- gets stCur
  case cur of
    Nothing -> modify (\s -> s {stCur = Just c})
    Just _ -> refuse "internal: a block is already open"

emit :: Ty -> Op -> L VId
emit t op = do
  v <- fresh
  push (Instr (Just (v, t)) op)
  pure v

emitDo :: Op -> L ()
emitDo op = push (Instr Nothing op)

-- the loop region's clock (runtime/fpr.h region_bytes, hart cell 58: directly
-- after the spill cells and stk_lo/stk_span) masked to the tagged Int range;
-- ORegionRoom compares it against a 64 KiB slab (runtime.c FPR_REGION_SLAB)
regionCell :: Int
regionCell = 58
regionMask :: Cx -> Integer
regionMask cx = 2 ^ (wordBits cx - 3) - 1
wordBits :: Cx -> Int
wordBits cx = if policyWidth (cxPolicy cx) == W32 then 32 else 64
regionClock :: Cx -> L VId
regionClock cx = do
  raw <- emit TInt (OHartCell regionCell)
  mask <- emit TInt (OConstInt (regionMask cx))
  emit TInt (OBit BAnd raw mask)

push :: Instr -> L ()
push i = do
  cur <- gets stCur
  case cur of
    Just (Cur b ps is) -> modify (\s -> s {stCur = Just (Cur b ps (i : is))})
    Nothing -> refuse "internal: no open block"

close :: Term -> L ()
close t = do
  cur <- gets stCur
  case cur of
    Just (Cur b ps is) -> modify (\s -> s {stCur = Nothing, stDone = Block b ps (reverse is) t : stDone s})
    Nothing -> refuse "internal: no open block to close"

spineOf :: Core -> (Core, [Core])
spineOf = go []
  where
    go acc (CApp f a) = go (a : acc) f
    go acc f = (f, acc)

arithOps :: M.Map String ArithOp
arithOps = M.fromList [("+", Add), ("-", Sub), ("*", Mul), ("/", Div)]

cmpOps :: M.Map String CmpOp
cmpOps = M.fromList [("<", Lt), (">", Gt), ("<=", Le), (">=", Ge), ("==", Eq), ("!=", Ne)]

-- an F64 operation or literal the value lowering expands inline: in tail
-- position too it is a value, never a tail call of the C entry
inlineFloat :: Cx -> Env -> Name -> [Core] -> Bool
inlineFloat cx env h args =
  isPrim cx env h && ((policyWidth (cxPolicy cx) == W32 && literal)
    || (polFloatInline (cxPolicy cx) && policyWidth (cxPolicy cx) == W64 && case args of
      [CInt _, CInt _] | h == "f64frombits" -> True
      [CInt _] | h == "f32frombits" -> True
      [_, _] -> M.member h floatBinOps || M.member h floatCmpOps || M.member h float32BinOps || M.member h float32CmpOps
      _ -> False))
  where literal = case (h,args) of
          ("f64frombits",[CInt _,CInt _]) -> True
          ("f32frombits",[CInt _]) -> True
          _ -> False

-- the F64 operators the legacy generator expands inline on the 64-bit word
floatBinOps :: M.Map String FloatOp
floatBinOps = M.fromList [("F64.+", FAdd), ("F64.-", FSub), ("F64.*", FMul), ("F64./", FDiv)]

floatCmpOps :: M.Map String CmpOp
floatCmpOps = M.fromList [("F64.<", Lt), ("F64.>", Gt), ("F64.<=", Le), ("F64.>=", Ge), ("F64.==", Eq), ("F64.!=", Ne)]

-- the F32 operators the legacy unboxed clones expand inline (fmv.w.x, fadd.s ...)
float32BinOps :: M.Map String FloatOp
float32BinOps = M.fromList [("F32.+", FAdd), ("F32.-", FSub), ("F32.*", FMul), ("F32./", FDiv)]

float32CmpOps :: M.Map String CmpOp
float32CmpOps = M.fromList [("F32.<", Lt), ("F32.>", Gt), ("F32.<=", Le), ("F32.>=", Ge), ("F32.==", Eq), ("F32.!=", Ne)]

-- the bitwise primitives the legacy inline table expands (runtime/bits.c);
-- a declared HAL name of arity two, never shadowed, is the operation
bitOps :: M.Map String BitOp
bitOps = M.fromList [(bitName o, o) | o <- [minBound .. maxBound]]

shiftOps :: M.Map String ShiftOp
shiftOps = M.fromList [(shiftName o, o) | o <- [minBound .. maxBound]]

workerPrefix :: String
workerPrefix = "$worker.scalar."

scalarPrefix :: String
scalarPrefix = "$scalar."

-- The producer's ordered signatures survive normalization and reuse.
-- Unsupported kinds remain absent, causing explicit worker fallback.
-- The policy says which profile's entry sequence the IR states; a profile
-- M2 does not implement refuses every function by name (Codegen.Policy).
-- `prog` is the whole program the unit was compiled from, for lookups (a
-- nullary constructor or a callee elided from this unit because a shared
-- unit emits it is still known, as the legacy generator knows it);
-- `emitted` are the functions this unit emits, the ones lowered.
lowerProgram :: Policy -> ScalarSignatures -> Prog -> Prog -> M.Map String Int -> M.Map String Prim -> (Program, [(Name, Reason)])
lowerProgram policy workerSigs prog emitted ext hal =
  let sigs = M.mapMaybe convert workerSigs
      convert (ps, r) = (,) <$> traverse kindTy ps <*> kindTy r
      kindTy KI = Just TInt
      kindTy KB = Just TVal
      kindTy _ = Nothing
      results = case validatePolicy policy of
        Left why -> [(n, Left why) | n <- M.keys emitted]
        Right () -> [(n, lowerFn policy sigs prog ext hal n def) | (n, def) <- M.toList emitted]
   in (M.fromList [(n, f) | (n, Right f) <- results], [(n, r) | (n, Left r) <- results])

lowerFn :: Policy -> M.Map Name ([Ty], Ty) -> Prog -> M.Map String Int -> M.Map String Prim -> Name -> ([Name], Core) -> Either Reason Fn
lowerFn policy sigs prog ext hal name (params, body)
  | Left why <- validatePolicy policy = Left why
  | length params > arityCeiling = Left ("arity above " ++ show arityCeiling ++ " (eight registers and the hart spill cells)")
  | workerPrefix `isPrefixOf` name, M.notMember name sigs = Left "a scalar worker without representation metadata"
  | length ptys /= length params = Left "worker representation metadata has the wrong arity"
  | otherwise = do
      result <- evalStateT (runExceptT go) (St 0 0 Nothing [])
      either (const (Left "internal: uncaught terminated function")) Right result
  where
    (ptys, rty) = M.findWithDefault (map (const TVal) params, TVal) name sigs
    go = do
      pvs <- mapM (const fresh) params
      entry <- freshB
      open entry (zip pvs ptys)
      -- the entry sequence the policy states: the headroom check, then the
      -- fuel tick, both after the parameters are the entry's values
      -- Keep the obligation explicit until native frame layout can prove
      -- the shallow-entry exemption. Lowering cannot know the frame size.
      when (polStackCheck policy /= StackStatic) (emitDo OStackCheck)
      when (polFuel policy) (emitDo OSafepoint)
      let cx = Cx prog ext hal policy name entry ptys rty sigs
          env = M.fromList (zip params (zip pvs ptys))
      lowerTail cx env body
      blocks <- gets (reverse . stDone)
      pure Fn {fnName = name, fnSourceParams = params, fnResult = rty, fnEntry = entry, fnBlocks = blocks}

-- the convention of a known callee
calleeOf :: Cx -> Name -> Int -> Maybe Callee
calleeOf cx h n
  | n > arityCeiling = Nothing -- no convention beyond the spill cells; refused as an over-saturated application
  | workerPrefix `isPrefixOf` h, M.notMember h (cxSigs cx) = Nothing
  | Just (pts, _) <- M.lookup h (cxSigs cx), length pts /= n = Nothing
  | Just (ps, _) <- M.lookup h (cxProg cx), length ps == n =
      let (pts, r) = M.findWithDefault (map (const TVal) ps, TVal) h (cxSigs cx)
       in Just (Callee h Local pts r)
  -- Ownership lowering introduces a closed set of consuming C adapters.
  -- Local source definitions still win; these calls have runtime costs,
  -- and never become generated-code fuel boundaries.
  | polProfile (cxPolicy cx) == BuiltinArc, "$arc." `isPrefixOf` h,
    Just a <- M.lookup h (cxExt cx), a == n =
      Just (Callee h (Foreign (functionSymbol h)) (replicate n TVal) TVal)
  | Just a <- M.lookup h (cxExt cx), a == n = Just (Callee h Imported (replicate n TVal) TVal)
  -- a primitive with a direct C entry: the legacy generator's
  -- `call fpr_prim_fn_<name>` for a core primitive and `call
  -- fpr_g_<name>_call<n>` for a declared HAL/foreign one (Codegen.genT:
  -- `known` and the tgtHal case); the names with inline expansions
  -- ($arc.*, $scalar.*, the integer operators) are not calls there and stay
  -- refused here
  | M.notMember h (cxProg cx), Just (Prim a (Just sym) _) <- M.lookup h (cxHal cx), a == n, kernelPrefix `isPrefixOf` h = Just (Callee h (Generated sym) (replicate n TVal) TVal)
  -- Private indexed accesses are checked C entries in the manual builtin
  -- runtime, produced only after the address-identity proof in Codegen.
  | polProfile (cxPolicy cx) `elem` [Builtin,Builtin32], "$mem." `isPrefixOf` h,
    M.notMember h (cxProg cx), Just (Prim a (Just sym) _) <- M.lookup h (cxHal cx), a == n =
      Just (Callee h (Foreign sym) (replicate n TVal) TVal)
  | M.notMember h (cxProg cx), Just (Prim a (Just sym) _) <- M.lookup h (cxHal cx), a == n, foreignName h = Just (Callee h (Foreign sym) (replicate n TVal) TVal)
  | otherwise = Nothing

-- a vector-specialisation site the native selector rewrote into a call of
-- its legacy-emitted kernel (Codegen.nativeSelect); the kernel takes and
-- returns tagged words in the generated-code ABI
kernelPrefix :: String
kernelPrefix = "$vkernel:"

foreignName :: Name -> Bool
foreignName h = not (any (`isPrefixOf` h) expanded) && h `notElem` inlined
  where
    -- the families the legacy generator expands in place or routes
    -- elsewhere (their slow paths and guards are its own, not a C call):
    -- the builtin adapters, the scalar workers' raw forms, the indexed
    -- memory forms, link-time symbols and the inlined entry tick. F64/F32 use the declared runtime V ABI, not raw FP registers.
    -- A `$`-name outside them ($receiveLoop, $vec.at/get/len)
    -- is a direct C entry in both generators
    expanded = ["$arc.", "$scalar.", "$mem.", "$sym.", "$fuel"]
    -- the plain names Codegen.inlineTable expands in place
    inlined = ["+", "-", "*", "/", "<", ">", "<=", ">=", "==", "!=", "charAt", "strlen", "band", "bor", "bxor", "BITSHIFTL", "BITSHIFTR"]

-- a head is a primitive only when nothing shadows it
isPrim :: Cx -> Env -> Name -> Bool
isPrim cx env h = M.notMember h env && M.notMember h (cxProg cx) && M.notMember h (cxExt cx)

coerce :: (VId, Ty) -> Ty -> L VId
coerce (v, t) want
  | t == want = pure v
  | otherwise = case (t, want) of
      (TInt, TVal) -> emit TVal (OTag v)
      (TPred, TVal) -> emit TVal (OBoolOf v)
      (TVal, TInt) -> emit TInt (OUntag v)
      (TVal, TPred) -> emit TPred (OTruth v)
      _ -> refuse ("a " ++ show t ++ " where a " ++ show want ++ " is needed")

asVal, asInt, asPred :: (VId, Ty) -> L VId
asVal x = coerce x TVal
asInt x = coerce x TInt
asPred x = coerce x TPred

-- the join type of two arms
unify :: Ty -> Ty -> Ty
unify a b
  | a == b = a
  | otherwise = TVal

-- tail position: the expression is the function's result
lowerTail :: Cx -> Env -> Core -> L ()
lowerTail cx env expr = ended (go expr) >> pure ()
 where
  go = \case
    CLet x a b -> lowerBind cx env x a >>= \env' -> lowerTail cx env' b
    CIf c t f -> do
      p <- lowerCond cx env c
      (bt, _) <- newBlock []
      (bf, _) <- newBlock []
      close (TCondBr p bt [] bf [])
      open bt [] >> lowerTail cx env t
      open bf [] >> lowerTail cx env f
    -- a dead arm: exhaustiveness proved it unreachable; the legacy generator
    -- emits the trap there (`la a0, <str>; call fpr_panic`) and so does the IR
    CErr msg -> close (TUnreachable msg)
    CVar h | polProfile (cxPolicy cx) == BuiltinArc,
      not (case M.lookup h (cxProg cx) of Just ([],CMk _ _ []) -> True; _ -> False),
      M.notMember h env, Just c <- calleeOf cx h 0 ->
      if h == cxSelf cx then close (TBr (cxEntry cx) [])
      else close (TTailCall c [])
    e
      | (CVar h, args@(_ : _)) <- spineOf e,
        M.notMember h env,
        not (inlineFloat cx env h args),
        Just c <- calleeOf cx h (length args) -> do
          as <- mapM (lowerVal cx env) args
          if h == cxSelf cx
            then do
              as' <- mapM (uncurry coerce) (zip as (cxEntryTys cx))
              close (TBr (cxEntry cx) as')
            else do
              when (calleeResult c /= cxResult cx) $ refuse ("a tail call to " ++ h ++ " answers " ++ show (calleeResult c) ++ ", this function " ++ show (cxResult cx))
              as' <- mapM (uncurry coerce) (zip as (calleeParams c))
              close (TTailCall c as')
      | otherwise -> do
          r <- lowerVal cx env e
          v <- coerce r (cxResult cx)
          close (TRet v)

-- a let binder: a local alias shares the value; anything else is lowered
lowerBind :: Cx -> Env -> Name -> Core -> L Env
lowerBind cx env x a = case a of
  CVar y | Just b <- M.lookup y env -> pure (M.insert x b env)
  _ -> do
    r <- lowerVal cx env a
    pure (M.insert x r env)

-- an arm of a branch in value position: a dead arm (CErr, after its lets)
-- closes the block with the unreachable terminator and yields no value
lowerArm :: Cx -> Env -> Core -> L (Maybe (VId, Ty))
lowerArm cx env e = ended (lowerVal cx env e)

-- condition position: a predicate
lowerCond :: Cx -> Env -> Core -> L VId
lowerCond cx env = \case
  CTagEq 1 1 c -> lowerCond cx env c
  CTagEq 1 0 c -> lowerCond cx env c >>= \p -> emit TPred (ONot p)
  CLet x a b -> lowerBind cx env x a >>= \env' -> lowerCond cx env' b
  e -> lowerVal cx env e >>= asPred

-- value position: the natural representation of the expression
lowerVal :: Cx -> Env -> Core -> L (VId, Ty)
lowerVal cx env = \case
  CVar x
    | Just r <- M.lookup x env -> pure r
    | polProfile (cxPolicy cx) == BuiltinArc, "$sym." `isPrefixOf` x -> symbolValue (drop 5 x)
    | Just ([], CMk t v []) <- M.lookup x (cxProg cx) -> nullary t v
    -- a nullary definition is evaluated by a call (the legacy `call fpr_fn_<x>`)
    | Just ([], _) <- M.lookup x (cxProg cx) -> callValue (Callee x Local [] TVal)
    | Just 0 <- M.lookup x (cxExt cx) -> callValue (Callee x Imported [] TVal)
    -- a function value is its static PAP (`la a0, fpr_obj_<x>`); a private
    -- worker has none (Codegen.objFor)
    | M.member x (cxProg cx) || M.member x (cxExt cx) ->
        if workerPrefix `isPrefixOf` x || "$worker." `isPrefixOf` x
          then refuse ("the function value of the private worker `" ++ x ++ "`")
          else (\v -> (v, TVal)) <$> emit TVal (OFunValue x)
    -- a core primitive's object or a declared HAL contract (`la a0,
    -- fpr_prim_obj_<x>` / `la a0, fpr_g_<x>`); other names have no object
    | Just (Prim _ _ (Just sym)) <- M.lookup x (cxHal cx) -> symbolValue sym
    | otherwise -> refuse ("the primitive or HAL value `" ++ x ++ "`")
  CInt n
    | intFitsWidth (policyWidth (cxPolicy cx)) n -> (\v -> (v, TInt)) <$> emit TInt (OConstInt n)
    | otherwise -> refuse ("the literal " ++ show n ++ " does not fit an Int")
  CStr s -> (\v -> (v, TVal)) <$> emit TVal (OString s)
  CMk t v [] -> nullary t v
  CMk tid variant fs -> do
    fields <- mapM (\e -> lowerVal cx env e >>= asVal) fs
    v <- emit TVal (OMake tid variant fields)
    pure (v, TVal)
  -- a fresh constructor over a uniquely owned one (Reuse.reuseFresh; the
  -- legacy `# reuse fresh constructor`): every field first, then the stores
  CApp (CApp (CVar "$reuse.fresh") (CVar x)) (CMk tid variant fs@(_ : _))
    | Just root <- M.lookup x env -> do
        fields <- mapM (\e -> lowerVal cx env e >>= asVal) fs
        r <- asVal root
        v <- emit TVal (OReuse tid variant r fields)
        pure (v, TVal)
  CProj index obj -> do
    value <- lowerVal cx env obj >>= asVal
    v <- emit TVal (OField index value)
    pure (v, TVal)
  CLam _ _ -> refuse "a lambda"
  CErr msg -> close (TUnreachable msg) >> throwError ()
  CTagEq 1 1 c -> (\p -> (p, TPred)) <$> lowerCond cx env c
  CTagEq 1 0 c -> (\p -> (p, TPred)) <$> lowerCond cx env (CTagEq 1 0 c)
  CTagEq t v c -> do
    x <- lowerVal cx env c >>= asVal
    p <- emit TPred (OTagTest t v x)
    pure (p, TPred)
  CLet x a b -> lowerBind cx env x a >>= \env' -> lowerVal cx env' b
  CIf c t f -> do
    p <- lowerCond cx env c
    (bt, _) <- newBlock []
    (bf, _) <- newBlock []
    close (TCondBr p bt [] bf [])
    open bt []
    rt <- lowerArm cx env t
    st <- traverse (const suspend) rt
    open bf []
    rf <- lowerArm cx env f
    sf <- traverse (const suspend) rf
    case (rt, rf, st, sf) of
      -- a dead arm closed its block with the trap: the live arm's block
      -- simply continues, no join is needed
      (Just r, Nothing, Just c', _) -> resume c' >> pure r
      (Nothing, Just r, _, Just c') -> resume c' >> pure r
      (Just r1, Just r2, Just c1, Just c2) -> do
        let jty = unify (snd r1) (snd r2)
        (bj, vj) <- newBlock1 jty
        resume c1
        vt <- coerce r1 jty
        close (TBr bj [vt])
        resume c2
        vf <- coerce r2 jty
        close (TBr bj [vf])
        open bj [(vj, jty)]
        pure (vj, jty)
      (Nothing, Nothing, _, _) -> throwError ()
      _ -> refuse "internal: inconsistent branch termination"
  e@(CApp _ _) -> case spineOf e of
    (CVar h, args)
      -- a local head: the generic application through the runtime
      | Just r <- M.lookup h env -> applyGeneric r args
      | workerPrefix `isPrefixOf` h, M.notMember h (cxSigs cx) ->
          refuse ("call to scalar worker `" ++ h ++ "` without representation metadata")
      | Just (pts, _) <- M.lookup h (cxSigs cx), length pts /= length args ->
          refuse ("call to scalar worker `" ++ h ++ "` whose representation metadata has the wrong arity")
      -- tagged Int arithmetic and comparison (the base profile's operators)
      | isPrim cx env h, Just o <- M.lookup h arithOps, [a, b] <- args -> arith o a b
      | isPrim cx env h, Just o <- M.lookup h cmpOps, [a, b] <- args -> compare' o a b
      -- the bitwise primitives and the shifts: declared HAL names of arity
      -- two (Codegen.inlineTable band/bor/bxor/BITSHIFTL/BITSHIFTR; their
      -- slow path is the fpr_g_<name>_call2 entry, which traps by name)
      | isPrim cx env h, Just o <- M.lookup h bitOps, [a, b] <- args, Just (Prim 2 _ _) <- M.lookup h (cxHal cx) -> do
          x <- lowerVal cx env a >>= asInt
          y <- lowerVal cx env b >>= asInt
          v <- emit TInt (OBit o x y)
          pure (v, TInt)
      | isPrim cx env h, Just o <- M.lookup h shiftOps, [a, b] <- args, Just (Prim 2 _ _) <- M.lookup h (cxHal cx) -> do
          x <- lowerVal cx env a >>= asInt
          y <- lowerVal cx env b >>= asInt
          v <- emit TInt (OShift o x y)
          pure (v, TInt)
      -- F64 + - * / and comparisons on the 64-bit word: inline, as the
      -- legacy inline table does (Codegen.inlineTable floatBin/floatCmp);
      -- the values stay IEEE bits in TVal, nothing new crosses a call
      -- an F64 literal: its bits, as the legacy generator splices them
      -- (Codegen.floatLitBits), instead of a runtime f64frombits call
      | isPrim cx env h, policyWidth (cxPolicy cx) == W32,
        h == "f64frombits", [CInt hi, CInt lo] <- args -> boxedFloat W64 (hi*4294967296 + lo `mod` 4294967296)
      | isPrim cx env h, policyWidth (cxPolicy cx) == W32,
        h == "f32frombits", [CInt bits] <- args -> boxedFloat W32 bits
      | isPrim cx env h, h == "f64frombits", polFloatInline (cxPolicy cx), policyWidth (cxPolicy cx) == W64,
        [CInt hi, CInt lo] <- args -> do
          let bits = ((hi * 4294967296) + (lo `mod` 4294967296)) `mod` (2 ^ (64 :: Int))
              signed = if bits >= 2 ^ (63 :: Int) then bits - 2 ^ (64 :: Int) else bits
          v <- emit TVal (OBits signed)
          pure (v, TVal)
      | isPrim cx env h, polFloatInline (cxPolicy cx), policyWidth (cxPolicy cx) == W64,
        Just o <- M.lookup h floatBinOps, [a, b] <- args -> do
          x <- lowerVal cx env a >>= asVal
          y <- lowerVal cx env b >>= asVal
          v <- emit TVal (OFloatBin o x y)
          pure (v, TVal)
      | isPrim cx env h, polFloatInline (cxPolicy cx), policyWidth (cxPolicy cx) == W64,
        Just o <- M.lookup h floatCmpOps, [a, b] <- args -> do
          x <- lowerVal cx env a >>= asVal
          y <- lowerVal cx env b >>= asVal
          p <- emit TPred (OFloatCmp o x y)
          pure (p, TPred)
      -- an F32 literal is its 32 bits in the word (Codegen.floatLitBits: `li` of the bits)
      | isPrim cx env h, h == "f32frombits", polFloatInline (cxPolicy cx), policyWidth (cxPolicy cx) == W64,
        [CInt b] <- args -> do
          v <- emit TVal (OBits (b `mod` (2 ^ (32 :: Int))))
          pure (v, TVal)
      | isPrim cx env h, polFloatInline (cxPolicy cx), policyWidth (cxPolicy cx) == W64,
        Just o <- M.lookup h float32BinOps, [a, b] <- args -> do
          x <- lowerVal cx env a >>= asVal
          y <- lowerVal cx env b >>= asVal
          v <- emit TVal (OFloat32Bin o x y)
          pure (v, TVal)
      | isPrim cx env h, polFloatInline (cxPolicy cx), policyWidth (cxPolicy cx) == W64,
        Just o <- M.lookup h float32CmpOps, [a, b] <- args -> do
          x <- lowerVal cx env a >>= asVal
          y <- lowerVal cx env b >>= asVal
          p <- emit TPred (OFloat32Cmp o x y)
          pure (p, TPred)
      | isPrim cx env h, h == "strlen", [a] <- args, Just (Prim 1 _ _) <- M.lookup h (cxHal cx) -> do
          str <- lowerVal cx env a >>= asVal
          v <- emit TInt (OStrLen str)
          pure (v, TInt)
      | isPrim cx env h, h == "charAt", [a, b] <- args, Just (Prim 2 _ _) <- M.lookup h (cxHal cx) -> do
          str <- lowerVal cx env a >>= asVal
          index <- lowerVal cx env b >>= asInt
          v <- emit TInt (OCharAt str index)
          pure (v, TInt)
      -- the raw forms of the scalar workers
      | isPrim cx env h, h == scalarPrefix ++ "unbox", [a] <- args -> lowerVal cx env a >>= asInt >>= \v -> pure (v, TInt)
      | isPrim cx env h, h == scalarPrefix ++ "box", [a] <- args -> lowerVal cx env a >>= asVal >>= \v -> pure (v, TVal)
      | isPrim cx env h, h == scalarPrefix ++ "isInt", [a] <- args -> do
          x <- lowerVal cx env a >>= asVal
          p <- emit TPred (OIsInt x)
          pure (p, TPred)
      | isPrim cx env h, scalarPrefix `isPrefixOf` h, Just o <- M.lookup (drop (length scalarPrefix) h) arithOps, [a, b] <- args -> arith o a b
      | isPrim cx env h, scalarPrefix `isPrefixOf` h, Just o <- M.lookup (drop (length scalarPrefix) h) cmpOps, [a, b] <- args -> compare' o a b
      -- an inlined callee's entry safepoint (Inline.hs); its value is Unit
      | h == "$fuel", [_] <- args -> when (polFuel (cxPolicy cx)) (emitDo OSafepoint) >> nullary 0 0
      -- a loop region's mark and back-edge test (docs/2026-10-25-REGIONS-LOOPS-CALLS.md):
      -- the hart's allocation clock is one hart-cell load; the test is a mask,
      -- a subtraction that cannot overflow (both sides lie in [0, mask]) and a
      -- compare against the region's slab.  No call: a hot loop pays three
      -- or four instructions an iteration.  runtime.c REGION_MASK and
      -- FPR_REGION_SLAB are the same numbers.
      | h == "$regionMark", [_] <- args, M.notMember h env -> do
          now <- regionClock cx
          pure (now, TInt)
      | h == "$regionRoom", [m] <- args, M.notMember h env -> do
          mark <- lowerVal cx env m >>= asVal -- tagged: the target untags it in the test
          p <- emit TPred (ORegionRoom mark)
          pure (p, TPred)
      -- a saturated known call
      | M.notMember h env, Just c <- calleeOf cx h (length args) -> do
          as <- mapM (lowerVal cx env) args
          as' <- mapM (uncurry coerce) (zip as (calleeParams c))
          v <- emit (calleeResult c) (OCall c as')
          pure (v, calleeResult c)
      -- a partial or over-saturated application of a known function: the
      -- legacy generator stages the whole spine for one fpr_applyN
      | M.member h (cxProg cx) || M.member h (cxExt cx) -> lowerVal cx env (CVar h) >>= \r -> applyGeneric r args
      -- HAL declarations may deliberately hide the runtime arity (QOS uses
      -- a -> b for Sys.storeReq/bindStore). A partial or over-saturated
      -- primitive therefore applies its actual PAP, just as the legacy
      -- generator does, rather than guessing a direct _call<n> entry.
      | Just (Prim ar _ (Just _)) <- M.lookup h (cxHal cx),
        ar <= arityCeiling, length args <= arityCeiling ->
          lowerVal cx env (CVar h) >>= \r -> applyGeneric r args
      | otherwise -> refuse ("the primitive `" ++ h ++ "`")
    -- a computed head (a branch, a let, an application answering a function)
    (hd, args) -> lowerVal cx env hd >>= \r -> applyGeneric r args
  where
    nullary t v = (\x -> (x, TVal)) <$> emit TVal (ONullary t v)
    callValue c = (\x -> (x, TVal)) <$> emit TVal (OCall c [])
    -- fpr_applyN over the head and every argument as tagged words, the
    -- arguments evaluated left to right after the head (Codegen.genT's
    -- generic CApp case)
    applyGeneric hd args = do
      f <- asVal hd
      as <- mapM (\a -> lowerVal cx env a >>= asVal) args
      v <- emit TVal (OApply f as)
      pure (v, TVal)
    symbolValue sym = (\x -> (x, TVal)) <$> emit TVal (OSymbol sym)
    boxedFloat width bits = (\x -> (x,TVal)) <$> emit TVal (OBoxedFloat width (bits `mod` (2 ^ widthBits width)))
    arith o a b = do
      x <- lowerVal cx env a >>= asInt
      y <- lowerVal cx env b >>= asInt
      v <- emit TInt (OArith o x y)
      pure (v, TInt)
    -- an ordering is Int by typing; == and != are deep unless both sides are already Ints
    compare' o a b = do
      ra <- lowerVal cx env a
      rb <- lowerVal cx env b
      p <- case (o, snd ra, snd rb) of
        (Eq, ta, tb) | ta /= TInt || tb /= TInt -> deep True ra rb
        (Ne, ta, tb) | ta /= TInt || tb /= TInt -> deep False ra rb
        _ -> do
          x <- asInt ra
          y <- asInt rb
          emit TPred (OCmp o x y)
      pure (p, TPred)
    deep eq ra rb = do
      x <- asVal ra
      y <- asVal rb
      emit TPred (OEqVal eq x y)
