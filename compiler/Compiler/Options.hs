-- One typed interpretation of native compiler switches. Drivers snapshot the
-- environment once; lowering and both caches consume that same interpretation.
-- Compatibility spellings remain at this boundary, not in backend passes.
module Compiler.Options
  (CompilerOptions(..), CodegenOptions(..), NativeOptions(..), DiagnosticOptions(..), DriverOptions(..),
   Granularity(..), Strict(..), OptionError(..), parseCompilerOptions, readCompilerOptions,
   renderOptionError, nativeOptionFlags, optimizationFlags, vectorOptionFlags,
   codegenCacheIdentity, disableInlining) where
import Data.Bits (xor)
import Data.List (intercalate)
import Data.Word (Word64)
import Numeric (showHex)
import System.Environment (getEnvironment)
import System.Exit (exitFailure)
import System.IO (hPutStrLn,stderr)

-- Diagnostic selection granularity; CLI emission always requires complete
-- native coverage. Refusals never select another generator.
data Granularity = WholeUnit | PerFunction deriving (Eq,Show)
data Strict = StrictOff | StrictAll | StrictNames [String] deriving (Eq,Show)
data NativeOptions = NativeOptions
  { nativeGranularity :: Granularity, nativeStrict :: Strict,
    nativeSelfLoops :: Bool, nativeForwardParams :: Bool, nativeShallowStack :: Bool,
    nativeEntryArgs :: Bool, nativeSplitEntry :: Bool, nativeShrinkWrap :: Bool,
    nativeFpPool :: Bool, nativeLinkPairs :: Bool } deriving (Eq,Show)
data CodegenOptions = CodegenOptions
  { nativeOptions :: NativeOptions, cgIndexedMemory :: Bool, cgFloatInline :: Bool,
    cgSimd :: Bool, cgFusion :: Bool, cgVecPeek :: Bool, cgVectorFast :: Bool, cgStringFast :: Bool, cgInterval :: Bool, cgLoopMotion :: Bool,
    cgScalarWorkers :: Bool, cgFieldWorkers :: Bool, cgPipelineInline :: Bool,
    cgReuse :: Bool, cgSpecialize :: Bool, cgReceiveTurns :: Bool,
    cgLoopRegions :: Bool, cgCallRegions :: Bool, cgInline :: Bool } deriving (Eq,Show)
data DiagnosticOptions = DiagnosticOptions
  { diagTypedIr :: Maybe String, diagReceiveNotes :: Bool, diagApply :: Bool,
    diagPreconditions :: Bool, diagUnsafeSuggest :: Bool,
    diagCore :: Maybe String, diagNativeInsns :: Bool } deriving (Eq,Show)
data DriverOptions = DriverOptions
  { driverCC :: Maybe String, driverCostProbe :: Bool, driverNoRunCache :: Bool,
    driverForeign :: [FilePath] } deriving (Eq,Show)
data CompilerOptions = CompilerOptions
  { codegenOptions :: CodegenOptions, diagnosticOptions :: DiagnosticOptions,
    driverOptions :: DriverOptions } deriving (Eq,Show)
data OptionError = RetiredBackend | UnknownBackend String deriving (Eq,Show)

parseCompilerOptions :: (String -> Maybe String) -> Either OptionError CompilerOptions
parseCompilerOptions env = do
  granularity<-case env "FPR_TYPED_IR_BACKEND" of
    Nothing->Right PerFunction
    Just s | s `elem` ["","mixed"]->Right PerFunction
    Just "1"->Right WholeUnit
    Just s | s `elem` ["legacy","0","off"]->Left RetiredBackend
    Just s->Left (UnknownBackend s)
  let strict=case env "FPR_TYPED_IR_STRICT" of
        Nothing->StrictOff; Just ""->StrictOff; Just "all"->StrictAll
        Just names->StrictNames (filter (not . null) (split ',' names))
      native=NativeOptions
        { nativeGranularity=granularity, nativeStrict=strict,
          nativeSelfLoops=on "FPR_TYPED_IR_SELF_LOOPS", nativeForwardParams=yes "FPR_TYPED_IR_FORWARD_PARAMS",
          nativeShallowStack=yes "FPR_TYPED_IR_SHALLOW_STACK", nativeEntryArgs=yes "FPR_TYPED_IR_ENTRY_ARGS",
          nativeSplitEntry=yes "FPR_TYPED_IR_SPLIT_ENTRY", nativeShrinkWrap=yes "FPR_TYPED_IR_SHRINK_WRAP",
          nativeFpPool=on "FPR_TYPED_IR_FP_POOL", nativeLinkPairs=on "FPR_TYPED_IR_LINK_PAIRS" }
      codegen=CodegenOptions
        { nativeOptions=native, cgIndexedMemory=enabled "INDEXED_MEMORY", cgFloatInline=enabled "F64_INLINE",
          cgSimd=enabled "VEC_SIMD", cgFusion=enabled "VEC_FUSE", cgVecPeek=enabled "VEC_PEEK", cgVectorFast=enabled "VEC_FAST", cgStringFast=enabled "STR_FAST", cgInterval=enabled "INTERVAL", cgLoopMotion=yes "FPR_TYPED_IR_LOOP_MOTION",
          cgScalarWorkers=enabled "SCALAR_WORKERS", cgFieldWorkers=enabled "FIELD_WORKERS",
          cgPipelineInline=enabled "PIPELINE_INLINE", cgReuse=enabled "REUSE", cgSpecialize=enabled "SPEC",
          cgReceiveTurns=enabled "RECEIVE_TURNS", cgLoopRegions=enabled "LOOP_REGIONS",
          cgCallRegions=enabled "CALL_REGIONS", cgInline=enabled "INLINE" }
      diagnostic=DiagnosticOptions
        { diagTypedIr=env "FPR_TYPED_IR", diagReceiveNotes=yes "FPR_RECEIVE_NOTES",
          diagApply=yes "FPRC_APPLY", diagPreconditions=yes "FPR_PRECOND_NOTES",
          diagUnsafeSuggest=yes "FPR_UNSAFE_SUGGEST", diagCore=env "FPR_DUMP_CORE",
          diagNativeInsns=yes "FPRC_NATIVE_INSNS" }
      driver=DriverOptions
        { driverCC=env "FPR_CC", driverCostProbe=yes "FPR_COST_PROBE",
          driverNoRunCache=maybe False (not . null) (env "FPR_NO_RUN_CACHE"),
          driverForeign=maybe [] (filter (not . null) . split ':') (env "FPR_FOREIGN") }
  pure (CompilerOptions codegen diagnostic driver)
  where
    yes n=env n==Just "1"
    on n=env n/=Just "0"
    enabled n=not (yes ("FPR_NO_"++n))

readCompilerOptions :: IO CompilerOptions
readCompilerOptions = do
  env<-getEnvironment
  either (\e -> hPutStrLn stderr (renderOptionError e) >> exitFailure) pure
    (parseCompilerOptions (`lookup` env))

renderOptionError :: OptionError -> String
renderOptionError RetiredBackend = "error: the legacy backend has been retired on every target; unset FPR_TYPED_IR_BACKEND or select mixed or 1"
renderOptionError (UnknownBackend value) = "FPR_TYPED_IR_BACKEND="++value++": expected mixed (per function, the default), 1 (whole units) "

-- CLI and environment combine before either lowering or unit-cache identity.
disableInlining :: Bool -> CompilerOptions -> CompilerOptions
disableInlining disabled options = options {codegenOptions=cg {cgInline=cgInline cg && not disabled}}
  where cg=codegenOptions options

-- Existing unit-key spelling is stable. Build's executable cache uses these
-- same renderers, so a newly added unit-mode flag cannot be omitted there.
-- FP pooling is target-dependent; the run cache conservatively records it.
nativeOptionFlags :: Bool -> NativeOptions -> String
nativeOptionFlags fpAvailable n =
  (if nativeGranularity n==PerFunction then "mixed" else "")
  ++ flag (fpAvailable && nativeFpPool n) "-fpregs"
  ++ flag (not (nativeSelfLoops n)) "-noloops"
  ++ flag (nativeShallowStack n) "-shallow"
  ++ flag (nativeForwardParams n) "-forward"
  ++ flag (nativeEntryArgs n) "-entryargs"
  ++ flag (nativeSplitEntry n) "-split"
  ++ flag (nativeShrinkWrap n) "-wrap"
  ++ flag (not (nativeLinkPairs n)) "-nolinkpairs"
  ++ case nativeStrict n of
    StrictOff->""; StrictAll->"-strictall"
    StrictNames names->"-strict"++take 12 (showHex (fnv (intercalate "," names)) "")

optimizationFlags :: CodegenOptions -> String
optimizationFlags c = flag (cgLoopMotion c) "-licm" ++ concat
  [flag (not enabled) suffix | (enabled,suffix)<-
    [(cgPipelineInline c,"-nopinline"),(cgReuse c,"-noreuse"),
     (cgScalarWorkers c,"-noscalar"),(cgFieldWorkers c,"-nofields"),
     (cgIndexedMemory c,"-noidx"),(cgReceiveTurns c,"-nort"),
     (cgLoopRegions c,"-nolr"),(cgCallRegions c,"-nocr"),
     (cgSpecialize c,"-nospec"),(cgInline c,"-noinl"),
     (cgFloatInline c,"-nof64"),(cgVecPeek c,"-novp"),(cgVectorFast c,"-novecfast"),(cgStringFast c,"-nostrfast"),(cgInterval c,"-nointerval")]]
vectorOptionFlags :: CodegenOptions -> String
vectorOptionFlags c = flag (not (cgSimd c)) "-nosimd" ++ flag (not (cgFusion c)) "-nofuse"
codegenCacheIdentity :: CodegenOptions -> String
codegenCacheIdentity c = "compiler-options-v1:" ++ nativeOptionFlags True (nativeOptions c)
  ++ optimizationFlags c ++ vectorOptionFlags c

flag :: Bool -> String -> String
flag enabled text = if enabled then text else ""
fnv :: String -> Word64
fnv = foldl (\h c -> (h `xor` fromIntegral (fromEnum c)) * 1099511628211) 14695981039346656037
split :: Char -> String -> [String]
split sep s=case break (==sep) s of (a,[])->[a]; (a,_:rest)->a:split sep rest
