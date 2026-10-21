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
module Codegen.Eval (RV (..), Event (..), Failure (..), Outcome (..), evalProgram, rvInt, rvBool, rvUnit) where

import Codegen.IR
import Control.Monad (foldM, when)
import Control.Monad.Except
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M

-- a runtime value: a tagged Int or an object
data RV = RInt Integer | RObj Int Int [RV] deriving (Eq, Ord, Show)

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
  | EvTrap String
  deriving (Eq, Show)

data Failure = Trap String | Stuck String deriving (Eq, Show)

data Outcome = Outcome {ocResult :: Either Failure RV, ocEvents :: [Event]} deriving (Show)

data Val = VVal RV | VInt Integer | VPred Bool deriving (Eq, Ord, Show)

type E = ExceptT Failure (State [Event])

event :: Event -> E ()
event e = lift (modify (e :))

stuck :: String -> E a
stuck = throwError . Stuck

trap :: String -> E a
trap msg = event (EvTrap msg) >> throwError (Trap msg)

evalProgram :: Program -> Name -> [RV] -> Outcome
evalProgram program name args =
  let (r, evs) = runState (runExceptT (callFn program name (map VVal args))) []
   in Outcome (fmap (\case VVal v -> v; VInt n -> RInt n; VPred b -> rvBool b) r) (reverse evs)

callFn :: Program -> Name -> [Val] -> E Val
callFn program name args = do
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
            mapM (look env) as >>= callFn program (calleeName c)
      instr env (Instr d op) = do
        r <- opValue env op
        case (d, r) of
          (Just (v, _), Just x) -> pure (M.insert v x env)
          (Nothing, Nothing) -> pure env
          _ -> stuck "an instruction's definition disagrees with its operation"
      opValue env = \case
        OConstInt n -> pure (Just (VInt n))
        ONullary t v -> pure (Just (VVal (RObj t v [])))
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
        OArith o a b -> do
          x <- int env a
          y <- int env b
          r <- arith o x y
          pure (Just (VInt r))
        OCmp o a b -> do
          x <- int env a
          y <- int env b
          pure (Just (VPred (cmp o x y)))
        OEqVal eq a b -> do
          x <- val env a
          y <- val env b
          pure (Just (VPred ((x == y) == eq)))
        OCall c as -> do
          args' <- mapM (look env) as
          when (isForeign c) (stuck ("a foreign call to " ++ calleeName c ++ ": the evaluator models no C"))
          r <- callFn program (calleeName c) args'
          pure (Just r)
        OSafepoint -> event (EvSafepoint (fnName fn)) >> pure Nothing
        OStackCheck -> event (EvStackCheck (fnName fn)) >> pure Nothing
      look env v = maybe (stuck ("no value " ++ show v)) pure (M.lookup v env)
      int env v = look env v >>= \case VInt n -> pure n; x -> stuck ("an Int was needed, found " ++ show x)
      val env v = look env v >>= \case VVal x -> pure x; x -> stuck ("a runtime value was needed, found " ++ show x)
      predicate env v = look env v >>= \case VPred b -> pure b; x -> stuck ("a predicate was needed, found " ++ show x)
  run (fnEntry fn) args M.empty

-- Int + - * / as runtime/runtime.c states them: the result must fit the
-- Int range; / refuses a zero divisor first; division truncates toward
-- zero like the C primitive.
arith :: ArithOp -> Integer -> Integer -> E Integer
arith o x y = case o of
  Add -> fit (x + y)
  Sub -> fit (x - y)
  Mul -> fit (x * y)
  Div
    | y == 0 -> trap "division by zero"
    | otherwise -> fit (x `quot` y)
  where
    fit r
      | intFits64 r = pure r
      | otherwise =
          trap ("Int overflow: " ++ show x ++ " " ++ arithSymbol o ++ " " ++ show y
                  ++ " does not fit an Int (" ++ show intMin ++ ".." ++ show intMax ++ "); I64 is the type that wraps")

cmp :: CmpOp -> Integer -> Integer -> Bool
cmp = \case Lt -> (<); Gt -> (>); Le -> (<=); Ge -> (>=); Eq -> (==); Ne -> (/=)
