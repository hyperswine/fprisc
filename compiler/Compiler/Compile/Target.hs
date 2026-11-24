-- Compiler.Compile.Target -- profile/system/host/target matrix validation
-- and backend policy / cache-tag configuration for the native compile driver.
module Compiler.Compile.Target
  ( TargetConfig (..),
    validateProfileMatrix,
    buildTargetConfig
  ) where

import Arc (arcRev)
import Codegen (Target, codegenRev, NativeBackend (..), NativeMode (..), tgtArc, tgtFieldWorkers, tgtFloatInline, tgtFuel, tgtFusion, tgtHal, tgtHeapProof, tgtIndexedMemory, tgtName, tgtNative, tgtPairReturns, tgtPipelineInline, tgtPolicy, tgtReuse, tgtScalarFast, tgtScalarWorkers, tgtSimd, tgtStackReport, tgtTupleScalars, tgtTypedIr, tgtWeak)
import Codegen.Policy (Policy (..), Profile (..), StackPolicy (..), policyWidth, registerBudget)
import Codegen.Target.A64 (HartAccess (..), ObjectFormat (..), a64HostedInterfaceRev, a64InterfaceRev, a64SelectionRev)
import Codegen.Target.Common (Tune (..))
import qualified Codegen.Target.RV as RV
import Codegen.Target.X64 (x64InterfaceRev, x64SelectionRev)
import Compiler.CommandLine
import Compiler.Compile.Support (posixPic)
import qualified Compiler.Options as Options
import Control.Monad (when)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

data TargetConfig = TargetConfig
  { tcPolicy :: Policy,
    tcNativeMode :: Maybe NativeMode,
    tcTarget :: Target,
    tcTargetName :: String,
    tcCacheTag :: String,
    tcRvv :: Bool,
    tcDirectFormat :: ObjectFormat,
    tcModuleFinal :: String -> String
  }

-- Validate the (profile, system, host, target, arc, raw, lib, plugin, budget)
-- matrix before parsing the prelude or loading modules.
validateProfileMatrix
  :: CompileArguments
  -> CompileArguments
  -> String -- ^ resolved profile
  -> String -- ^ resolved system
  -> Bool -- ^ esp-idf host
  -> Bool -- ^ checkOnly
  -> Maybe Integer -- ^ stackBudget
  -> Maybe Integer -- ^ heapBudget
  -> (String -> IO ()) -- ^ refuse callback
  -> IO ()
validateProfileMatrix opts0 opts profile system espHost checkOnly stackBudget heapBudget refuse = do
  case oHost opts0 of
    Just h | h /= "esp-idf" -> refuse ("--host=" ++ h ++ ": the posix system's hosts are unix (this machine, the default) and esp-idf")
    Just h | system /= "posix" -> refuse ("--host=" ++ h ++ " is a kind of posix host: it goes with --system=posix, not " ++ system)
    _ -> pure ()
  when (profile == "builtin" && system /= "bare-metal") $
    refuse ("profile builtin runs on the bare-metal system only, not " ++ system ++ " (--system=bare-metal)")
  when (espHost && (oA64 opts0 || oX64 opts0 || oQosApp opts0 || oPlugin opts0 || oRvv opts0 || tgtName (oTarget opts0) /= "rv32")) $
    refuse "--host=esp-idf is rv32 code for an ESP-IDF application: no other --target, QOS app image, plugin or RVV"
  when (system == "posix" && not espHost && tgtName (oTarget opts0) /= "rv64") $
    refuse "--system=posix on Unix requires a 64-bit target (a64, x64 or rv64)"
  when (profile == "sol" && system /= "posix") $
    refuse ("profile sol runs on the posix system (the VM: `fpr run`), not " ++ system)
  when (profile == "sol" && espHost) $
    refuse "profile sol runs on the VM (`fpr run`) on this machine, not on the esp-idf host"
  when (oBuiltin opts && (oA64 opts || oX64 opts || oQosApp opts || oRvv opts || tgtName (oTarget opts) `notElem` ["rv64", "rv32"])) $ do
    hPutStrLn stderr "profile builtin supports scalar RV64 or RV32 only"
    exitFailure
  when (oBuiltin opts && oArc opts && tgtName (oTarget opts) == "rv32") $ do
    hPutStrLn stderr "profile builtin RV32 currently supports manual ownership only; --arc/--raw/--export require RV64"
    exitFailure
  when (oBase opts && (oBuiltin opts || oQosApp opts || oRvv opts)) $ do
    hPutStrLn stderr "--system=posix supports hosted executables/modules: no builtin/arc, no QOS app image, no RVV"
    exitFailure
  when (oArc opts && not (oBuiltin opts)) $ do
    hPutStrLn stderr "--arc needs profile builtin (the raw ABI)"
    exitFailure
  when (oRaw opts && not (oArc opts)) $ do
    hPutStrLn stderr "--raw needs --arc (it is the raw ABI without the ownership instrumentation)"
    exitFailure
  when (not checkOnly && (oLib opts || not (null (oExports opts))) && not (oArc opts && oBuiltin opts)) $ do
    hPutStrLn stderr "--lib / --export need profile builtin with --arc (the raw ABI is the C ABI)"
    exitFailure
  when (oArc opts && oPlugin opts) $ do
    hPutStrLn stderr "--arc does not yet support plugin/foreign ownership boundaries"
    exitFailure
  when (isJust stackBudget && not (oBuiltin opts && oArc opts && oLib opts && not (null (oExports opts))
                                  && tgtName (oTarget opts) == "rv64" && not (oA64 opts || oX64 opts || oQosApp opts || oRvv opts))) $
    refuse "--stack-budget requires builtin RV64 --arc --lib with explicit --export entries"
  when (isJust heapBudget && not (oBuiltin opts && oArc opts && oLib opts && not (null (oExports opts))
                                  && tgtName (oTarget opts) == "rv64" && not (oA64 opts || oX64 opts || oQosApp opts || oRvv opts))) $
    refuse "--heap-budget requires builtin RV64 --arc --lib with explicit --export entries"

buildTargetConfig
  :: CompileArguments
  -> Options.CodegenOptions
  -> Options.NativeOptions
  -> Options.DiagnosticOptions
  -> Bool -- ^ espHost
  -> Maybe Integer -- ^ heapBudget
  -> M.Map String Int -- ^ halAr
  -> String -- ^ contractHash
  -> String -- ^ compilerStamp (executable fingerprint for cache invalidation)
  -> TargetConfig
buildTargetConfig opts codegen native diagnostic espHost heapBudget halAr contractHash compilerStamp =
  TargetConfig
    { tcPolicy = irPolicy,
      tcNativeMode = nativeMode,
      tcTarget = tgt,
      tcTargetName = tname,
      tcCacheTag = tag,
      tcRvv = rvv,
      tcDirectFormat = if a64mac || x64mac then MachO else ELF,
      tcModuleFinal = moduleFinal
    }
  where
    a64 = oA64 opts
    a64mac = oA64Mac opts
    x64 = oX64 opts
    x64mac = oX64Mac opts
    qapp = oQosApp opts
    qsingle = oQosSingle opts
    rvv = oRvv opts && not a64 && not x64

    irPolicy = Policy
      { polProfile = if oArc opts then BuiltinArc
                     else if oBuiltin opts then (if tgtName (oTarget opts) == "rv32" then Builtin32 else Builtin)
                     else if tgtName (oTarget opts) == "rv32" then Rv32
                     else if qapp then QosApp
                     else HostedBase,
        polFuel = not (oBuiltin opts),
        polTickBatch = Options.cgTickBatch codegen,
        polTickWeight = Options.cgTickWeight codegen,
        polStackCheck = if oBuiltin opts then StackStatic
                        else if Options.nativeShallowStack native then StackCheckShallow
                        else if Options.nativeShallowDefault native && x64 && not qapp && tgtName (oTarget opts) /= "rv32" then StackCheckShallow
                        else StackCheckEveryEntry,
        polFloatInline = Options.cgFloatInline codegen,
        polLoopMotion = Options.cgLoopMotion codegen,
        polStringScan = Options.cgStringScan codegen,
        polEarlyLoops = Options.cgEarlyLoops codegen,
        polVectorFast = Options.cgVectorFast codegen,
        polStringFast = Options.cgStringFast codegen,
        polInterval = Options.cgInterval codegen,
        polTypedCase = Options.cgTypedCase codegen,
        polBumpAlloc = Options.cgBumpAlloc codegen,
        polCompactCells = Options.cgCompactCells codegen && not (oBuiltin opts) && tgtName (oTarget opts) /= "rv32",
        polRegisters = registerBudget (if x64 then "x64" else if a64 then "a64" else tgtName (oTarget opts))
      }

    nativeMode = Just NativeMode
      { nmGranularity = Options.nativeGranularity native,
        nmStrict = Options.nativeStrict native,
        nmTargetName = if x64 then "x64" else if a64 then "a64" else tgtName (oTarget opts),
        nmBackend = if a64 && not qapp
                      then Just (DirectA64 (if a64mac then MachO else ELF) (if oBase opts then HartX28 else if a64mac then HartTlvMachO else HartTlsElf))
                      else if a64 && qapp
                        then Just (DirectA64 (if a64mac then MachO else ELF) (if qsingle then HartGlobal else HartX28))
                      else if x64 then Just (if qapp then DirectQX64 else DirectX64 (if x64mac then MachO else ELF))
                      else if not a64 && not x64 && tgtName (oTarget opts) `elem` ["rv32", "rv64"]
                              && (not qapp || tgtName (oTarget opts) == "rv64")
                        then Just (DirectRV (policyWidth irPolicy)
                                     (if espHost then RV.HartTlsEsp else if qapp then RV.HartQos else if oBase opts && oPlugin opts then RV.HartTlsIe else if oBase opts then RV.HartTls else RV.HartTp))
                      else Nothing,
        nmSelfLoops = Options.nativeSelfLoops native,
        nmForwardParams = Options.nativeForwardParams native,
        nmTune = Tune (Options.nativeEntryArgs native) (Options.nativeShrinkWrap native) (Options.nativeFpPool native) (Options.nativeLinkPairs native) (Options.nativeX64Split native),
        nmSplitEntry = Options.nativeSplitEntry native,
        nmFramelessEntry = Options.cgFramelessEntry codegen,
        nmX64Ra = Options.nativeX64Ra native
      }

    tgt = (oTarget opts)
      { tgtFuel = not (oBuiltin opts),
        tgtArc = oArc opts,
        tgtWeak = oLib opts,
        tgtHeapProof = isJust heapBudget,
        tgtStackReport = oStackReport opts || isJust (oStackBudget opts) || not (null (oExports opts)),
        tgtHal = halAr,
        tgtFloatInline = Options.cgFloatInline codegen,
        tgtSimd = (a64 || x64) && Options.cgSimd codegen,
        tgtFusion = Options.cgFusion codegen,
        tgtScalarFast = True,
        tgtIndexedMemory = Options.cgIndexedMemory codegen,
        tgtScalarWorkers = Options.cgScalarWorkers codegen,
        tgtPairReturns = Options.cgPairReturns codegen,
        tgtFieldWorkers = Options.cgFieldWorkers codegen,
        tgtTupleScalars = Options.cgTupleScalars codegen,
        tgtPipelineInline = Options.cgPipelineInline codegen,
        tgtReuse = Options.cgReuse codegen,
        tgtTypedIr = Options.diagTypedIr diagnostic,
        tgtPolicy = irPolicy,
        tgtNative = nativeMode
      }

    moduleFinal =
      if oBase opts && oPlugin opts
        then (if a64 || x64 then id else \t -> if null t then t else "    .option pic\n" ++ t) . posixPic a64 (a64mac || x64mac)
        else id

    tname0
      | qsingle = "qa64singler" ++ show a64InterfaceRev
      | a64mac && qapp = "qa64macr" ++ show a64InterfaceRev
      | a64mac = (if oPlugin opts && oBase opts then "module-" else "") ++ "a64macx28r" ++ show a64HostedInterfaceRev
      | a64 && qapp = "qa64r" ++ show a64InterfaceRev
      | a64 = "a64x28r" ++ show a64HostedInterfaceRev
      | x64 && qapp = "qx64r" ++ show x64InterfaceRev
      | x64mac = (if oPlugin opts && oBase opts then "module-" else "") ++ "x64macr" ++ show x64InterfaceRev
      | x64 = "x64r" ++ show x64InterfaceRev
      | espHost = "rv32-idftls1"
      | qapp = "qrv64r" ++ show RV.rvSelectionRev
      | oBase opts = "rv64posixr" ++ show RV.rvSelectionRev
      | otherwise = tgtName tgt

    tname = (if oBase opts && oPlugin opts then "posix-module-" else "") ++ tname0

    backendTag =
      "-tirbe" ++ (if x64 then "x64-" ++ show x64SelectionRev else if a64 then show a64SelectionRev else tgtName (oTarget opts) ++ "-" ++ show RV.rvSelectionRev)
        ++ (if a64 || x64 then "-native1" else "")
        ++ Options.nativeOptionFlags (a64 && not qapp) native

    tag =
      "g" ++ show codegenRev ++ (if null compilerStamp then "" else "-b" ++ compilerStamp)
        ++ backendTag ++ Options.optimizationFlags codegen
        ++ "rt3pc6-c" ++ take 12 contractHash ++ "-" ++ tname ++ (if rvv then "-rvv" else "")
        ++ Options.vectorOptionFlags codegen ++ (if oBuiltin opts then "-builtin" else "") ++ (if oArc opts then "-arc" ++ show arcRev else "")
