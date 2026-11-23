module Compiler.Compile.TypedReport
  ( prepareTypedInput,
    reportTypedLowering,
    directCheck,
    checkBuiltinWidth,
    reportTurns,
  )
where

import Codegen (Emission (..), Target (..), TypedUse (..), foreignEntries, normalizesLiterals, tgtName, tgtPolicy)
import Codegen.IR (Fn)
import Compiler.CommandLine (CompileArguments (..))
import qualified Compiler.Native.Core as NativeCore
import qualified Compiler.Native.Regions as Regions
import qualified Compiler.Native.TypedLowering as TypedLowering
import qualified Compiler.Options as Options
import Control.Monad (forM_, unless, when)
import qualified Core.Alpha as Alpha
import Core.Syntax (Core (..), Prog)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Lazy as ML
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Set as S
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- The manual Builtin RV32 runtime does not provide Base's boxed numeric
-- ABI. Refuse before code generation, including imported definitions and
-- unsaturated primitives. Base RV32 supports these through runtime boxes.
builtinWideFloat :: Core -> Bool
builtinWideFloat = coreHasName $ \n ->
  any (`isPrefixOf` n) ["F64.", "F32.", "I64."]
    || n `elem` ["f64frombits", "f32frombits"]
    || i32WidePrimitive n

i32WidePrimitive :: String -> Bool
i32WidePrimitive n =
  n `elem` map ("I32." ++)
    [ "ofI64", "toI64", "toI64U", "ofF32", "ofF32U", "ofF64", "ofF64U",
      "toF32", "toF32U", "toF64", "toF64U", "ofF32Bits", "toF32Bits"
    ]

coreHasName :: (String -> Bool) -> Core -> Bool
coreHasName test e = case e of
  CVar n -> test n
  CApp f a -> coreHasName test f || coreHasName test a
  CLam _ b -> coreHasName test b
  CLet _ a b -> coreHasName test a || coreHasName test b
  CIf c a b -> any (coreHasName test) [c, a, b]
  CMk _ _ xs -> any (coreHasName test) xs
  CTagEq _ _ a -> coreHasName test a
  CProj _ a -> coreHasName test a
  _ -> False

checkBuiltinWidth :: CompileArguments -> Prog -> IO ()
checkBuiltinWidth opts p = do
  when (oArc opts && any (coreHasName i32WidePrimitive . snd) (M.elems p)) $ do
    hPutStrLn stderr "I32 conversions with I64/F32/F64 currently require the manual ABI; --arc/--raw bridge ownership adapters are not implemented"
    exitFailure
  when (oBuiltin opts && tgtName (oTarget opts) == "rv32" && any (builtinWideFloat . snd) (M.elems p)) $ do
    hPutStrLn stderr "profile builtin RV32: F64 and I64 require a 64-bit value ABI; F32 also requires the boxed Base runtime; I32 wide conversions require Base"
    exitFailure

directCheck :: String -> Emission -> IO ()
directCheck what emission = do
  strictCheck what (emScalarFallbacks emission)
  strictCheck what (emRefusals emission)
  where
    strictCheck label fallbacks = unless (null fallbacks) $ do
      hPutStrLn stderr ("typed-ir strict: " ++ label ++ ": " ++ show (length fallbacks) ++ " function(s) did not take the native backend:")
      mapM_ (\(n, r) -> hPutStrLn stderr ("  " ++ n ++ ": " ++ r)) fallbacks
      exitFailure

-- --cost: every boundary placed, by rule, and a count of the pure
-- groups declined; FPR_RECEIVE_NOTES=1 lists the declined ones too
-- (docs/2026-10-24-REGIONS-STAGE2.md)
reportTurns :: CompileArguments -> Options.CodegenOptions -> Options.DiagnosticOptions -> Regions.Result -> IO ()
reportTurns opts codegen diagnostic result =
  when (Options.diagReceiveNotes diagnostic || oCost opts) $ do
    let ns = Regions.resultNotes result
        declined = [n | n <- ns, "turn-regions (declined): " `isPrefixOf` n]
    mapM_ (hPutStrLn stderr) (if Options.diagReceiveNotes diagnostic then ns else filter (`notElem` declined) ns)
    when (not (Options.diagReceiveNotes diagnostic) && not (null declined)) $
      hPutStrLn stderr ("turn-regions: " ++ show (length declined) ++ " self-tail-call group(s) declined (unbounded or unproven state); FPR_RECEIVE_NOTES=1 lists them")
    when (not (Options.cgLoopRegions codegen) && any ("turn-regions (candidate): " `isPrefixOf`) ns) $
      hPutStrLn stderr "turn-regions: the candidates above are not placed (FPR_NO_LOOP_REGIONS=1)"

-- P2 typed lowering (docs/2026-11-08-P2-TYPED-LOWERING-SLICE-1.md):
-- slice 2 emits every S1 function from its typed lowering where the
-- erased lowering of the same function agrees; a disagreement stops
-- the compile. FPR_NO_TYPED_LOWER=1 emits the erased functions.
prepareTypedInput :: Target -> Regions.Result -> S.Set String -> M.Map String Int -> Prog -> IO (TypedLowering.Lowered, M.Map String (Fn, ([String], Core)), S.Set String)
prepareTypedInput linkedTgt result emitted extArities local = do
  skip <- (== Just "1") <$> lookupEnv "FPR_NO_TYPED_LOWER"
  let placedNames = Regions.resultPlacedNames result
      lowered =
        TypedLowering.typedFunctions
          (normalizesLiterals linkedTgt)
          (tgtPolicy linkedTgt)
          extArities
          (foreignEntries linkedTgt)
          (Regions.resultNative result)
          (Regions.resultTyped result)
          placedNames
          emitted
          local
  pure
    ( lowered,
      if skip then M.empty else ML.intersectionWith (,) (TypedLowering.loweredFns lowered) (TypedLowering.loweredCores lowered),
      placedNames `S.difference` TypedLowering.loweredPlaced lowered
    )

reportTypedLowering :: Target -> TypedLowering.Lowered -> Regions.Result -> S.Set String -> M.Map String Int -> String -> [(String, M.Map String ([String], Core))] -> Emission -> IO ()
reportTypedLowering linkedTgt lowered result emitted extArities label stages emission = do
  putStrLn (TypedLowering.loweredCensus lowered ++ " unit=" ++ label)
  let use = emTypedUse emission
      n = show . length
  skip <- (== Just "1") <$> lookupEnv "FPR_NO_TYPED_LOWER"
  unless skip $ do
    putStrLn
      ( "# typed lowering: s1=" ++ show (TypedLowering.loweredS1 lowered)
          ++ " typed=" ++ n (tuTyped use)
          ++ " regions=" ++ show (S.size (TypedLowering.loweredPlaced lowered))
          ++ " worker=" ++ n (tuWorker use)
          ++ " reuse=" ++ n (tuReuse use)
          ++ " optimized=" ++ n (tuOptimized use)
          ++ " placed=" ++ n (tuPlaced use)
          ++ " arc=" ++ n (tuArc use)
          ++ " absent=" ++ n (tuAbsent use)
          ++ " refused=" ++ n (TypedLowering.loweredRefused lowered)
          ++ concat
            [ " refused_by=" ++ intercalate ";" (take 3 [f ++ ":" ++ why | (f, why) <- TypedLowering.loweredRefused lowered])
              | not (null (TypedLowering.loweredRefused lowered))
            ]
          ++ " unit=" ++ label
      )
    unless (null (tuDisagree use)) $ do
      mapM_ (\(f, e, t) -> hPutStrLn stderr ("typed lowering disagreement: " ++ f ++ ": " ++ TypedLowering.firstDifference e t)) (tuDisagree use)
      exitFailure
  -- where the optimizer reshaped an S1 function: the first place the
  -- plan's Core and the Core the erased lowering was given differ
  showOptimized <- (== Just "1") <$> lookupEnv "FPR_TYPED_LOWER_OPTIMIZED"
  when (showOptimized && not skip) $
    forM_ (tuOptimized use) $ \f ->
      forM_ ((,) <$> M.lookup f (TypedLowering.loweredCores lowered) <*> M.lookup f (emEligible emission)) $ \(planned, eligible) -> do
        when (Alpha.rewriteKind (snd (comparableCore planned)) (snd (comparableCore eligible)) == "same") $
          forM_ ((,) <$> M.lookup f (emLowered emission) <*> M.lookup f (TypedLowering.loweredFns lowered)) $ \(e, t) ->
            putStrLn ("# typed lowering optimized-fn " ++ f ++ ": " ++ take 4000 (TypedLowering.firstDifference e t))
        let raw (ps, b) = Alpha.canonical (ps, Alpha.substituteLiterals b)
            kind = Alpha.rewriteKind (snd (comparableCore planned)) (snd (comparableCore eligible))
            diff = if kind == "same" then Alpha.firstTextDifference (raw planned) (raw eligible) else Alpha.firstTextDifference (comparableCore planned) (comparableCore eligible)
        putStrLn ("# typed lowering optimized " ++ f ++ ": " ++ kind ++ "; " ++ diff)
  -- slice 2 count: where the emitted bodies of the S1 functions change
  traceStages <- (== Just "1") <$> lookupEnv "FPR_TYPED_LOWER_STAGES"
  showName <- lookupEnv "FPR_TYPED_LOWER_STAGES_SHOW"
  when (traceStages || isJust showName) $ do
    let report =
          TypedLowering.check
            (normalizesLiterals linkedTgt)
            (tgtPolicy linkedTgt)
            extArities
            (foreignEntries linkedTgt)
            (Regions.resultNative result)
            emitted
        allStages = stages ++ [("optimized", emOptimized emission), ("eligible", emEligible emission)]
    when traceStages $ putStrLn (TypedLowering.stagesNote report allStages (emLowered emission) ++ " unit=" ++ label)
    forM_ showName $ \f -> when (M.member f (NativeCore.nativeDefinitions (Regions.resultNative result))) $ do
      forM_ (M.lookup f (TypedLowering.reportAgreedFns report)) $ \(def, _) ->
        putStrLn ("# stage boundary " ++ f ++ ": " ++ show def)
      forM_ allStages $ \(l, p) ->
        putStrLn ("# stage " ++ l ++ " " ++ f ++ ": " ++ maybe "absent" show (M.lookup f p))
      putStrLn ("# stage typed-fn " ++ f ++ ": " ++ maybe "absent" show (M.lookup f (TypedLowering.loweredFns lowered)))
      putStrLn ("# stage lowered-fn " ++ f ++ ": " ++ maybe "absent" show (M.lookup f (emLowered emission)))

comparableCore :: ([String], Core) -> ([String], Core)
comparableCore (ps, b) = Alpha.canonical (ps, Alpha.diagnosticNormal ps (Alpha.substituteLiterals b))
