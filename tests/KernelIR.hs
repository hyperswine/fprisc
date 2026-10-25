-- Whole-unit refusals must not expose partial native code. Complete units
-- retain every requested native kernel on each selector.
import Codegen
import qualified Codegen.Kernel as K
import qualified Codegen.Kernel.Plan as Plan
import qualified Codegen.IR as I
import KernelKinds (Kind(..))
import Codegen.IR (Width(..), ArithOp(..))
import Codegen.Policy (m2Policy, Policy(..), Profile(..))
import Codegen.Target.RV (RVHart(..))
import Codegen.Target.A64 (ObjectFormat(..), HartAccess(..))
import Codegen.Target.Common (noTune)
import FPRISC (Core(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isInfixOf)
import Control.Monad (forM_, unless)

main :: IO ()
main = do
  let app f = foldl CApp (CVar f)
      program = M.fromList
        [("opaque",([],CVar "hostValue")),
         ("inc",(["c","x"],app "+" [CVar "x",CVar "c"])),
         ("map",(["c","v"],app "Vec.map" [app "inc" [CVar "c"],CVar "v"]))]
  forM_ [DirectA64 ELF HartX28, DirectX64 ELF, DirectX64 MachO, DirectRV W64 HartTp, DirectRV W32 HartTp] $ \backend -> do
    let mode = NativeMode WholeUnit StrictOff "kernel-probe" (Just backend) False noTune False True
        base = case backend of DirectRV W32 _ -> rv32 {tgtPolicy=m2Policy {polProfile=Rv32}}; _ -> rv64
        target = base {tgtNative=Just mode}
        out = emitProgramWith target False True [] M.empty S.empty S.empty program
    unless (null (emNativeNames out) && any ((=="opaque") . fst) (emFallbacks out))
      (error "probe failed to force whole-unit refusal")
    unless (null (emNativeNames out) && not ("fpr_vspec_map_inc:" `isInfixOf` unlines (emNative out)))
      (error ("refused whole unit unexpectedly emitted a kernel: " ++ show backend))
    let supported=emitProgramWith target False True [] M.empty S.empty S.empty (M.delete "opaque" program)
    unless (null (emFallbacks supported) && "fpr_vspec_map_inc:" `isInfixOf` unlines (emNative supported))
      (error "supported whole unit failed to emit its native kernel")
  putStrLn "Typed kernel emission: unsupported whole units refused; complete units retain kernels on all four selectors PASS"
  let floatRecord = K.RecordKernel "float-record" "original" [] False (-1,-1) [(0,KD)] (K.RecordFold "dual" KD) False
  case K.lowerRecordKernel (m2Policy {polProfile=Rv32}) M.empty floatRecord of
    Left "RV32 float record columns use boxed values" -> pure ()
    other -> error ("RV32 float record lowering must refuse boxed columns: " ++ show other)
  putStrLn "Typed record builder: explicit RV32 boxed-float refusal PASS"
  let captured = K.Kernel "pair" [KI] KI Nothing [K.Stage K.Map "f" [0]] (Just (K.SInt Add K.SLane (K.SCapture 0),0)) False
  case K.lowerKernel m2Policy M.empty captured of
    Right _ -> pure ()
    Left msg -> error ("captured SIMD builder refused: " ++ msg)
  putStrLn "Typed SIMD builder: matching Int captures admitted PASS"
  -- the new forms refuse the shapes their proofs do not cover
  let refused what = case what of Left _ -> pure (); Right _ -> error "a builder accepted a shape outside its proof"
  refused (K.lowerKernel m2Policy M.empty (K.Kernel "pair" [KD] KI Nothing [K.Stage K.Map "f" [0]] (Just (K.SInt Add K.SLane (K.SConst 1),0)) False))
  refused (K.lowerKernel m2Policy M.empty (K.Kernel "pair" [] KI Nothing [K.Stage K.Map "f" []] (Just (K.SInt Mul K.SLane (K.SConst 2),0)) False))
  refused (K.lowerKernel m2Policy M.empty captured {K.kernelSimd=Just (K.SInt Add K.SLane (K.SCapture 1),0)})
  refused (K.lowerKernel (m2Policy {polProfile=Rv32}) M.empty captured)
  refused (K.lowerKernel m2Policy M.empty (K.Kernel "strip" [KI,KI] KI (Just (1,KI)) [K.Stage K.Fold "f" [0]] Nothing True))
  refused (K.lowerRecordKernel m2Policy M.empty (K.RecordKernel "gpu" "f" [] False (-1,-1) [(0,KI),(2,KI)] (K.RecordFold "dual" KI) True))
  refused (K.lowerMapAsKernel m2Policy (K.MapAsKernel "as" "f" 8 "d"))
  putStrLn "Typed kernel builders: a mixed-capture or invalid-op SIMD pair, a captured RVV sum, a GPU pair sum off columns 0 and 1, and an eight-capture mapAs are refused PASS"
  checkColumnPlans

-- Refuse malformed plans before a partial list index or CFG construction.
-- These are caller-contract failures rather than manufactured ISA failures.
checkColumnPlans :: IO ()
checkColumnPlans = do
  let base = K.Kernel "column" [KI,KB,KI] KI Nothing [K.Stage K.Map "map" [0]] Nothing False
      callback name count result = I.Fn name [] result (I.BId 0)
        [I.Block (I.BId 0) [(I.VId n,I.TVal) | n <- [0..count-1]] [] (I.TRet (I.VId 0))]
      bodies = M.fromList [("map",callback "map" 2 I.TVal),
                           ("filter",callback "filter" 2 I.TVal),
                           ("fold",callback "fold" 3 I.TVal)]
      pipeline = base {K.kernelAccumulator=Just (2,KI),
        K.kernelStages=[K.Stage K.Map "map" [0],K.Stage K.Filter "filter" [1],K.Stage K.Fold "fold" [0]]}
      accept label result = case result of Right _ -> pure (); Left msg -> error (label ++ ": " ++ msg)
      reject label detail callbacks draft = case K.lowerKernel m2Policy callbacks draft of
        Left msg | detail `isInfixOf` msg -> pure ()
        other -> error (label ++ ": expected " ++ detail ++ ", got " ++ show other)
  accept "captured map/filter/fold" (K.lowerKernel m2Policy bodies pipeline)
  accept "out-of-line callbacks remain supported" (K.lowerKernel m2Policy M.empty pipeline)
  forM_ [[],[K.Map],[K.Filter],[K.Map,K.Filter],[K.Filter,K.Map]] $ \prefix -> do
    -- Fold-free and terminal-fold chains both retain their operation order.
    let stages = [K.Stage op "callback" [] | op <- prefix]
    unless (null prefix) $ accept "fold-free admission" (Plan.checkKernel m2Policy M.empty
      base {K.kernelStages=stages})
    accept "terminal-fold admission" (Plan.checkKernel m2Policy M.empty
      base {K.kernelAccumulator=Just (2,KI),K.kernelStages=stages++[K.Stage K.Fold "callback" []]})
  reject "negative capture" "capture slot" M.empty base {K.kernelStages=[K.Stage K.Map "map" [-1]]}
  reject "past-end capture must not read the vector slot" "capture slot" M.empty base {K.kernelStages=[K.Stage K.Map "map" [3]]}
  reject "negative accumulator" "accumulator slot" M.empty pipeline {K.kernelAccumulator=Just (-1,KI)}
  reject "past-end accumulator" "accumulator slot" M.empty pipeline {K.kernelAccumulator=Just (3,KI)}
  reject "accumulator kind" "accumulator kind disagrees" M.empty pipeline {K.kernelAccumulator=Just (2,KD)}
  reject "Boolean accumulator" "unsupported accumulator kind" M.empty pipeline {K.kernelAccumulator=Just (1,KB)}
  reject "fold lacks accumulator" "single terminal fold" M.empty base {K.kernelStages=[K.Stage K.Fold "fold" []]}
  reject "accumulator lacks fold" "single terminal fold" M.empty base {K.kernelAccumulator=Just (2,KI)}
  reject "nonterminal fold" "single terminal fold" M.empty pipeline {K.kernelStages=reverse (K.kernelStages pipeline)}
  reject "multiple folds" "single terminal fold" M.empty pipeline {K.kernelStages=[K.Stage K.Fold "fold" [],K.Stage K.Fold "fold" []]}
  reject "empty stages" "empty stage list" M.empty base {K.kernelStages=[]}
  reject "empty kernel symbol" "empty kernel symbol" M.empty base {K.kernelSymbol=""}
  reject "empty callback" "empty callback symbol" M.empty base {K.kernelStages=[K.Stage K.Map "" []]}
  reject "entry limit" "entry arity" M.empty base {K.kernelCaptures=replicate 64 KI}
  reject "callback limit" "callback arity" M.empty base {K.kernelStages=[K.Stage K.Map "map" (replicate 64 0)]}
  reject "callback arity mismatch" "callback interface" (M.singleton "map" (callback "map" 1 I.TVal)) base
  reject "callback result mismatch" "callback interface" (M.singleton "map" (callback "map" 2 I.TInt)) base
  reject "callback parameter mismatch" "callback interface" (M.singleton "map"
    (I.Fn "map" [] I.TVal (I.BId 0) [I.Block (I.BId 0) [(I.VId 0,I.TInt),(I.VId 1,I.TVal)] [] (I.TRet (I.VId 1))])) base
  reject "callback entry missing" "callback interface" (M.singleton "map"
    ((callback "map" 2 I.TVal) {I.fnEntry=I.BId 1})) base
  reject "undefined callback operand refused before copying" "is never defined" (M.singleton "map"
    ((callback "map" 2 I.TVal) {I.fnBlocks=[I.Block (I.BId 0) [(I.VId 0,I.TVal),(I.VId 1,I.TVal)] [] (I.TRet (I.VId 99))]})) base
  reject "invalid callback edge refused before copying" "compiler error:" (M.singleton "map"
    ((callback "map" 2 I.TVal) {I.fnBlocks=[I.Block (I.BId 0) [(I.VId 0,I.TVal),(I.VId 1,I.TVal)] [] (I.TBr (I.BId 99) [])]})) base
  let pair = K.Kernel "pair" [KI] KI Nothing [K.Stage K.Map "map" [0]] (Just (K.SLane,-1)) False
  reject "negative SIMD fuel" "negative SIMD callback fuel" M.empty pair
  reject "overflowing SIMD fuel" "overflowing SIMD callback fuel" M.empty pair {K.kernelSimd=Just (K.SLane,maxBound)}
  reject "RVV cannot capture its initial accumulator" "capture-free Int fold" M.empty
    (K.Kernel "sum" [KI] KI (Just (0,KI)) [K.Stage K.Fold "fold" [0]] Nothing True)
  let runtime = [(K.Map,"Vec.map","fpr_vec_map",2),(K.Filter,"Vec.filter","fpr_vec_filter",2),
                 (K.Fold,"Vec.fold","fpr_vec_fold",3)]
  forM_ runtime $ \(op,name,symbol,arity) -> do
    let c=Plan.stageFallback op
    unless (I.calleeName c==name && I.calleeKind c==I.Foreign symbol && I.calleeParams c==replicate arity I.TVal
      && I.calleeResult c==I.TVal) (error "column fallback ABI changed")
  putStrLn "Checked column plans: stage order, captures, accumulators, callback interfaces, fuel and runtime ABI PASS"
