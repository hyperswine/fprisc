-- Column-kernel admission precedes CFG construction. A checked plan owns
-- its policy and callback snapshot, so lowering cannot combine unrelated
-- evidence or index a malformed capture/accumulator slot.
module Codegen.Kernel.Plan
  (Stage(..), Kernel(..), ElementOp(..), CheckedKernel, checkKernel, kernelInput,
   stageFallback, RecordOp(..), RecordKernel(..), CheckedRecord, checkRecordKernel, recordInput,
   MapAsKernel(..), CheckedMapAs, checkMapAsKernel, mapAsInput) where
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
  checkCallbacks policy callbacks [(name,length slots + if op == Fold then 2 else 1) | Stage op name slots <- stages]
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

-- A record plan describes the dualized callbacks, never architecture details.
-- Columns are (index, kind); map outputs cover the complete record. The map
-- entry retains the planner's capture slot even for a capture-free callback.
data RecordOp
  = RecordFold Name Kind
  | RecordFilter Name
  | RecordMap [(Name, [Int], [Int])]
  deriving Show
data RecordKernel = RecordKernel
  { recordSymbol :: String, recordOriginal :: Name,
    recordCaptures :: [Kind], recordHasCapture :: Bool,
    recordShape :: (Int,Int), recordColumns :: [(Int,Kind)],
    recordOperation :: RecordOp,
    recordGpuPairSum :: Bool -- a capture-free Int fold of acc + column 0 + column 1: offered to the GPU hook first (vec.c fpr_gpu_vec_fold_pair_sum)
  } deriving Show

data CheckedRecord = CheckedRecord Policy Program RecordKernel
recordInput :: CheckedRecord -> (Policy, Program, RecordKernel)
recordInput (CheckedRecord p fs k) = (p,fs,k)

checkRecordKernel :: Policy -> Program -> RecordKernel -> Either String CheckedRecord
checkRecordKernel policy callbacks k = do
  validatePolicy policy
  unless (not (null columns) && all ((>=0) . fst) columns)
    (Left "invalid typed record column plan")
  case operation of
    RecordMap fields -> unless
      (map fst columns == [0..length fields-1] && all (\(_,ps,cs) -> all (>=0) ps && all (`elem` map fst columns) cs) fields)
      (Left "invalid typed record map field plan")
    _ -> pure ()
  unless (all (`elem` [KI,KD,KS]) (map snd columns ++ accumulatorKinds) &&
          all (`elem` [KI,KD,KS,KB]) (recordCaptures k))
    (Left "typed record kernels currently support Int/F64/F32 columns and Int/F64/F32/Bool captures")
  when (recordGpuPairSum k) $
    unless (null (recordCaptures k) && map fst columns == [0,1] && accumulatorKinds == [KI] && all ((== KI) . snd) columns)
      (Left "the GPU pair sum needs a capture-free Int fold over columns 0 and 1")
  unless (policyWidth policy == W64 || all (`notElem` [KD,KS]) (map snd columns ++ accumulatorKinds ++ recordCaptures k))
    (Left "RV32 float record columns use boxed values")
  require "empty kernel/original symbol" (not (null (recordSymbol k)) && not (null (recordOriginal k)))
  require "duplicate record column" (M.size (M.fromList columns) == length columns)
  require "column count exceeds target Int range" (all (\(n,_) -> toInteger n < snd (intBounds (policyWidth policy))) columns)
  let argc = case operation of RecordMap _ -> 2; _ -> length (recordCaptures k) + length accumulatorKinds + 1
  require "entry arity exceeds native ceiling" (argc <= arityCeiling)
  calls <- case operation of
    RecordFold name _ -> do
      require "capture tuple flag on a fold" (not (recordHasCapture k))
      pure [(name,length (recordCaptures k) + 1 + length columns)]
    RecordFilter name -> do
      require "record filter must be capture-free" (null (recordCaptures k) && not (recordHasCapture k))
      pure [(name,length columns)]
    RecordMap fields -> do
      require "record map uses a tuple capture, not scalar entry captures" (null (recordCaptures k))
      require "record map reads absent capture tuple" (recordHasCapture k || all (\(_,ps,_) -> null ps) fields)
      require "record map capture projection exceeds native displacement" (all (\(_,ps,_) -> all (<=268435454) ps) fields)
      pure [(name,length ps + length cs) | (name,ps,cs) <- fields]
  checkCallbacks policy callbacks calls
  pure (CheckedRecord policy callbacks k)
  where
    columns = recordColumns k
    operation = recordOperation k
    accumulatorKinds = case operation of RecordFold _ ty -> [ty]; _ -> []
    require why ok = unless ok (Left ("compiler error: typed record kernel: " ++ why))

data MapAsKernel = MapAsKernel
  { mapAsSymbol :: String, mapAsOriginal :: Name, mapAsCaptures :: Int, mapAsLayout :: String }
  deriving Show

data CheckedMapAs = CheckedMapAs Policy MapAsKernel
mapAsInput :: CheckedMapAs -> (Policy, MapAsKernel)
mapAsInput (CheckedMapAs p k) = (p,k)

checkMapAsKernel :: Policy -> MapAsKernel -> Either String CheckedMapAs
checkMapAsKernel policy k = do
  validatePolicy policy
  unless (mapAsCaptures k >= 0 && mapAsCaptures k <= 7) (Left "typed mapAs kernels take at most seven captures")
  unless (not (null (mapAsSymbol k)) && not (null (mapAsOriginal k)))
    (Left "compiler error: typed mapAs kernel: empty kernel/original symbol")
  pure (CheckedMapAs policy k)

-- Absent bodies deliberately use generated calls (the pipeline inline
-- opt-out). Available bodies must match their boxed callback interfaces.
-- Verify before cloning: every operand/edge must exist in the copier's maps.
checkCallbacks :: Policy -> Program -> [(Name,Int)] -> Either String ()
checkCallbacks policy callbacks calls = do
  forM_ calls $ \(name,arity) -> do
    require "empty callback symbol" (not (null name))
    require ("callback arity exceeds native ceiling at " ++ name) (arity >= 0 && arity <= arityCeiling)
    forM_ (M.lookup name callbacks) $ \fn ->
      require ("callback interface disagrees at " ++ name)
        (fnResult fn == TVal && case [bParams b | b <- fnBlocks fn, bId b == fnEntry fn] of
          [ps] -> map snd ps == replicate arity TVal
          _ -> False)
  either (Left . ("compiler error: " ++)) Right (verifyProgramWidth (policyWidth policy) callbacks)
  where require why ok = unless ok (Left ("compiler error: typed kernel: " ++ why))
