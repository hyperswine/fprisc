-- Column-kernel admission precedes CFG construction. A checked plan owns
-- its policy and callback snapshot, so lowering cannot combine unrelated
-- evidence or index a malformed capture/accumulator slot.
module Codegen.Kernel.Plan
  (Stage(..), Kernel(..), ElementOp(..), CheckedKernel, checkKernel, kernelInput,
   stageFallback) where
import Compiler.VectorOperation
import Codegen.IR
import Codegen.Policy
import Codegen.Verify (simdExprOk, verifyProgramWidth)
import KernelKinds (Kind(..))
import Control.Monad (unless, when, forM_)
import qualified Data.Map.Strict as M

-- Capture indices address boxed entry arguments. An optional accumulator
-- also occupies an entry argument, before the vector.
data Stage = Stage ElementOp Name [Int] deriving Show
data Kernel = Kernel
  { kernelSymbol :: String, kernelCaptures :: [Kind], kernelElement :: Kind,
    kernelAccumulator :: Maybe (Int, Kind), kernelStages :: [Stage],
    kernelSimd :: Maybe (SimdExpr, Int), kernelRvvSum :: Bool }
  deriving Show

data CheckedKernel = CheckedKernel Policy Program Kernel
kernelInput :: CheckedKernel -> (Policy, Program, Kernel)
kernelInput (CheckedKernel p fs k) = (p,fs,k)

checkKernel :: Policy -> Program -> Kernel -> Either String CheckedKernel
checkKernel policy callbacks k = do
  validatePolicy policy
  unless (kernelElement k `elem` [KI,KD,KS] && all (`elem` [KI,KD,KS,KB]) captures)
    (Left "typed column kernels currently support Int/F64/F32 elements and Int/F64/F32/Bool captures")
  unless (policyWidth policy == W64 || (kernelElement k == KI && all (`notElem` [KD,KS]) captures))
    (Left "RV32 float columns use boxed values")
  require "empty stage list" (not (null stages))
  require "empty kernel symbol" (not (null (kernelSymbol k)))
  require "entry arity exceeds native ceiling" (length captures < arityCeiling)
  -- A fold consumes the stream and yields (accumulator, vector). The generic
  -- fallback cannot feed that pair into another column stage.
  require "fold must be the single terminal fold with an accumulator"
    (case kernelAccumulator k of
      Nothing -> Fold `notElem` ops
      Just _ -> case reverse ops of Fold:rest -> Fold `notElem` rest; _ -> False)
  forM_ (kernelAccumulator k) $ \(n,kind) -> do
    require "accumulator slot outside entry arguments" (valid n)
    require "accumulator kind disagrees with its entry slot" (captures !! n == kind)
    require "unsupported accumulator kind" (kind `elem` [KI,KD,KS])
  forM_ stages $ \(Stage op name slots) -> do
    require "empty callback symbol" (not (null name))
    require ("capture slot outside entry arguments at " ++ name) (all valid slots)
    let arity = length slots + if op == Fold then 2 else 1
    require ("callback arity exceeds native ceiling at " ++ name) (arity <= arityCeiling)
    -- Absent callbacks deliberately use generated calls (the pipeline inline
    -- opt-out). Available bodies must match the boxed callback interface.
    forM_ (M.lookup name callbacks) $ \fn ->
      require ("callback interface disagrees at " ++ name)
        (fnResult fn == TVal && case [bParams b | b <- fnBlocks fn, bId b == fnEntry fn] of
          [ps] -> map snd ps == replicate arity TVal
          _ -> False)
  forM_ (kernelSimd k) $ \(expr,ticks) -> do
    unless (ops == [Map] && all (== kernelElement k) captures && kernelElement k `elem` [KI,KD] && policyWidth policy == W64)
      (Left "a SIMD pair body needs a single map over Int or F64 with matching captures on a 64-bit word")
    unless (all valid (simdCaptures expr)) (Left "SIMD capture index outside the kernel captures")
    require "negative SIMD callback fuel" (ticks >= 0)
    require "overflowing SIMD callback fuel" (ticks <= maxBound `div` 2 - 1)
    either (Left . ("compiler error: " ++)) Right (simdExprOk (kernelElement k == KI) expr)
  when (kernelRvvSum k) $
    unless (ops == [Fold] && captures == [KI] && kernelElement k == KI
      && kernelAccumulator k == Just (0,KI) && all (\(Stage _ _ slots) -> null slots) stages)
      (Left "an RVV sum strip needs a capture-free Int fold")
  -- Validate before cloning callback blocks: the copier uses total maps only
  -- after this proves every operand, edge and block identity is present.
  either (Left . ("compiler error: " ++)) Right (verifyProgramWidth (policyWidth policy) callbacks)
  pure (CheckedKernel policy callbacks k)
  where
    captures = kernelCaptures k
    stages = kernelStages k
    ops = [op | Stage op _ _ <- stages]
    valid n = n >= 0 && n < length captures
    require why ok = unless ok (Left ("compiler error: typed column kernel: " ++ why))

-- These are foreign runtime entries, not source spellings to parse again.
stageFallback :: ElementOp -> Callee
stageFallback op = case op of
  Map -> entry "Vec.map" "fpr_vec_map" 2
  Filter -> entry "Vec.filter" "fpr_vec_filter" 2
  Fold -> entry "Vec.fold" "fpr_vec_fold" 3
  where entry source symbol arity = Callee source (Foreign symbol) (replicate arity TVal) TVal
