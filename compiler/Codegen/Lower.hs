{-# LANGUAGE LambdaCase #-}
-- Codegen.Lower: Core -> typed IR for the scalar subset of M1.
--
-- The input is the Core a function has when `Codegen.compileFnBody`
-- receives it: after inlining, fusion, workers, `normIn` and reuse.  The
-- lowering accepts Int arithmetic and comparison (tagged, and the raw
-- `$scalar.*` forms of the private workers), let, if, Bool tag tests,
-- nullary constructors, saturated known calls, tail calls and self tail
-- calls, and the inlined entry safepoint.  Everything else is refused
-- with a reason naming the form, and the function stays on the legacy
-- path: an unsupported form is a reported fallback, never a partial IR.
--
-- Evaluation order is the legacy generator's: arguments left to right,
-- each fully evaluated before the next; a branch's arms are their own
-- blocks; a trap happens where its operation is.
module Codegen.Lower (lowerFn, lowerProgram, workerSignatures, Reason) where

import Codegen.IR
import Control.Monad (when)
import Control.Monad.State.Strict
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC (Core (..), Prog)

type Reason = String

data Cur = Cur BId [(VId, Ty)] [Instr] -- instructions reversed

data St = St {stV :: Int, stB :: Int, stCur :: Maybe Cur, stDone :: [Block]}

type L = StateT St (Either Reason)

data Cx = Cx
  { cxProg :: Prog,
    cxExt :: M.Map String Int,
    cxSelf :: Name,
    cxEntry :: BId,
    cxEntryTys :: [Ty],
    cxResult :: Ty,
    cxSigs :: M.Map Name ([Ty], Ty) -- the scalar workers' raw conventions
  }

type Env = M.Map Name (VId, Ty)

refuse :: String -> L a
refuse = lift . Left

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

workerPrefix :: String
workerPrefix = "$worker.scalar."

scalarPrefix :: String
scalarPrefix = "$scalar."

-- ---------------------------------------------------------------------
-- The scalar workers' conventions.  A worker (Workers.scalarWorkers)
-- takes each Int parameter as a raw word and each Bool as the ordinary
-- immutable object, and answers a raw word or a Bool object.  The kinds
-- are recovered from the worker bodies: an operand of a `$scalar.`
-- operation is an Int, a tag-tested or branched-on parameter is a Bool,
-- an argument to another worker has that parameter's kind, to a
-- fixpoint.  A worker with a parameter or result left undetermined gets
-- no signature and is refused.

data K = KInt | KBool deriving (Eq, Show)

workerSignatures :: Prog -> M.Map Name ([Ty], Ty)
workerSignatures prog = M.mapMaybe finish (iterateFix step start)
  where
    workers = M.filterWithKey (\n _ -> workerPrefix `isPrefixOf` n) prog
    start = M.map (\(ps, _) -> (M.fromList [(p, Nothing) | p <- ps], Nothing)) workers
    iterateFix f x = let x' = f x in if x' == x then x else iterateFix f x'
    step sol = M.mapWithKey (stepOne sol) sol
    stepOne sol n (pk, rk) =
      let (ps, b) = workers M.! n
          pk' = foldr (\(p, k) m -> M.insertWith merge p k m) pk (demands sol (S.fromList ps) b)
       in (pk', merge rk (resultKind sol pk' b))
    merge (Just a) (Just b) | a /= b = Nothing -- a conflict: left undetermined, refused later
    merge a b = maybe b Just a
    finish (pk, rk) = do
      ps <- mapM (\k -> ty <$> k) (M.elems pk)
      r <- ty <$> rk
      pure (ps, r)
    ty KInt = TInt
    ty KBool = TVal
    -- (parameter, kind) facts from one body
    demands sol ps e = case spineOf e of
      (CVar h, args@(_ : _))
        | scalarPrefix `isPrefixOf` h, h `notElem` [scalarPrefix ++ "unbox", scalarPrefix ++ "box", scalarPrefix ++ "isInt"] ->
            [(p, Just KInt) | CVar p <- args, S.member p ps] ++ concatMap (demands sol ps) args
        | Just (pk, _) <- M.lookup h sol, Just (wps, _) <- M.lookup h workers ->
            [(p, M.findWithDefault Nothing wp pk) | (CVar p, wp) <- zip args wps, S.member p ps] ++ concatMap (demands sol ps) args
        | otherwise -> concatMap (demands sol ps) args
      _ -> case e of
        CTagEq 1 _ (CVar p) | S.member p ps -> [(p, Just KBool)]
        CTagEq _ _ x -> demands sol ps x
        CIf (CVar p) t f | S.member p ps -> (p, Just KBool) : concatMap (demands sol ps) [t, f]
        CIf c t f -> concatMap (demands sol ps) [c, t, f]
        CLet x a b -> demands sol ps a ++ demands sol (S.delete x ps) b
        CApp f a -> demands sol ps f ++ demands sol ps a
        _ -> []
    resultKind sol pk = \case
      CLet _ _ b -> resultKind sol pk b
      CIf _ t f -> case (resultKind sol pk t, resultKind sol pk f) of
        (Just a, Just b) | a == b -> Just a
        (Just a, Nothing) -> Just a
        (Nothing, b) -> b
        _ -> Nothing
      CTagEq _ _ _ -> Just KBool
      CMk 1 _ [] -> Just KBool
      CVar p -> M.findWithDefault Nothing p pk
      e -> case spineOf e of
        (CVar h, _ : _)
          | h == scalarPrefix ++ "unbox" -> Just KInt
          | scalarPrefix `isPrefixOf` h, Just _ <- M.lookup (drop (length scalarPrefix) h) arithOps -> Just KInt
          | scalarPrefix `isPrefixOf` h, Just _ <- M.lookup (drop (length scalarPrefix) h) cmpOps -> Just KBool
          | Just (_, rk) <- M.lookup h sol -> rk
        _ -> Nothing

-- ---------------------------------------------------------------------

lowerProgram :: Prog -> M.Map String Int -> (Program, [(Name, Reason)])
lowerProgram prog ext =
  let sigs = workerSignatures prog
      results = [(n, lowerFn sigs prog ext n def) | (n, def) <- M.toList prog]
   in (M.fromList [(n, f) | (n, Right f) <- results], [(n, r) | (n, Left r) <- results])

lowerFn :: M.Map Name ([Ty], Ty) -> Prog -> M.Map String Int -> Name -> ([Name], Core) -> Either Reason Fn
lowerFn sigs prog ext name (params, body)
  | length params > 8 = Left "arity above 8 (parameters through the hart spill cells)"
  | workerPrefix `isPrefixOf` name, M.notMember name sigs = Left "a scalar worker whose convention was not determined"
  | otherwise = evalStateT go (St 0 0 Nothing [])
  where
    (ptys, rty) = M.findWithDefault (map (const TVal) params, TVal) name sigs
    go = do
      pvs <- mapM (const fresh) params
      entry <- freshB
      open entry (zip pvs ptys)
      emitDo OStackCheck
      emitDo OSafepoint
      let cx = Cx prog ext name entry ptys rty sigs
          env = M.fromList (zip params (zip pvs ptys))
      lowerTail cx env body
      blocks <- gets (reverse . stDone)
      pure Fn {fnName = name, fnSourceParams = params, fnResult = rty, fnEntry = entry, fnBlocks = blocks}

-- the convention of a known callee
calleeOf :: Cx -> Name -> Int -> Maybe Callee
calleeOf cx h n
  | Just (ps, _) <- M.lookup h (cxProg cx), length ps == n =
      let (pts, r) = M.findWithDefault (map (const TVal) ps, TVal) h (cxSigs cx)
       in Just (Callee h Local pts r)
  | Just a <- M.lookup h (cxExt cx), a == n = Just (Callee h Imported (replicate n TVal) TVal)
  | otherwise = Nothing

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
lowerTail cx env = \case
  CLet x a b -> lowerBind cx env x a >>= \env' -> lowerTail cx env' b
  CIf c t f -> do
    p <- lowerCond cx env c
    (bt, _) <- newBlock []
    (bf, _) <- newBlock []
    close (TCondBr p bt [] bf [])
    open bt [] >> lowerTail cx env t
    open bf [] >> lowerTail cx env f
  e
    | (CVar h, args@(_ : _)) <- spineOf e,
      M.notMember h env,
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
    | Just ([], CMk t v []) <- M.lookup x (cxProg cx) -> nullary t v
    | Just ([], _) <- M.lookup x (cxProg cx) -> refuse ("the CAF `" ++ x ++ "`")
    | M.member x (cxProg cx) || M.member x (cxExt cx) -> refuse ("the function value `" ++ x ++ "`")
    | otherwise -> refuse ("the primitive or HAL value `" ++ x ++ "`")
  CInt n
    | intFits64 n -> (\v -> (v, TInt)) <$> emit TInt (OConstInt n)
    | otherwise -> refuse ("the literal " ++ show n ++ " does not fit an Int")
  CStr _ -> refuse "a string literal"
  CMk t v [] -> nullary t v
  CMk _ _ _ -> refuse "a constructor with fields"
  CProj _ _ -> refuse "a field projection"
  CLam _ _ -> refuse "a lambda"
  CErr _ -> refuse "a dead arm (CErr)"
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
    rt <- lowerVal cx env t
    st <- suspend
    open bf []
    rf <- lowerVal cx env f
    sf <- suspend
    let jty = unify (snd rt) (snd rf)
    (bj, vj) <- newBlock1 jty
    resume st
    vt <- coerce rt jty
    close (TBr bj [vt])
    resume sf
    vf <- coerce rf jty
    close (TBr bj [vf])
    open bj [(vj, jty)]
    pure (vj, jty)
  e@(CApp _ _) -> case spineOf e of
    (CVar h, args)
      | M.member h env -> refuse ("an application of the local `" ++ h ++ "`")
      -- tagged Int arithmetic and comparison (the base profile's operators)
      | isPrim cx env h, Just o <- M.lookup h arithOps, [a, b] <- args -> arith o a b
      | isPrim cx env h, Just o <- M.lookup h cmpOps, [a, b] <- args -> compare' o a b
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
      | h == "$fuel", [_] <- args -> emitDo OSafepoint >> nullary 0 0
      -- a saturated known call
      | M.notMember h env, Just c <- calleeOf cx h (length args) -> do
          as <- mapM (lowerVal cx env) args
          as' <- mapM (uncurry coerce) (zip as (calleeParams c))
          v <- emit (calleeResult c) (OCall c as')
          pure (v, calleeResult c)
      | M.member h (cxProg cx) || M.member h (cxExt cx) -> refuse ("a partial or over-saturated application of `" ++ h ++ "`")
      | otherwise -> refuse ("the primitive `" ++ h ++ "`")
    _ -> refuse "an application with a computed head"
  where
    nullary t v = (\x -> (x, TVal)) <$> emit TVal (ONullary t v)
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
