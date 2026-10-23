-- Whole-unit refusals must not expose partial native code. Complete units
-- retain every requested native kernel on each selector.
import Codegen
import qualified Codegen.Kernel as K
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
  let captured = K.Kernel "pair" [KI] KI Nothing [K.Stage "map" "f" [0]] (Just (K.SInt Add K.SLane (K.SCapture 0),0)) False
  case K.lowerKernel m2Policy M.empty captured of
    Right _ -> pure ()
    Left msg -> error ("captured SIMD builder refused: " ++ msg)
  putStrLn "Typed SIMD builder: matching Int captures admitted PASS"
  -- the new forms refuse the shapes their proofs do not cover
  let refused what = case what of Left _ -> pure (); Right _ -> error "a builder accepted a shape outside its proof"
  refused (K.lowerKernel m2Policy M.empty (K.Kernel "pair" [KD] KI Nothing [K.Stage "map" "f" [0]] (Just (K.SInt Add K.SLane (K.SConst 1),0)) False))
  refused (K.lowerKernel m2Policy M.empty (K.Kernel "pair" [] KI Nothing [K.Stage "map" "f" []] (Just (K.SInt Mul K.SLane (K.SConst 2),0)) False))
  refused (K.lowerKernel m2Policy M.empty captured {K.kernelSimd=Just (K.SInt Add K.SLane (K.SCapture 1),0)})
  refused (K.lowerKernel (m2Policy {polProfile=Rv32}) M.empty captured)
  refused (K.lowerKernel m2Policy M.empty (K.Kernel "strip" [KI,KI] KI (Just (1,KI)) [K.Stage "fold" "f" [0]] Nothing True))
  refused (K.lowerRecordKernel m2Policy M.empty (K.RecordKernel "gpu" "f" [] False (-1,-1) [(0,KI),(2,KI)] (K.RecordFold "dual" KI) True))
  refused (K.lowerMapAsKernel m2Policy (K.MapAsKernel "as" "f" 8 "d"))
  putStrLn "Typed kernel builders: a mixed-capture or invalid-op SIMD pair, a captured RVV sum, a GPU pair sum off columns 0 and 1, and an eight-capture mapAs are refused PASS"
