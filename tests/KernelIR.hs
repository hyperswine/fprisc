-- Emission regression: whole-unit scalar fallback must not discard a native
-- kernel that a legacy caller references. This boundary is independent of
-- source type checking: hostValue models a legacy-only HAL value.
import Codegen
import Codegen.IR (Width(..))
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
  forM_ [DirectA64 ELF HartX28, DirectX64, DirectRV W64 HartTp, DirectRV W32 HartTp] $ \backend -> do
    let mode = NativeMode WholeUnit StrictOff "kernel-probe" (Just backend) False noTune False True
        base = case backend of DirectRV W32 _ -> rv32 {tgtPolicy=m2Policy {polProfile=Rv32}}; _ -> rv64
        target = base {tgtNative=Just mode}
        out = emitProgramWith target False True [] M.empty S.empty S.empty program
    unless (null (emNativeNames out) && any ((=="opaque") . fst) (emFallbacks out))
      (error "probe failed to force whole-unit scalar fallback")
    unless ("fpr_vspec_map_inc:" `isInfixOf` unlines (emNative out))
      (error ("native kernel lost under legacy-only callers: " ++ show backend))
    unless ("fpr_vspec_map_inc" `isInfixOf` emAsm out)
      (error "legacy caller did not reference the native kernel")
  putStrLn "Typed kernel emission: legacy-only callers retain their native kernel on all four selectors PASS"
