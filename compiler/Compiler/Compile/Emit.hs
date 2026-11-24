{-# LANGUAGE LambdaCase #-}
module Compiler.Compile.Emit
  ( EmitInputs (..),
    emitNative,
  )
where

import Arc (arcExterns, lowerArcWithProductEvidence, lowerRawWithProductEvidence)
import Codegen
  ( Emission (..),
    NativeMode (..),
    codegenRev,
    emitTypedProductProgramWithImports,
    externals,
    productBackendWidth,
    tgtMapBodies,
    tgtName,
    tgtPoolResetters,
    tgtSpineBuilders,
  )
import qualified Codegen as Backend (tgtW)
import Codegen.Export.Plan (FloatABI (..))
import qualified Codegen.Heap as Heap
import Codegen.Selected (CodeSymbol (..))
import qualified Codegen.Stack as Stack
import Codegen.Target.Common (dataSyntax, functionSymbol)
import Codegen.Target.RV.Export (adapterHeap, adapterStack, renderAdapter)
import Compiler.CommandLine (CompileArguments (..))
import Compiler.Compile.Link (linkAndOptimize)
import Compiler.Compile.Support (arities, bindNames, fst3, nativeSummary, phaseTime, symbolize, writeWhole)
import Compiler.Compile.Tables (renderRootTables)
import Compiler.Compile.Target (TargetConfig (..), buildTargetConfig)
import Compiler.Compile.TypedReport (checkBuiltinWidth, directCheck, prepareTypedInput, reportTurns, reportTypedLowering)
import Compiler.DataLayout (i64StoreAt)
import qualified Compiler.CallableReport as CallableReport
import qualified Compiler.Native.Core as NativeCore
import qualified Compiler.Native.Exports as Exports
import qualified Compiler.Native.Imports as NativeImports
import qualified Compiler.Native.Linked as Linked
import qualified Compiler.Native.Regions as Regions
import qualified Compiler.Native.Regions.Typed as TypedRegions
import qualified Compiler.Native.Representation as NativeRep
import qualified Compiler.Options as Options
import qualified Compiler.Remarks as Remarks
import Control.Monad (forM, forM_, unless, when)
import Core.CacheIdentity (CallArities (..), coreCacheIdentityWithBuilders)
import Core.Opt.Normalize (normArc)
import Core.Opt.ProductParameters (withImportedVariantResults, withoutVariantResults)
import Core.Opt.Representation (eraseLayoutCasts)
import Core.Syntax (Core (..), Name)
import Core.Typed.Callback (CallbackMode (..))
import qualified Core.Typed.Syntax as TCore
import qualified Core.VectorRead as VectorRead
import Data.List (isPrefixOf)
import qualified Data.List as List
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Diagnostic.Remark as Remark
import Frontend.Desugar.Typed (CheckedPlans, CheckedUnit, SourceSelection, checkedCallArities, selectCheckedUnit)
import Frontend.Syntax (STop (..))
import Frontend.Traverse (stripPosTops)
import Infer (builtinEnv, canonicalTypeWith)
import Inline (inlineCompatibilityWithImports, inlineSmall, vecPeekCompatibility)
import Modules (ModExport (..), hashAST)
import Mono (qualifyAux, specializeCompatibilityWithProducts)
import Precond (PreTable, checkedName)
import Reuse (mapBodiesOf, poolResetters, spineBuilders)
import Safety (measureCheck)
import Control.Exception (SomeException, try)
import Data.Bits (xor)
import Data.Char (ord)
import Data.Word (Word64)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize, getModificationTime)
import System.Environment (getExecutablePath)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import Type.Syntax (Scheme (..), Type (..))

data EmitInputs = EmitInputs
  { eiOpts :: CompileArguments,
    eiCodegen :: Options.CodegenOptions,
    eiNative :: Options.NativeOptions,
    eiDiagnostic :: Options.DiagnosticOptions,
    eiEspHost :: Bool,
    eiRemarkMode :: Remark.Mode,
    eiStackBudget :: Maybe Integer,
    eiHeapBudget :: Maybe Integer,
    eiOut :: FilePath,
    eiSources :: M.Map FilePath String,
    eiAnchors :: M.Map Name (FilePath, Int),
    eiExports :: [ModExport],
    eiPreTab :: PreTable,
    eiInterfaces :: [(Name, Type)],
    eiInterfaceName :: Name -> Name,
    eiTops :: [STop],
    eiTops0RL :: [STop],
    eiFinalTops :: [STop],
    eiPreludeTops :: [STop],
    eiForeignTops :: [STop],
    eiPreludeE' :: [STop],
    eiPreludeHash :: String,
    eiRoot' :: [STop],
    eiRoot'' :: [STop],
    eiRootHash :: String,
    eiUnits' :: [(String, [STop])],
    eiCheckedLowering :: CheckedPlans,
    eiConsAll :: M.Map Name (Int, Int, Int),
    eiShapes :: M.Map [Name] Int,
    eiRawAll :: M.Map (Int, Int) (Integer, Integer, Integer),
    eiI64All :: M.Map Name [Int],
    eiPreludeEmitted :: Bool,
    eiUnitsEmitted :: Bool,
    eiAllCons :: S.Set Name,
    eiRootCons :: S.Set Name,
    eiRootElided :: S.Set Name,
    eiPreludeCons :: S.Set Name,
    eiPreludeElided :: S.Set Name,
    eiUnitConsOf :: String -> S.Set Name,
    eiUnitElided :: String -> S.Set Name,
    eiPinnedTypeSpec :: S.Set Name,
    eiCallbackMode :: CallbackMode,
    eiCompileSelected :: String -> CallbackMode -> Either String SourceSelection -> NativeCore.NativeCore,
    eiSelectRoot :: [STop] -> Either String SourceSelection,
    eiNativeUnit :: String -> S.Set Name -> CheckedUnit -> NativeCore.NativeCore,
    eiPrepareRegions :: NativeCore.NativeCore -> Regions.Program
  }

-- Fast, zero-allocation-overhead executable fingerprint (size + mtime) so
-- rebuilding ./fpr invalidates unit caches automatically without bumping
-- codegenRev (which stays the explicit binary/module ABI revision).
compilerBinaryStamp :: IO String
compilerBinaryStamp = do
  res <- tryAny $ do
    exe <- getExecutablePath
    sz <- getFileSize exe
    mt <- getModificationTime exe
    let raw = show sz ++ ":" ++ show mt
        h = foldl (\acc c -> (acc `xor` fromIntegral (ord c)) * 1099511628211) (14695981039346656037 :: Word64) raw
        hex = showHex h ""
    pure (replicate (max 0 (12 - length hex)) '0' ++ take 12 hex)
  pure (either (const "") id res)
  where
    tryAny :: IO a -> IO (Either SomeException a)
    tryAny = try

emitNative :: EmitInputs -> IO ()
emitNative ei = do
  compilerStamp <- compilerBinaryStamp
  let opts = eiOpts ei
      codegen = eiCodegen ei
      native = eiNative ei
      diagnostic = eiDiagnostic ei
      espHost = eiEspHost ei
      remarkMode = eiRemarkMode ei
      stackBudget = eiStackBudget ei
      heapBudget = eiHeapBudget ei
      out = eiOut ei
      sources = eiSources ei
      anchors = eiAnchors ei
      exports = eiExports ei
      preTab = eiPreTab ei
      interfaces = eiInterfaces ei
      interfaceName = eiInterfaceName ei
      tops = eiTops ei
      tops0RL = eiTops0RL ei
      finalTops = eiFinalTops ei
      preludeTops = eiPreludeTops ei
      foreignTops = eiForeignTops ei
      preludeE' = eiPreludeE' ei
      preludeHash = eiPreludeHash ei
      root' = eiRoot' ei
      root'' = eiRoot'' ei
      rootHash = eiRootHash ei
      units' = eiUnits' ei
      checkedLowering = eiCheckedLowering ei
      consAll = eiConsAll ei
      shapes = eiShapes ei
      rawAll = eiRawAll ei
      i64All = eiI64All ei
      preludeEmitted = eiPreludeEmitted ei
      unitsEmitted = eiUnitsEmitted ei
      allCons = eiAllCons ei
      rootCons = eiRootCons ei
      rootElided = eiRootElided ei
      preludeCons = eiPreludeCons ei
      preludeElided = eiPreludeElided ei
      unitConsOf = eiUnitConsOf ei
      unitElided = eiUnitElided ei
      pinnedTypeSpec = eiPinnedTypeSpec ei
      callbackMode = eiCallbackMode ei
      compileSelected = eiCompileSelected ei
      selectRoot = eiSelectRoot ei
      nativeUnit = eiNativeUnit ei
      prepareRegions = eiPrepareRegions ei
      timed = phaseTime (Options.diagTimings diagnostic)
      owned uts = either error id (selectCheckedUnit checkedLowering (bindNames uts))
      preludeChecked = owned preludeE'
      checkedUnits = [(h, uts, owned uts) | (h, uts) <- units']
      reportTurnsOf = reportTurns opts codegen diagnostic
      typedInput = prepareTypedInput linkedTgt
      typedLowering = reportTypedLowering linkedTgt
      checkWidth = checkBuiltinWidth opts
      -- Checked entries can be owned by the root (including contracts
      -- added to prelude functions). Every unit also needs the physical
      -- arity of any checked global it references, including root entries.
      checkedExt = arities [t | t@(TBind n _ _ _) <- finalTops, "$precond" `isPrefixOf` n]
      sourceExt = M.union checkedExt (checkedCallArities checkedLowering)
      extFor = M.union (if oArc opts then arcExterns else M.empty) sourceExt
      halAr =
        M.unions
          [ M.fromList [(n, length as) | TSig n (as, _) _ <- preludeE' ++ concatMap snd units' ++ root'],
            M.map (\(Forall _ _ t) -> arrows t) builtinEnv,
            M.fromList
              ( [("$callActive", 1) | oBase opts]
                  ++ VectorRead.peekArities
                  ++ [ ("$receiveLoop", 2), ("$regionSeq", 1), ("$regionOpen", 1), ("$regionMark", 1),
                       ("$regionRoom", 1), ("$receiveReady", 2), ("$regionCycle", 2), ("$loopLeave", 2),
                       ("$callPend", 1), ("$callLeave", 2), ("$fnIs", 2) ]
              )
          ]
      arrows (TFn _ r) = 1 + arrows r
      arrows _ = 0 :: Int
      contractHash = hashAST [t | t@(TSig n _ _) <- tops, M.member n preTab]
      targetCfg = buildTargetConfig opts codegen native diagnostic espHost heapBudget halAr contractHash compilerStamp
      tgt = tcTarget targetCfg
      irPolicy = tcPolicy targetCfg
      nativeMode = tcNativeMode targetCfg
      tname = tcTargetName targetCfg
      tag = tcCacheTag targetCfg
      rvv = tcRvv targetCfg
      moduleFinal = tcModuleFinal targetCfg
      spec = True
      unitDir = takeDirectory out </> "units"
      arcPrepared = NativeRep.prepareFor (not (oRaw opts)) (Linked.artifactCore (artifactOf Linked.RootArtifact))
      arcSignatures = fmap (\(signatures, layouts, _, _) -> (signatures, layouts)) arcPrepared
      own = ownWith M.empty
      ownWith imports prog =
        if oArc opts
          then do
            (signatures, layouts, evidence, _) <- either (\e -> hPutStrLn stderr e >> exitFailure) pure arcPrepared
            (lowered, declined) <-
              either
                (\e -> hPutStrLn stderr e >> exitFailure)
                (\(p, d) -> pure (inlineSmall 3 24 p, d))
                ( ( (if oRaw opts then lowerRawWithProductEvidence else lowerArcWithProductEvidence)
                      (if Options.cgPairReturns codegen then productBackendWidth (nativeMode >>= nmBackend) else 0)
                  )
                    evidence
                    layouts
                    (Options.cgTypeSpec codegen)
                    pinnedTypeSpec
                    (M.restrictKeys signatures (M.keysSet prog))
                    sourceExt
                    prog
                )
            when (remarkMode /= Remark.Off) $
              forM_ declined $ \(fn, why) ->
                hPutStrLn stderr ("remark[type-spec] " ++ fn ++ ": " ++ why)
            let dump = Options.diagCore diagnostic
            forM_ [(n, d) | Just want <- [dump], (n, d) <- M.toList lowered, takeWhile (/= '@') n == want] $ \(n, d) ->
              hPutStrLn stderr ("core " ++ n ++ ": " ++ show d ++ "\nnormalized: " ++ show (fmap normArc d))
            pure lowered
          else do
            let inl =
                  (if oNoInline opts then id else inlineCompatibilityWithImports checkedCallbackTargets imports pureOutside 3 24)
                    (if not (Options.cgVecPeek codegen) then prog else vecPeekCompatibility checkedCallbackTargets prog)
            let dump = Options.diagCore diagnostic
            forM_ [(n, d) | Just want <- [dump], (n, d) <- M.toList inl, takeWhile (/= '@') n == want] $ \(n, d) ->
              hPutStrLn stderr ("core " ++ n ++ ": " ++ show d)
            pure inl
      pureOutside g = maybe False (> 0) (M.lookup g extFor) || maybe False (> 0) (M.lookup g halAr) || g `elem` corePrimNames
      corePrimNames = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">=", "strcat", "str", "String.len"]
      resultProducts placed = (if Options.cgTypeSpec codegen && oBase opts then id else withoutVariantResults) (Regions.resultProductParameters placed)
      mono products ns ext p = if not (Options.cgSpecialize codegen) || oArc opts then (p, products) else specializeCompatibilityWithProducts products checkedCallbackTargets importedPrivateNames ns halAr ext p
      checkedCallbackTargets =
        typedRegionNames
          `S.union` S.fromList
            [ name
              | (_, Linked.SymbolOwner _ definition) <- M.toList (Linked.linkedSymbols linked),
                name <- case definition of
                  Linked.SourceDefinition n _ _ -> [n]
                  Linked.PrivateDefinition _ (TCore.CodeId n) _ -> [n]
                  _ -> []
            ]
      typedRegionNames = S.unions [M.keysSet (TypedRegions.programFunctions p) | p <- M.elems typedRegionPrograms]
      rootNames = S.fromList [fst3 b | b@(TBind {}) <- root']
      rootLoweredNames = bindNames root''
      unitNames = S.fromList (concat [[fst3 b | b@(TBind {}) <- uts] | (_, uts) <- units'])
      preludeNames = bindNames preludeE'
      rootProgTops =
        [ t
          | t@(TBind n _ _ _) <- finalTops,
            S.member n rootLoweredNames
              || (not (S.member n unitNames) && not (S.member n preludeNames))
        ]
      rootNative = compileSelected ("root." ++ rootHash) PreserveCallbacks (selectRoot (if oArc opts then finalTops else rootProgTops))
      artifactResults =
        Linked.artifact
          Linked.RootArtifact
          (if oArc opts then M.keysSet (NativeCore.nativeProgram rootNative) else bindNames root'' `S.union` rootCons)
          (if oArc opts then S.empty else rootElided)
          rootNative
          : [ Linked.artifact
                (Linked.PreludeArtifact preludeHash)
                (bindNames preludeE' `S.union` preludeCons)
                preludeElided
                (nativeUnit ("prelude." ++ preludeHash) preludeCons preludeChecked)
              | preludeEmitted
            ]
          ++ [ Linked.artifact
                 (Linked.DependencyArtifact h)
                 (bindNames uts `S.union` unitConsOf h)
                 (unitElided h)
                 (nativeUnit ("unit." ++ h) (unitConsOf h) unit)
               | (h, uts, unit) <- checkedUnits,
                 unitsEmitted
             ]
      linkedResult = linkAndOptimize opts codegen irPolicy remarkMode callbackMode artifactResults
      (linked, fusionNotes, trmcNotes) = either error id linkedResult
      declarationsResult = do
        (verified, _, _) <- linkedResult
        base <- NativeImports.codeDeclarations verified
        NativeImports.withRegions typedRegionPrograms base
      declarations = either error id declarationsResult
      artifactOf key = Linked.linkedArtifacts linked M.! key
      artifactRaw = prepareRegions . Linked.artifactCore
      regionInputs = M.map artifactRaw (Linked.linkedArtifacts linked)
      regionArtifacts =
        if oBuiltin opts || oArc opts || not (Options.cgReceiveTurns codegen)
          then M.map Regions.bypass regionInputs
          else
            either
              error
              id
              ( Regions.placePrograms
                  ( Regions.Options
                      (Options.cgLoopRegions codegen)
                      (Options.cgCallRegions codegen)
                      True
                      (if oQosApp opts || oBuiltin opts then Nothing else Options.cgPersistentLoop codegen)
                      (Backend.tgtW (oTarget opts) == 8)
                  )
                  (fst (measureCheck tops))
                  regionInputs
              )
      typedRegionPrograms = M.mapMaybe Regions.resultTyped regionArtifacts
      artifactRegions key = regionArtifacts M.! key
      ready templates key exps prog =
        either (\reason -> hPutStrLn stderr reason >> exitFailure) pure (NativeImports.prepareEmissionWithImports templates declarations key exps prog)
      importedPrivateNames =
        S.unions
          [ NativeImports.preservedCode declarations key
            | key <- M.keys (Linked.linkedArtifacts linked),
              key /= Linked.RootArtifact
          ]
      rootProgRaw =
        if oArc opts
          then either error (\(_, _, _, p) -> eraseLayoutCasts p) arcPrepared
          else Regions.resultProgram (artifactRegions Linked.RootArtifact)
      linkedProgram = M.unions [Regions.resultProgram (artifactRegions key) | key <- M.keys (Linked.linkedArtifacts linked)]
      resetting = poolResetters linkedProgram
      linkedTgt =
        tgt
          { tgtPoolResetters = resetting,
            tgtSpineBuilders = M.filterWithKey (\name _ -> '@' `elem` name) (spineBuilders resetting (linkedProgram `M.union` erasedConstructorStubs linkedProgram)),
            tgtMapBodies = mapBodiesOf linkedProgram
          }
      importedCore =
        M.unions
          [ qualifyAux
              (prefix key)
              (Linked.artifactExports a `S.union` allCons `S.union` NativeImports.preservedCode declarations key)
              (Regions.resultProgram (artifactRegions key))
            | (key, a) <- M.toList (Linked.linkedArtifacts linked),
              key /= Linked.RootArtifact
          ]
      prefix (Linked.PreludeArtifact h) = "$specaux.p" ++ take 12 h ++ "."
      prefix (Linked.DependencyArtifact h) = "$specaux.u" ++ take 12 h ++ "."
      prefix Linked.RootArtifact = error "native link: root is not an imported artifact"
      applyReport label asm =
        when (Options.diagApply diagnostic || isJust (oCallables opts)) $
          hPutStrLn
            stderr
            ( "apply "
                ++ label
                ++ ": dispatch="
                ++ show (length [() | l <- lines asm, "fpr_apply" `List.isInfixOf` l, any (`List.isInfixOf` l) ["call ", "bl "]])
                ++ " known-partial="
                ++ show (length [() | l <- lines asm, "# pap-create:" `List.isPrefixOf` l])
                ++ " static-descriptors="
                ++ show (length [() | l <- lines asm, "# static-pap:" `List.isPrefixOf` l])
            )
      erasedConstructorStubs prog =
        M.fromList
          [ ( name,
              if arity == 0
                then ([], CMk tid var [])
                else (params, CMk tid var (i64StoreAt (M.findWithDefault [] name i64All) (map CVar params)))
            )
            | (name, (tid, var, arity)) <- M.toList consAll,
              M.notMember name prog,
              let params = ["x" ++ show i | i <- [1 .. arity]]
          ]
      emitUnit pathBase ext artifact = do
        let placed = artifactRegions (Linked.artifactId artifact)
            exps = Linked.artifactExports artifact
            elide = Linked.artifactElided artifact
            unitProgram = Regions.resultProgram placed
            unitProducts = resultProducts placed
            path =
              pathBase
                ++ "-c"
                ++ coreCacheIdentityWithBuilders (tgtSpineBuilders linkedTgt) unitProducts (tgtPoolResetters linkedTgt) elide (CallArities ext halAr) unitProgram
                ++ "-"
                ++ tag
                ++ ".s"
        reportTurnsOf placed
        checkWidth unitProgram
        cached <- if oStackReport opts then pure False else doesFileExist path
        if cached
          then do
            when (Options.diagApply diagnostic || isJust (oCallables opts)) (readFile path >>= applyReport (takeFileName path))
            pure (path, "cached")
          else do
            let (specialized, productParameters) = mono unitProducts (takeFileName path) M.empty unitProgram
            prog <- own specialized
            prepared <- ready M.empty (Linked.artifactId artifact) exps (prog `M.union` erasedConstructorStubs prog)
            let unitExt = NativeImports.importArities prepared `M.union` M.union (if oArc opts then arcExterns else M.empty) ext
            (lowered, typedFns, placedNames) <- typedInput placed (M.keysSet unitProgram `S.difference` elide) unitExt (NativeImports.readyProgram prepared `M.union` NativeImports.readyTemplates prepared)
            let emission =
                  emitTypedProductProgramWithImports
                    typedFns
                    placedNames
                    unitProgram
                    productParameters
                    (if oArc opts then S.empty else checkedCallbackTargets)
                    (NativeImports.readyTemplates prepared)
                    linkedTgt
                    rvv
                    spec
                    []
                    unitExt
                    (NativeImports.readySymbols prepared)
                    elide
                    (NativeImports.readyProgram prepared)
                vnotes = emNotes emission
                asm = moduleFinal (unlines (["# typed IR: no translation"] ++ emNative emission ++ emData emission))
            let packed = T.pack asm
            T.length packed `seq` directCheck ("unit " ++ takeFileName path) emission
            mapM_ putStrLn vnotes
            typedLowering
              lowered
              placed
              (M.keysSet unitProgram `S.difference` elide)
              unitExt
              (takeFileName path)
              [("placed", unitProgram), ("mono", specialized), ("own", prog), ("ready", NativeImports.readyProgram prepared)]
              emission
            writeWhole path (T.unpack packed)
            nativeSummary (Options.diagNativeInsns diagnostic) ("unit " ++ takeFileName path) (T.unpack packed)
            applyReport (takeFileName path) (T.unpack packed)
            let count = M.size prog
            count `seq` pure (path, show count ++ " supercombinators")
  timed "link-and-opt" $ do
    either (\reason -> hPutStrLn stderr reason >> exitFailure) (const (pure ())) linkedResult
    when (isJust (oCallables opts)) (CallableReport.writeReport (oCallables opts == Just "json") anchors linked)
    when (oArc opts) $ either (\reason -> hPutStrLn stderr reason >> exitFailure) (const (pure ())) arcPrepared
    when (remarkMode `elem` [Remark.Hot, Remark.All]) (mapM_ (hPutStrLn stderr) trmcNotes)
    Remarks.writeRemarks
      remarkMode
      sources
      anchors
      ( Remarks.collect
          (map Linked.artifactCore (M.elems (Linked.linkedArtifacts linked)))
          (M.elems regionArtifacts)
          fusionNotes
      )
    either (\reason -> hPutStrLn stderr reason >> exitFailure) (const (pure ())) declarationsResult
  createDirectoryIfMissing True unitDir
  preludeOut <- timed "emit-prelude" $
    if oArc opts || null preludeTops
      then pure []
      else do
        r <- emitUnit (unitDir </> ("prelude-" ++ take 12 preludeHash)) extFor (artifactOf (Linked.PreludeArtifact preludeHash))
        pure [r]
  let shapesHash = hashAST [TShape (concat fs) [] | fs <- M.keys shapes]
  unitOuts <- timed "emit-units" $ forM (if oArc opts then [] else checkedUnits) $ \(h, _, _) ->
    emitUnit
      (unitDir </> ("u-" ++ take 12 h ++ "-p" ++ take 8 preludeHash ++ "-s" ++ take 8 shapesHash))
      extFor
      (artifactOf (Linked.DependencyArtifact h))
  let rootExports =
        [ ModExport rootHash n n (length ps) ""
          | oPlugin opts,
            TBind n ps _ _ <- rootProgTops,
            S.member n rootNames
        ]
      rawExports = [e {meArity = M.findWithDefault (meArity e) (meQual e) extFor} | e <- exports] ++ rootExports
      checkedTypes = M.fromList interfaces
      contractTops = stripPosTops tops
      contractFor n = [(as, r, pres) | TSig q (as, r) pres <- contractTops, q == n]
      unsafeMarkers = [q | TSig q _ pres <- contractTops, any (\p -> (fst <$> p) == Just "$unsafe") pres]
      ownsUnsafe n marker
        | marker == "$module" = n `S.member` rootNames
        | "$module@" `isPrefixOf` marker = drop (length "$module") marker `List.isInfixOf` n
        | ".$module" `List.isSuffixOf` marker = take (length marker - length "$module") marker `isPrefixOf` n
        | otherwise = marker == n
      opaque n =
        any (ownsUnsafe n) unsafeMarkers
          || any (\(_, _, pres) -> any (\p -> (fst <$> p) == Just "$size") pres) (contractFor n)
      stamp e = case M.lookup (meQual e) checkedTypes of
        Nothing -> ""
        Just ty
          | opaque (meQual e) || oManifest opts /= Nothing -> ""
          | otherwise ->
              "fpr-interface-1/g"
                ++ show codegenRev
                ++ "/"
                ++ preludeHash
                ++ "/"
                ++ hashAST foreignTops
                ++ "/"
                ++ tname
                ++ "/hardfloat="
                ++ show (oHardFloat opts)
                ++ "/"
                ++ canonicalTypeWith interfaceName ty
                ++ "/precond=2"
                ++ "/contracts="
                ++ show (contractFor (meQual e))
                ++ "/arity="
                ++ show (meArity e)
      checkedTarget n = if M.member n preTab then checkedName n 0 else n
      imageExports = [e {meInterface = stamp e, meQual = checkedTarget (meQual e)} | e <- rawExports]
  let sourceArities = arities tops
      badContractExports =
        [ meName e
          | e <- rawExports,
            M.member (meQual e) preTab,
            Just ps <- [M.lookup (meQual e) preTab],
            Just a <- [M.lookup (meQual e) sourceArities],
            a /= length ps
        ]
  unless (null badContractExports) $ do
    hPutStrLn stderr ("precondition: dynamic exports require matching signature and implementation arity: " ++ unwords badContractExports)
    exitFailure
  when (oBuiltin opts && not (oArc opts) && M.member "machineInterrupt" rootProgRaw) $ do
    hPutStrLn stderr "machineInterrupt requires --arc (raw, allocation-free handler ABI)"
    exitFailure
  checkWidth rootProgRaw
  reportTurnsOf (artifactRegions Linked.RootArtifact)
  rootProgSym <- case symbolize rootProgRaw of
    Left e -> hPutStrLn stderr ("error: " ++ e) >> exitFailure
    Right p -> pure p
  importedSym <-
    if not (Options.cgSpecialize codegen) || oArc opts
      then pure M.empty
      else case symbolize importedCore of
        Left e -> hPutStrLn stderr ("error: " ++ e) >> exitFailure
        Right p -> pure p
  let borrowed = M.restrictKeys importedSym importedPrivateNames
  boundarySignatures <-
    if oArc opts && not (oRaw opts)
      then either (\e -> hPutStrLn stderr e >> exitFailure) (pure . fst) arcSignatures
      else pure M.empty
  checkedExports <-
    case (if oArc opts && not (oRaw opts) then Exports.prepareUniformExportsWith boundarySignatures else Exports.prepareExports)
      (if oHardFloat opts then HardFloat else SoftFloat)
      (oExports opts)
      tops0RL
      (M.map (length . fst) rootProgSym)
      (functionSymbol . checkedTarget) of
      Left err -> hPutStrLn stderr ("export " ++ Exports.exportSource err ++ ": " ++ Exports.exportMessage err) >> exitFailure
      Right checked -> pure checked
  let rootFacts =
        withImportedVariantResults
          importedSym
          [resultProducts placed | (key, placed) <- M.toList regionArtifacts, key /= Linked.RootArtifact]
          (resultProducts (artifactRegions Linked.RootArtifact))
      (rootSpecialized, rootProductParameters) = mono rootFacts ("root" ++ take 12 rootHash) importedSym rootProgSym
  rootProg <- ownWith borrowed rootSpecialized
  rootReady <-
    ready
      borrowed
      Linked.RootArtifact
      (if oArc opts then M.keysSet rootProg else Linked.artifactExports (artifactOf Linked.RootArtifact))
      (rootProg `M.union` erasedConstructorStubs rootProg)
  let rootEmitted = M.keysSet (Regions.resultProgram (artifactRegions Linked.RootArtifact)) `S.difference` Linked.artifactElided (artifactOf Linked.RootArtifact)
      rootExt = NativeImports.importArities rootReady `M.union` extFor
  (rootLowered, rootTypedFns, rootPlacedNames) <- typedInput (artifactRegions Linked.RootArtifact) rootEmitted rootExt (NativeImports.readyProgram rootReady `M.union` NativeImports.readyTemplates rootReady)
  let rootEmission =
        emitTypedProductProgramWithImports
          rootTypedFns
          rootPlacedNames
          (Regions.resultProgram (artifactRegions Linked.RootArtifact))
          rootProductParameters
          (if oArc opts then S.empty else checkedCallbackTargets)
          (NativeImports.readyTemplates rootReady)
          linkedTgt
          rvv
          spec
          imageExports
          (NativeImports.importArities rootReady `M.union` extFor)
          (NativeImports.readySymbols rootReady)
          (Linked.artifactElided (artifactOf Linked.RootArtifact))
          (NativeImports.readyProgram rootReady)
      rootVNotes = emNotes rootEmission
      adapterFrames = map (adapterStack . Exports.exportAdapter) checkedExports
      callbackFrames = emStackFrames rootEmission ++ adapterFrames
      callbackBounds = Stack.analyse callbackFrames
      callbackNotes =
        [ Stack.reportLine f b
          | f <- adapterFrames,
            Just b <- [M.lookup (Stack.frameSymbol f) callbackBounds]
        ]
  tramps <- forM checkedExports $ \entry -> do
    putStrLn (Exports.exportDescription entry)
    pure (renderAdapter (Exports.exportAdapter entry))
  let dir = if tgtName tgt == "rv32" then ".word" else ".quad"
      rootTables = renderRootTables (oBuiltin opts) (oLib opts) (oPlugin opts) dir consAll shapes rawAll
      rootAsm =
        moduleFinal
          ( unlines
              ( ["# typed IR: no translation"]
                  ++ emNative rootEmission
                  ++ emData rootEmission
                  ++ dataSyntax (tcDirectFormat targetCfg) rootTables
              )
          )
          ++ unlines (concat tramps ++ callbackNotes)
  directCheck "root" rootEmission
  admitted <- case stackBudget of
    Nothing -> pure []
    Just limit ->
      either (\why -> hPutStrLn stderr ("error: " ++ why) >> exitFailure) pure
        (Stack.admit limit (map Stack.frameSymbol adapterFrames) callbackFrames)
  heapAdmitted <- case heapBudget of
    Nothing -> pure []
    Just limit ->
      either (\why -> hPutStrLn stderr ("error: " ++ why) >> exitFailure) pure
        ( Heap.admit
            limit
            (map Stack.frameSymbol adapterFrames)
            (emHeapEquations rootEmission ++ map (adapterHeap . Exports.exportAdapter) checkedExports)
        )
  mapM_ putStrLn rootVNotes
  typedLowering
    rootLowered
    (artifactRegions Linked.RootArtifact)
    rootEmitted
    rootExt
    "root"
    [ ("placed", Regions.resultProgram (artifactRegions Linked.RootArtifact)),
      ("raw", rootProgRaw),
      ("symbolized", rootProgSym),
      ("mono", rootSpecialized),
      ("own", rootProg),
      ("ready", NativeImports.readyProgram rootReady)
    ]
    rootEmission
  applyReport "root" rootAsm
  let admissionNotes =
        [ "# native-stack-budget-v1: " ++ codeName entry ++ " peak=" ++ show bytes ++ " limit=" ++ show limit ++ " scope=c-entry-closed-unit"
          | Just limit <- [stackBudget],
            (entry, bytes) <- admitted
        ]
          ++ [ "# native-heap-budget-v1: " ++ codeName entry ++ " requests=" ++ show (Heap.requests d)
                 ++ " requested=" ++ show (Heap.requestedBytes d)
                 ++ " arena=" ++ show bytes
                 ++ " limit=" ++ show limit
                 ++ " scope=fresh-aligned-builtin-rv64-c-heap"
               | Just limit <- [heapBudget],
                 (entry, d, bytes) <- heapAdmitted
             ]
      admittedAsm = if null admissionNotes then rootAsm else rootAsm ++ unlines admissionNotes
  timed "emit-root" (writeFile out admittedAsm)
  mapM_ (putStrLn . drop 2) admissionNotes
  nativeSummary (Options.diagNativeInsns diagnostic) "root" rootAsm
  writeFile (out ++ ".units") (unlines (map fst (preludeOut ++ unitOuts)))
  writeFile (out ++ ".abirev") (show codegenRev)
  forM_ (preludeOut ++ unitOuts) $ \(p, note) -> putStrLn ("unit " ++ p ++ " (" ++ note ++ ")")
  putStrLn ("wrote " ++ out ++ " (" ++ show (M.size rootProg) ++ " supercombinators, linearity OK)")
  when (not (null imageExports)) $
    putStrLn ("module table: " ++ show (length [e | e <- imageExports, meArity e >= 1]) ++ " remote-callable exports")
  putStrLn "assumed external symbols (the fpr_g_ HAL/runtime contract):"
  putStrLn ("  " ++ unwords (externals extFor rootProg))
