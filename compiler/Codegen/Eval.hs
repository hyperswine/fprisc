{-# LANGUAGE LambdaCase #-}
-- Codegen.Eval: the reference evaluator of the typed IR.
--
-- It states the semantics the backends must preserve: the result, the
-- trap (its text is the legacy primitive's, runtime/runtime.c) and the
-- order of effects, recorded as events.  It is not fast and it models no
-- machine: values are semantic (an Int is an Integer, an object is its
-- typeid, variant and fields), fuel is counted and never runs out, the
-- stack never fills.  Anything it cannot evaluate is `Stuck`, which is
-- a coverage gap or a compiler bug, never a program behaviour.
module Codegen.Eval (RV (..), Event (..), Failure (..), Outcome (..), evalProgram, evalProgramWidth, rvInt, rvBool, rvUnit) where

import Codegen.IR
import Codegen.Target.Common (utf8Bytes)
import Control.Monad (foldM, when, unless, replicateM_)
import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Control.Monad.Except
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M

-- a runtime value: a tagged Int, an object, a partial application of a
-- program function (its static PAP when no argument is supplied), or an
-- immortal object known only by its symbol (a primitive's object, a HAL
-- contract): opaque, equal only to itself
data RV = RInt Integer | RObj Int Int [RV] | RPap Name [RV] | RString [Int] | RSym String deriving (Eq, Ord, Show)

rvInt :: Integer -> RV
rvInt = RInt

rvBool :: Bool -> RV
rvBool b = RObj 1 (if b then 1 else 0) []

rvUnit :: RV
rvUnit = RObj 0 0 []

data Event
  = EvSafepoint Name
  | EvStackCheck Name
  | EvCall Name [Val]
  | EvAllocate Name Int Int [RV]
  | EvTrap String
  deriving (Eq, Show)

data Failure = Trap String | Stuck String deriving (Eq, Show)

data Outcome = Outcome {ocResult :: Either Failure RV, ocEvents :: [Event]} deriving (Eq, Show)

data Val = VVal RV | VInt Integer | VPred Bool deriving (Eq, Ord, Show)

type E = ExceptT Failure (State [Event])

event :: Event -> E ()
event e = lift (modify (e :))

stuck :: String -> E a
stuck = throwError . Stuck

trap :: String -> E a
trap msg = event (EvTrap msg) >> throwError (Trap msg)

evalProgram :: Program -> Name -> [RV] -> Outcome
evalProgram = evalProgramWidth W64

evalProgramWidth :: Width -> Program -> Name -> [RV] -> Outcome
evalProgramWidth width program name args =
  let (r, evs) = runState (runExceptT (callFn width program name (map VVal args))) []
   in Outcome (fmap (\case VVal v -> v; VInt n -> RInt n; VPred b -> rvBool b) r) (reverse evs)

callFn :: Width -> Program -> Name -> [Val] -> E Val
callFn width program name args = do
  fn <- maybe (stuck ("call to " ++ name ++ ", which is not in the lowered program")) pure (M.lookup name program)
  event (EvCall name args)
  let blocks = M.fromList [(bId b, b) | b <- fnBlocks fn]
      -- a block sees every value its dominators defined (the verifier's
      -- dominance check is what makes carrying the whole environment sound)
      run bid ins outer = do
        b <- maybe (stuck ("no block " ++ show bid)) pure (M.lookup bid blocks)
        when (length ins /= length (bParams b)) (stuck ("block " ++ show bid ++ ": argument count"))
        env <- foldM instr (M.union (M.fromList (zip (map fst (bParams b)) ins)) outer) (bInstrs b)
        case bTerm b of
          TRet v -> look env v
          TBr t as -> mapM (look env) as >>= \as' -> run t as' env
          TCondBr c t as e bs -> do
            p <- look env c >>= \case VPred p -> pure p; x -> stuck ("condbr on " ++ show x)
            if p then mapM (look env) as >>= \as' -> run t as' env else mapM (look env) bs >>= \bs' -> run e bs' env
          TTailCall c as -> do
            when (isForeign c) (stuck ("a foreign tail call to " ++ calleeName c ++ ": the evaluator models no C"))
            case calleeKind c of Generated s -> stuck ("a tail call of the vector kernel " ++ s ++ ": the evaluator models no kernel"); _ -> pure ()
            mapM (look env) as >>= callFn width program (calleeName c)
          TUnreachable msg -> trap msg
      instr env (Instr d op) = do
        r <- opValue env op
        case (d, r) of
          (Just (v, _), Just x) -> pure (M.insert v x env)
          (Nothing, Nothing) -> pure env
          _ -> stuck "an instruction's definition disagrees with its operation"
      opValue env = \case
        OAddress _ -> stuck "unmanaged memory is outside the Core evaluator; use the native kernel oracle"
        OIndex _ _ -> stuck "unmanaged memory is outside the Core evaluator"
        OLoad _ _ _ -> stuck "unmanaged memory is outside the Core evaluator"
        OLoadByte _ _ -> stuck "unmanaged memory is outside the Core evaluator"
        OStore _ _ _ _ -> stuck "unmanaged memory is outside the Core evaluator"
        OConstInt n -> pure (Just (VInt n))
        ONullary t v -> pure (Just (VVal (RObj t v [])))
        OString s -> pure (Just (VVal (RString (utf8Bytes s))))
        OMake tid variant fields -> do
          fs <- mapM (val env) fields
          event (EvAllocate (fnName fn) tid variant fs)
          pure (Just (VVal (RObj tid variant fs)))
        -- value semantics: the reused object is the new value (the old one
        -- is consumed; no program can observe the difference)
        OReuse tid variant root fields -> do
          _ <- val env root
          fs <- mapM (val env) fields
          pure (Just (VVal (RObj tid variant fs)))
        OField n obj -> val env obj >>= \case
          RObj _ _ fs | n >= 0 && n < length fs -> pure (Just (VVal (fs !! n)))
          _ -> stuck "a field projection outside its statically typed constructor"
        OStrLen str -> do
          bs <- string env "strlen" str
          pure (Just (VInt (toInteger (length bs))))
        OCharAt str index -> do
          bs <- string env "charAt" str
          n <- int env index
          when (n < 0 || n >= toInteger (length bs))
            (trap ("charAt: index out of range (" ++ show n ++ ", length " ++ show (length bs) ++ ")"))
          pure (Just (VInt (toInteger (bs !! fromInteger n))))
        OTag v -> int env v >>= \n -> pure (Just (VVal (RInt n)))
        OUntag v -> val env v >>= \case
          RInt n -> pure (Just (VInt n))
          x -> stuck ("untag of an object " ++ show x)
        OBoolOf v -> predicate env v >>= \b -> pure (Just (VVal (rvBool b)))
        OTruth v -> val env v >>= \case
          RObj 1 b [] -> pure (Just (VPred (b /= 0)))
          x -> stuck ("truth of " ++ show x)
        ONot v -> predicate env v >>= \b -> pure (Just (VPred (not b)))
        OIsInt v -> val env v >>= \case
          RInt _ -> pure (Just (VPred True))
          _ -> pure (Just (VPred False))
        OTagTest t c v -> val env v >>= \case
          RObj t' c' _ -> pure (Just (VPred (t == t' && c == c')))
          RInt _ -> pure (Just (VPred False))
          RSym s -> stuck ("a tag test on the immortal object " ++ s ++ ", whose typeid the evaluator does not model")
          RString _ -> pure (Just (VPred (t == 9000 && c == 0)))
          RPap _ _ -> pure (Just (VPred False)) -- T_PAP is no constructor's typeid
        OSymbol sym -> pure (Just (VVal (RSym sym)))
        OFunValue n -> pure (Just (VVal (RPap n [])))
        OApply f as -> do
          h <- val env f
          args' <- mapM (val env) as
          r <- applyN width program h args'
          pure (Just (VVal r))
        OKernelArith o a b -> do
          x <- int env a
          y <- int env b
          when (o == Div && y == 0) (trap "division by zero")
          let result = case o of Add -> x+y; Sub -> x-y; Mul -> x*y; Div -> x `quot` y
          unless (intFitsWidth width result) (trap ("Int overflow in a vector kernel: the result does not fit an Int (" ++ show (fst (intBounds width)) ++ ".." ++ show (snd (intBounds width)) ++ "); I64 is the type that wraps"))
          pure (Just (VInt result))
        OArith o a b -> do
          x <- int env a
          y <- int env b
          r <- arith width o x y
          pure (Just (VInt r))
        OBit o a b -> do
          x <- int env a
          y <- int env b
          pure (Just (VInt (bit o x y)))
        OShift o a b -> do
          x <- int env a
          n <- int env b
          r <- shift width o x n
          pure (Just (VInt r))
        OCmp o a b -> do
          x <- int env a
          y <- int env b
          pure (Just (VPred (cmp o x y)))
        OEqVal eq a b -> do
          x <- val env a
          y <- val env b
          pure (Just (VPred ((x == y) == eq)))
        OBits _ -> stuck "a raw-bits constant (an F64 literal): the evaluator models no floats"
        OFloatBin _ _ _ -> stuck "an inline F64 operation: the evaluator models no floats (F64 values come from C entries it does not model either)"
        OFloatCmp _ _ _ -> stuck "an inline F64 comparison: the evaluator models no floats"
        OFloatCmpTree {} -> stuck "a comparison tree: the evaluator models no floats"
        OFloat32CmpTree {} -> stuck "a comparison tree: the evaluator models no floats"
        OFloat32Tree _ -> stuck "an F32 tree: the evaluator models no floats"
        OFloatTree _ -> stuck "a float tree: the evaluator models no floats"
        OFloat32Bin _ _ _ -> stuck "an inline F32 operation: the evaluator models no floats"
        OFloat32Cmp _ _ _ -> stuck "an inline F32 comparison: the evaluator models no floats"
        OCall c as -> do
          args' <- mapM (look env) as
          when (isForeign c) (stuck ("a foreign call to " ++ calleeName c ++ ": the evaluator models no C"))
          case calleeKind c of Generated s -> stuck ("a call of the vector kernel " ++ s ++ ": the evaluator models no kernel"); _ -> pure ()
          r <- callFn width program (calleeName c) args'
          pure (Just r)
        OSafepoint -> event (EvSafepoint (fnName fn)) >> pure Nothing
        OSafepointN n -> replicateM_ n (event (EvSafepoint (fnName fn))) >> pure Nothing
        OSimdPair {} -> stuck "a NEON pair over unmanaged memory is outside the Core evaluator"
        ORvvVlMax -> stuck "the vector length is a machine fact outside the Core evaluator"
        ORvvLanes _ _ -> stuck "vector lanes over unmanaged memory are outside the Core evaluator"
        ORvvSumLoaded _ -> stuck "vector lanes over unmanaged memory are outside the Core evaluator"
        OStackCheck -> event (EvStackCheck (fnName fn)) >> pure Nothing
      look env v = maybe (stuck ("no value " ++ show v)) pure (M.lookup v env)
      int env v = look env v >>= \case VInt n -> pure n; x -> stuck ("an Int was needed, found " ++ show x)
      val env v = look env v >>= \case VVal x -> pure x; x -> stuck ("a runtime value was needed, found " ++ show x)
      string env prim v = val env v >>= \case RString bs -> pure bs; _ -> trap (prim ++ ": not a string")
      predicate env v = look env v >>= \case VPred b -> pure b; x -> stuck ("a predicate was needed, found " ++ show x)
  run (fnEntry fn) args M.empty

-- the generic application as runtime/runtime.c fpr_applyN states it: an
-- Int or an object that is no PAP traps by name; fewer arguments than the
-- function still needs make a larger PAP; exactly enough call it; more
-- call it with what it needs and apply the result to the rest
applyN :: Width -> Program -> RV -> [RV] -> E RV
applyN width program f args = case f of
  RInt _ -> trap "apply: applied an integer"
  RObj _ _ _ -> trap "apply: not a function value"
  RString _ -> trap "apply: not a function value"
  RSym s -> stuck ("an application of the immortal object " ++ s ++ ": the evaluator models no C")
  RPap n supplied -> do
    fn <- maybe (stuck ("an application of " ++ n ++ ", which is not in the lowered program")) pure (M.lookup n program)
    let arity = length (fnSourceParams fn)
        need = arity - length supplied
    if length args < need
      then pure (RPap n (supplied ++ args))
      else do
        r <- callFn width program n (map VVal (supplied ++ take need args))
        let rest = drop need args
        r' <- case r of VVal v -> pure v; VInt k -> pure (RInt k); VPred b -> pure (rvBool b)
        if null rest then pure r' else applyN width program r' rest

-- Int + - * / as runtime/runtime.c states them: the result must fit the
-- Int range; / refuses a zero divisor first; division truncates toward
-- zero like the C primitive.
arith :: Width -> ArithOp -> Integer -> Integer -> E Integer
arith width o x y = case o of
  Add -> fit (x + y)
  Sub -> fit (x - y)
  Mul -> fit (x * y)
  Div
    | y == 0 -> trap "division by zero"
    | otherwise -> fit (x `quot` y)
  where
    fit r
      | intFitsWidth width r = pure r
      | otherwise =
          trap ("Int overflow: " ++ show x ++ " " ++ arithSymbol o ++ " " ++ show y
                  ++ " does not fit an Int (" ++ show (fst (intBounds width)) ++ ".." ++ show (snd (intBounds width)) ++ "); I64 is the type that wraps")

cmp :: CmpOp -> Integer -> Integer -> Bool
cmp = \case Lt -> (<); Gt -> (>); Le -> (<=); Ge -> (>=); Eq -> (==); Ne -> (/=)

-- band/bor/bxor on the untagged Ints (runtime/bits.c): two's complement,
-- bit for bit; the result of two 63-bit values is a 63-bit value
bit :: BitOp -> Integer -> Integer -> Integer
bit = \case BAnd -> (.&.); BOr -> (.|.); BXor -> xor

-- BITSHIFTL / BITSHIFTR as bits.c states them: the count must be 0..63
-- (checked first, the primitive's text), then the 64-bit shift of the
-- untagged value, logical to the right, and the low 63 bits sign-extended
-- (TAG((sw)...) drops the top bit)
shift :: Width -> ShiftOp -> Integer -> Integer -> E Integer
shift width o x n
  | n < 0 || n >= toInteger (widthBits width) = trap (shiftName o ++ ": shift must be 0.." ++ show (widthBits width - 1))
  | otherwise = pure $ case o of
      Shl -> wrapInt width (x `shiftL` fromInteger n)
      Shr -> wrapInt width ((x `mod` 2 ^ widthBits width) `shiftR` fromInteger n)
