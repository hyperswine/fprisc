{-# LANGUAGE LambdaCase #-}
module Compile (compileMain, checkedInterface, parseFile) where

import Data.Maybe (fromMaybe, isJust)
import System.IO (hPutStrLn, stderr)
import Core.Typed.Callback (CallbackMode (..))
import qualified Compiler.Native.Core as NativeCore
import Compiler.DataLayout (Layouts (..))
import qualified Compiler.Native.Regions as Regions
import qualified Codegen as Backend (tgtW)
import Control.Monad (forM, forM_, unless, when)
import qualified Data.List as List
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Core.Syntax (Name)
import qualified Compiler.Options as Options
import Compiler.CommandLine
import Core.Identity (Namespace (..))
import Frontend.Syntax
import Frontend.Desugar
import Frontend.OwnedMapFold (ownedMapFolds)
import Frontend.KeyedListFold (keyedListFolds)
import Frontend.ListRewrites (sharedMaps, snocFolds)
import Frontend.Paths
import Frontend.Linearity
import Frontend.Normalize
import Frontend.Diagnostics
import qualified Diagnostic.Render as Diagnostic
import qualified Compiler.Editor as Editor
import qualified Diagnostic.Remark as Remark
import Infer.Result
import Frontend.Desugar.Typed (prepareChecked, specializeCheckedSource, specializedTops, checkedTransportCatalog, selectUnit, selectSpecialized)
import Infer (inferTopsChecked, aotProf, builtinLinShapes, canonicalTypeWith)
import Safety (measureCheck, checkSafety, safetyDiagnostics, safetySuggestions, trustedLibraryPaths)
import qualified Resource.Analysis as Resource
import Manifest (Manifest (..), readManifest)
import Struct (expandStructs, sigTable, structTable)
import Modules (LoadResult (..), ModExport (..), hashAST, loadProgram)
import Precond (PreNote (..), PreStatus (..), applyPreconds, checkedName, preTable, renderNote, validatePre, validatePreUses)
import Home (underHome)
import System.Environment (getArgs, lookupEnv)
import StdBridge (runStdCheck)
import System.Exit (exitFailure, exitSuccess)
import Control.Exception (evaluate)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.FilePath (takeExtension, takeFileName, (</>))
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Compiler.Compile.Support
import Compiler.Compile.Target (validateProfileMatrix)
import Compiler.Compile.Cost (runCostAnalysis)
import Compiler.Compile.Emit (EmitInputs (..), emitNative)

compileMain :: IO ()
compileMain = do
  args <- getArgs
  compileWithArguments (parseCompileArguments args) (const (pure ()))

-- Return interfaces only after the SAME normal checker has accepted the unit.
-- No diagnostic parsing, alternate inference path, argv mutation, or code
-- generation required.
checkedInterface :: FilePath -> IO [(Name, String)]
checkedInterface file = do
  ref <- newIORef []
  let opts = parseCompileArguments ["--check-only", "--lib", file, "/dev/null"]
  compileWithArguments opts (writeIORef ref)
  readIORef ref

compileWithArguments :: CompileArguments -> ([(Name, String)] -> IO ()) -> IO ()
compileWithArguments options accepted = do
  let root = case oFiles options of f:_ -> f; _ -> "<input>"
  Editor.run (oEditorJSON options) root (compileWithReport options accepted)

compileWithReport :: CompileArguments -> ([(Name, String)] -> IO ()) -> Editor.Report -> IO ()
compileWithReport opts0 accepted report = do
  setLocaleEncoding utf8
  let checkOnly = oCheckOnly opts0
  stackBudget <- case oStackBudget opts0 of
    Nothing->pure Nothing
    Just raw->case reads raw of
      [(n,"")] | not (null raw), all (`elem` ['0'..'9']) raw, n>0,
                  not (checkOnly || oStdCheck opts0)->pure (Just n)
      _->hPutStrLn stderr "error: --stack-budget needs a positive decimal byte count and native compilation" >> exitFailure
  heapBudget <- case oHeapBudget opts0 of
    Nothing->pure Nothing
    Just raw->case reads raw of
      [(n,"")] | not (null raw), all (`elem` ['0'..'9']) raw, n>0, n<2^(64::Int),
                  not (checkOnly || oStdCheck opts0)->pure (Just n)
      _->hPutStrLn stderr "error: --heap-budget needs a positive RV64 decimal byte count and native compilation" >> exitFailure
  -- --stdcheck: parse the single file and run the std proof pass
  -- (StdBridge lowers the checkable fragment into StdCheck's interval /
  -- measure / WCET engine); no code is generated.
  when (oStdCheck opts0) $ do
    inp <- case oFiles opts0 of
      [i] -> pure i
      _ -> putStrLn "usage: fprc --stdcheck <in.fpr>" >> exitFailure >> pure ""
    tops <- parseFile inp
    ok <- runStdCheck tops
    if ok then exitSuccess else exitFailure
  (inp, out) <- case oFiles opts0 of
    [i, o] -> pure (i, o)
    _ -> putStrLn "usage: fprc [--system=posix|bare-metal|qos-native|qos-portable] [--host=unix|esp-idf] [--profile=builtin|base|extbase|sol] [--arc] [--target=rv32|rv64|a64|a64mac|x64|x64mac|qx64|qrv64|qa64|qa64single|qa64mac] [--plugin] [--rvv] [--stdcheck] [--prelude=FILE] <in.fpr> <out.s>" >> exitFailure >> pure ("", "")
  remarkMode<-either (\why->hPutStrLn stderr ("error: "++why) >> exitFailure) pure (Remark.parseMode (oRemarks opts0))
  when (oCheckOnly opts0 && remarkMode/=Remark.Off) $
    hPutStrLn stderr "error: optimization remarks require native compilation; omit --check-only" >> exitFailure
  when (maybe False (`notElem` ["summary","json"]) (oCallables opts0)) $
    hPutStrLn stderr "error: --callables expects summary or json" >> exitFailure
  when (isJust (oCallables opts0) && (oCheckOnly opts0 || oEditorJSON opts0)) $
    hPutStrLn stderr "error: --callables requires native compilation; omit --check-only/--editor-json" >> exitFailure
  configured <- Options.readCompilerOptions
  let configuration = Options.disableInlining (oNoInline opts0) configured
      codegen = Options.codegenOptions configuration
      native = Options.nativeOptions codegen
      diagnostic = Options.diagnosticOptions configuration
      timed = phaseTime (Options.diagTimings diagnostic)
  (rootSrc0, rootTopsParsed) <- timed "parse-root" (parseFileSrcEditor report inp)
  -- the PROFILE is the file's: `profile base.` (or `unsafe base.`), a
  -- .sol file is sol; the flag serves a file that says nothing, and
  -- may not contradict one that does.  Base is the default.
  let declared = case declaredProfile rootTopsParsed of
        Just d -> Just d
        Nothing | takeExtension inp == ".sol" -> Just "sol"
                | otherwise -> Nothing
      refuse m = Editor.problem report "profile" m Nothing >> hPutStrLn stderr ("error: " ++ m) >> exitFailure
  profile <- case (declared, oProfileFlag opts0) of
    (Just d, Just f) | d /= f -> refuse ("the file declares `profile " ++ d ++ ".` but the command line asks for " ++ f) >> pure d
    (Just d, _) -> pure d
    (Nothing, Just f) -> pure f
    (Nothing, Nothing) -> pure "base"
  let system = fromMaybe "bare-metal" (oSystem opts0)
      espHost = oHost opts0 == Just "esp-idf" -- the posix system on an ESP-IDF board (docs/2026-09-23-ESP-IDF.md)
      opts = opts0 {oBuiltin = profile == "builtin", oSol = oSol opts0 || profile == "sol", oNoInline = not (Options.cgInline codegen)}
  validateProfileMatrix opts0 opts profile system espHost checkOnly stackBudget heapBudget refuse
  -- --prelude=FILE as given; no flag = the prelude beside the binary
  -- (core/prelude.fpr under Home.fprHome), so `fpr compile x.fpr x.s`
  -- means the same thing from any directory; --prelude= (empty) = none
  prelude <- case oPrelude opts of
    Just "" -> pure Nothing
    Just f -> pure (Just f)
    Nothing | oBuiltin opts -> pure Nothing
            | otherwise -> underHome ("core" </> "prelude.fpr")
  let opts' = opts {oPrelude = prelude}
  (preludeSrc, preludeTops0) <- timed "parse-prelude" (maybe (pure ("", [])) (parseFileSrcEditor report) prelude)
  -- --foreign=FILE: the primitives the SYSTEM supplies, declared by whoever
  -- implements them.  The compiler used to type every QOS device and system
  -- primitive itself (glRender, blkRead, Pin.*, Sys.caps, Apps.*): a language
  -- that named one operating system's HAL.  Such a file holds signatures and
  -- nothing else -- a signature with no definition is a foreign declaration,
  -- resolved at link time to an fpr_g_ symbol -- and joins the prelude, so
  -- every unit sees the names exactly as it saw the builtins.  docs/2026-09-19-HAL.md.
  -- FPR_FOREIGN (a path list, like FPR_PATH) names such files for every
  -- invocation in a tree that exports it; the flag adds to it
  let envForeign = Options.driverForeign (Options.driverOptions configuration)
  foreignInputs <- forM (envForeign ++ oForeign opts) $ \f -> do
    (source,ts) <- parseFileSrcEditor report f
    let strays = [n | TBind n _ _ _ <- ts]
    unless (null strays) $ do
      hPutStrLn stderr ("--foreign=" ++ f ++ ": declarations only; it defines " ++ unwords (take 5 strays))
      exitFailure
    pure (f,source,[t | t@(TSig {}) <- ts])
  let foreignTops=concat [ts | (_,_,ts)<-foreignInputs]
      foreignSources=M.fromList [(file,source) | (file,source,_)<-foreignInputs]
      preludeTops = preludeTops0 ++ foreignTops
  -- a LIBRARY: the file is compiled as the one import of an empty root,
  -- so every name it defines is qualified by its module hash (no clash
  -- with the program it links into) and nothing requires a `main`
  let (rootSrc, rootTops0) =
        if oLib opts then ("", [TUse "Lib" (takeFileName inp)]) else (rootSrc0, rootTopsParsed)
  -- ONE grammar, profile-gated views: `>` top-level statements are the
  -- sol/HostedBytecode surface.  Outside that view they are a profile
  -- error, not a parse error -- the sentence is grammatical everywhere,
  -- it just isn't part of this profile's contract.
  let solView = oSol opts || takeExtension inp == ".sol"
      (rootTops, nEvals) = desugarEvals rootTops0
  when (nEvals > 0 && not solView) $ do
    hPutStrLn stderr ("error: " ++ show nEvals ++ " top-level `>` statement(s): the sol profile's surface (declare `profile sol.`, or name the file .sol)")
    exitFailure
  when (nEvals > 0 && any isMain rootTops0) $ do
    hPutStrLn stderr "error: both `main` and top-level `>` statements -- the `>` list IS main in the sol view"
    exitFailure
  -- An executable starts at `main`. Check-only also serves editors opening
  -- library/source modules: check their definitions normally, without an
  -- executable entry point or the qualification introduced by --lib.
  when (not checkOnly && nEvals == 0 && not (oPlugin opts) && not (oLib opts) && not (any isMain rootTops0)) $ do
    hPutStrLn stderr ("error: " ++ inp ++ " has no `main` (a program starts at main; a library unit is built with --module)")
    exitFailure
  -- an ordered Map built by a fold is built in a MutMap and frozen once
  -- (Frontend/OwnedMapFold.hs; FPR_NO_OWNED_MAP_FOLD=1 turns it off)
  let rootRewrites = not solView && not (oBuiltin opts) && not (oLib opts)
      ownedFolds = Options.cgOwnedMapFold codegen && rootRewrites
      rootTopsOwned = if ownedFolds then fst (ownedMapFolds rootTops) else rootTops
      -- a list kept by key in a fold is kept in a table and listed once
      -- (Frontend/KeyedListFold.hs; FPR_NO_KEYED_LIST_FOLD=1), a map that
      -- changes few elements shares the rest, and a fold that appends to its
      -- list builds it reversed (Frontend/ListRewrites.hs; FPR_SHARED_MAP=1 turns
      -- the first on, FPR_NO_SNOC_FOLD=1 the second off).  Same profiles as the owned map folds.
      (rootTopsKeyed, nKeyed) = if rootRewrites && Options.cgKeyedListFold codegen then keyedListFolds rootTopsOwned else (rootTopsOwned, [])
      (rootTopsShared, nShared) = if rootRewrites && Options.cgSharedMap codegen then sharedMaps rootTopsKeyed else (rootTopsKeyed, [])
      (rootTopsLoaded, nSnoc) = if rootRewrites && Options.cgSnocFold codegen then snocFolds rootTopsShared else (rootTopsShared, [])
  listNotes <- lookupEnv "FPR_LIST_REWRITE_NOTES"
  when (listNotes == Just "1") $
    hPutStrLn stderr ("list rewrites: " ++ show (length nKeyed) ++ " keyed-list folds, " ++ show (length nShared) ++ " shared maps, " ++ show (length nSnoc) ++ " snoc folds"
                      ++ concat ["\n  " ++ kind ++ " in " ++ f | (kind, fs) <- [("keyed-list fold", nKeyed), ("shared map", nShared), ("snoc fold", nSnoc)], f <- fs])
  lr <- timed "load-imports" (loadProgram preludeTops inp rootTopsLoaded)
  case lr of
    Left e -> Editor.problem report "import" e Nothing >> putStrLn e >> exitFailure
    Right (LoadResult tops0RL exports notes units0L root0L rootHash unitAnchors rootAliases unitSources) -> do
      mapM_ putStrLn notes
      -- spans steps 1-3: every "in NAME:" diagnostic below gets the
      -- best available anchor -- a stamped statement offset, the named
      -- token's position, or NAME's definition line (root + prelude
      -- scanned here, spliced units by Modules under qualified names)
      let anchors =
            M.unions
              [ bindAnchors inp rootSrc rootTops0,
                maybe M.empty (\pp -> bindAnchors pp preludeSrc preludeTops) (oPrelude opts'),
                unitAnchors
              ]
          sources =
            M.unions
              [ if oLib opts then M.empty else M.singleton inp rootSrc,
                maybe M.empty (`M.singleton` preludeSrc) (oPrelude opts'),
                foreignSources, unitSources
              ]
          anchored = map (anchorMsg sources anchors)
          anchoredDiagnostics = map (Diagnostic.renderSourceDiagnostic sources anchors)
      Editor.context report sources anchors
      -- first-class paths: validate + desugar @Shape.path literals on the
      -- surface tree, first transform after load (ONE table from the
      -- merged program, so root and unit rewrites agree; the generated
      -- records then flow through every later pass like user code).
      let ptbl = shapeTyTable tops0RL
          ttbl = typeTyTable tops0RL
          (pathErrsM, tops0R) = expandPathLits ptbl ttbl tops0RL
          (pathErrsR, root0) = expandPathLits ptbl ttbl root0L
          unitsPR = [(h, expandPathLits ptbl ttbl uts) | (h, uts) <- units0L]
          -- a module reached by two spellings (`ep` and `../programs/mods/ep`,
          -- a pin and a path) is ONE unit: its hash is its identity.  Listed
          -- twice it was compiled once (the cache) and linked twice (duplicate
          -- symbols, 2026-10-02).
          units0 = dedupeUnits [(h, ts) | (h, (_, ts)) <- unitsPR]
          pathErrs = List.nub (pathErrsM ++ pathErrsR ++ concat [es | (_, (es, _)) <- unitsPR])
      unless (null pathErrs) $ do
        putStrLn "=== PATH LITERALS: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored pathErrs)
        Editor.legacy report "path-literal" pathErrs
        exitFailure
      -- Privileged builtins (std/hashmap's trie node access: nodeGet,
      -- nodeWith, nodeSet).  Their schemes are deliberately loose
      -- (`Int -> a -> a`) and they read and store a cell by field number
      -- with no layout check, so a program that names them can mutate an
      -- immutable value or read past a cell.  Only the modules listed in
      -- privilegedBuiltinModules, resolved under FPR_HOME, may mention them.
      privileged <- privilegedModulePaths
      let privHashes = S.fromList [drop 1 h | (n, (p, _)) <- M.toList unitAnchors, S.member p privileged,
                                              let h = dropWhile (/= '@') n, not (null h)]
      rootPrivileged <- (`S.member` privileged) <$> canonicalPathOr inp
      let privErrs =
            [ "in " ++ n ++ ": " ++ b ++ " is a privileged builtin (std/hashmap only): user code cannot call it"
              | (h, uts) <- ("", root0) : units0, if null h then not rootPrivileged else S.notMember h privHashes,
                (n, b) <- privilegedMentions uts ]
      unless (null privErrs) $ do
        putStrLn "=== PRIVILEGED BUILTINS: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored privErrs)
        Editor.legacy report "privileged-builtin" privErrs
        exitFailure
      -- A received message dies with its turn (docs/2026-10-24-REGIONS-STAGE1.md):
      -- the runtime releases every root an actor took when the turn that
      -- took it ends, so the compiler inserts no `drop` any more (the
      -- autoDrop pass of docs/2026-08-25-MEMORY.md is retired).
      let (tops0, asNotes) = (\(ts, ns) -> (etaPrimitiveValues ts, ns)) (aritySpill tops0R)
      mapM_ putStrLn asNotes
      -- ---- ML-style modules: expand sigs/structures, typecheck (HM +
      -- rows), resolve operators by operand type, monomorphize -----------
      -- The global sig table spans units (prelude sigs are visible
      -- everywhere). Structs expand per-unit to flat `Numeric.+` globals
      -- plus a first-class record; codegen stays per-unit, cached.
      let sigs = sigTable tops0
          structs = structTable tops0
          expandU uts = snd (expandStructs sigs uts)
          preludeExpErrs = fst (expandStructs sigs preludeTops)
          preludeE = expandU preludeTops
          -- the same spilling reaches the ASTs codegen actually consumes:
          -- root codegen reads finalTops (derived from tops0, spilled
          -- above), but UNIT codegen reads units0; root0 is transformed
          -- too so root' -- used for cons/tid tables -- matches what the
          -- root emits.  Notes are dropped here: the pass above already
          -- printed the same lines.
          root' = expandU (etaPrimitiveValues (fst (aritySpill root0)))
          units = [(h, expandU (etaPrimitiveValues (fst (aritySpill uts)))) | (h, uts) <- units0]
          tops = expandU tops0
      unless (null preludeExpErrs) $ do
        putStrLn "=== SIG/STRUCT: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored preludeExpErrs)
        Editor.legacy report "sig-struct" preludeExpErrs
        exitFailure
      -- ---- preconditions (contracts): signatures may constrain params,
      -- (n : Int | n > 0).  Discharge obligations statically from local
      -- facts (clause guards, case discrimination, own preconditions),
      -- insert blame-carrying runtime checks otherwise.  Runs BEFORE
      -- inference so inserted checks are typechecked + operator-resolved
      -- like any user code; the merged table spans units, and the pass
      -- is deterministic per-bind so unit and root rewrites agree.
      let preTab = preTable tops
          preFragErrs = validatePre preTab ++ validatePreUses preTab tops
      unless (null preFragErrs) $ do
        putStrLn "=== PRECONDITION: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored preFragErrs)
        Editor.legacy report "precondition" preFragErrs
        exitFailure
      let (pnAll, tops') = applyPreconds preTab tops
          -- Bodyless foreign signatures keep a global name across imports.
          -- Their checked entries must have one owner, even when multiple
          -- units declare the same primitive. Keep signatures in each unit
          -- for inference, but emit the shared entry once with the root.
          foreignContracts = M.keysSet preTab `S.difference` bindNames tops
          sharedEntryNames = S.fromList
            [checkedName n k | n <- S.toList foreignContracts,
              Just ps <- [M.lookup n preTab], k <- [0 .. length ps - 1],
              any (/= Nothing) (map (fmap (const ())) (drop k ps))]
          sharedEntryTops = [t | t <- tops', case t of
            TBind n _ _ _ -> n `S.member` sharedEntryNames
            TSig n _ _ -> n `S.member` sharedEntryNames
            _ -> False]
          removeShared = filter (\t -> case t of
            TBind n _ _ _ -> n `S.notMember` sharedEntryNames
            _ -> True)
          preludeE' = removeShared (snd (applyPreconds preTab preludeE))
          root'' = removeShared (snd (applyPreconds preTab root')) ++ sharedEntryTops
          units' = [(h, removeShared (snd (applyPreconds preTab uts))) | (h, uts) <- units]
          rootBinds = S.fromList [fst3 b | b@TBind {} <- root']
          pnRoot = [n | n <- pnAll, S.member (pnCaller n) rootBinds]
          nDis = length [() | n <- pnAll, pnStatus n == Discharged]
          nRt = length [() | n <- pnAll, pnStatus n == RuntimeCheck]
          nTrap = length [() | n <- pnAll, pnStatus n == BuiltinTrap]
      -- per-obligation notes are telemetry, not signal: 100+ lines per
      -- compile buried the errors.  FPR_PRECOND_NOTES=1 restores them;
      -- the one-line summary below always prints.
      when (Options.diagPreconditions diagnostic) $ mapM_ (putStrLn . renderNote) pnRoot
      unless (null pnAll) $
        putStrLn ("precond: " ++ show (length pnAll) ++ " obligations: "
                  ++ show nDis ++ " discharged, " ++ show nRt
                  ++ " runtime-checked, " ++ show nTrap ++ " builtin traps")
      -- typecheck the merged expanded program; rewritten tops carry
      -- operator sites resolved to prims / Str.+ / s.(+)
      (inferred, terrs, notes, holes, linsigs, interfaces) <- timed "typecheck" $ do
        let inf = inferTopsChecked (Namespace rootHash) aotProf sigs structs tops'
            ts = inferenceDiagnostics inf
            ns = inferenceNotes inf
            hs = inferenceHoles inf
            ls = inferenceLinearity inf
            ifs = inferenceInterfaces inf
        _ <- evaluate (length ts + length hs)
        pure (inf, ts, ns, hs, ls, ifs)
      unless (null terrs) $ do
        putStrLn "=== TYPE ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchoredDiagnostics terrs)
        Editor.diagnostics report "type-error" terrs
        exitFailure
      -- typed holes: NAMED holes typecheck everything around them and
      -- then refuse to compile, with the inferred type -- exactly the
      -- "let it typecheck, don't let it ship" contract.  ?? holes were
      -- elaborated to runtime traps and pass through.
      let named = [(n, t) | (n, t) <- holes, not (null n)]
      unless (null named) $ do
        putStrLn "=== TYPED HOLES ==="
        mapM_ (\(n, t) -> putStrLn ("  * got into a typed hole, ?" ++ n ++ " : " ++ t)) named
        Editor.legacy report "typed-hole" ["got into a typed hole, ?" ++ n ++ " : " ++ t | (n,t) <- named]
        unless (null [t | (_, t) <- holes, False]) (pure ())
        exitFailure
      case inferenceEvidence inferred of
        Right (Just _) -> pure ()
        Left reason -> hPutStrLn stderr ("compiler inference evidence: " ++ reason) >> exitFailure
        Right Nothing -> hPutStrLn stderr "compiler inference evidence: capture missing" >> exitFailure
      checkedLowering <- timed "typed-core" (either (\reason -> hPutStrLn stderr ("compiler typed Core: " ++ reason) >> exitFailure) evaluate (prepareChecked inferred))
      unless (null [() | (n, _) <- holes, null n]) $
        mapM_ (\(_, t) -> putStrLn ("note: ?? hole (runtime trap) : " ++ t)) [h | h@(n, _) <- holes, null n]
      -- the safe/unsafe line (Safety.hs): recursion and unsafe-taint
      -- must be DECLARED.  --no-safety exists for transition only.
      unless (oNoSafety opts || oBuiltin opts) $ timed "safety" $ do
        trustedPaths <- trustedLibraryPaths
        let trustedAnchors = filter (\(_, (p, _)) -> S.member p trustedPaths) (M.toList unitAnchors)
        let trustedHashes = S.fromList [drop 1 h | (n, _) <- trustedAnchors, let h = dropWhile (/= '@') n, not (null h)]
            trustedTops = preludeE ++ concat [expandU ts | (h, ts) <- units0L, S.member h trustedHashes]
            preludeNames = S.fromList [n | TBind n _ _ _ <- trustedTops]
            -- on the tops BEFORE precondition insertion (as Sol does): the
            -- inserted guards wrap call arguments, and a measure must read
            -- the user's arguments to verify the descent
            safety = checkSafety preludeNames tops notes
            serrs = safetyDiagnostics safety
            ssug = safetySuggestions safety
        unless (null serrs) $ do
          putStrLn "=== SAFETY: the safe/unsafe line ==="
          mapM_ (putStrLn . ("  * " ++)) (anchoredDiagnostics serrs)
          Editor.diagnostics report "safety" serrs
          when (Options.diagUnsafeSuggest diagnostic && not (null ssug)) $ do
            putStrLn "-- paste-ready signatures (inferred types):"
            mapM_ (putStrLn . ("SUGGEST " ++)) ssug
          exitFailure
      unless (oBuiltin opts) $ do
        let gameApps = S.fromList
              [ n
                | (n, (p, _)) <- M.toList unitAnchors,
                  takeWhile (/= '@') n == "app",
                  ("std" </> "game.fpr") `List.isSuffixOf` p
              ]
            foreignNames = S.fromList [n | TSig n _ _ <- foreignTops]
            vpErrs = viewPurityErrors gameApps (impureViewPrimitives `S.union` foreignNames) tops
        unless (null vpErrs) $ do
          putStrLn "=== VIEW PURITY: ERRORS ==="
          mapM_ (putStrLn . ("  * " ++)) (anchored vpErrs)
          Editor.legacy report "view-purity" vpErrs
          exitFailure
      -- One owned source product supplies the compatibility analyses and
      -- typed structure transformation. Units keep their checked projections;
      -- root clones preserve types/identities before layout and closure lifting.
      specialized <- timed "specialize" $ case specializeCheckedSource checkedLowering of
        Left specErrs -> do
          putStrLn "=== SIG/STRUCT: ERRORS ==="
          mapM_ (putStrLn . ("  * " ++)) (anchored specErrs)
          Editor.legacy report "sig-struct" specErrs
          exitFailure
        Right source -> evaluate source
      let finalTops = specializedTops specialized
      -- ---- whole-program ANALYSES (cheap; codegen below is per-unit) ----
      let preludeHash = hashAST preludeTops
          -- content-addressed cons: every unit's types under ITS hash;
          -- both sides of a `use` compute the same ids from the same AST.
          -- ... and per OWNER, for the stubs: the unit that declares a type
          -- emits its constructors' stubs, the others reference them
          -- (docs/2026-10-19-SHARED-PRELUDE-UNIT.md).  builtinCons rides in
          -- every collectCons; the prelude's map is the one that owns it.
          consPrelude = collectCons preludeHash preludeE
          consRoot = collectCons rootHash root'
          consUnits = [(h, collectCons h uts) | (h, uts) <- units]
          consAll = M.unions (consPrelude : consRoot : map snd consUnits)
          -- C6 stage 3a: which constructor fields hold raw words (fpr_layout_raw)
          -- C6 stage 3c: I64 constructor fields hold raw bits in the images
          -- that publish the masks (fpr_layout_raw) and whose runtime reads
          -- them: hosted Base, 64-bit, not a plugin (registered without masks),
          -- a library, a QOS app (plane memory answers no mask), Sol or --arc
          rawI64 = oBase opts && not (oBuiltin opts || oLib opts || oPlugin opts || oQosApp opts || oSol opts || oArc opts)
                   && Backend.tgtW (oTarget opts) == 8
          rawAll = M.unions (collectRawFields rawI64 preludeHash preludeE : collectRawFields rawI64 rootHash root' : [collectRawFields rawI64 h uts | (h, uts) <- units])
          i64All = if rawI64 then M.unions (collectI64Fields preludeE : collectI64Fields root' : [collectI64Fields uts | (_, uts) <- units]) else M.empty
          -- constructor stub ownership.  Each unit's Core now carries ONLY
          -- the constructor stubs it owns and emits; the others reference the
          -- owner's symbol through schemas/arities like any cross-unit call.
          -- The prelude unit owns the builtin and prelude constructors when
          -- it is emitted, else the root does; a unit owns its own types; the
          -- root its own.  Under --arc the root is the whole program and owns
          -- everything (docs/2026-10-19-SHARED-PRELUDE-UNIT.md).
          preludeEmitted = not (oArc opts) && not (null preludeTops)
          unitsEmitted = not (oArc opts)
          allCons = M.keysSet consAll
          preludeCons = M.keysSet consPrelude
          unitConsOf h = maybe S.empty M.keysSet (lookup h consUnits) `S.difference` M.keysSet builtinCons
          rootElided = (if preludeEmitted then preludeCons else S.empty)
                       `S.union` (if unitsEmitted then S.unions [unitConsOf h | (h, _) <- units'] else S.empty)
          rootCons = allCons `S.difference` rootElided
          preludeElided = allCons `S.difference` preludeCons
          unitElided h = allCons `S.difference` unitConsOf h
          shapes = collectShapes finalTops -- structural fnv ids: globally consistent
          nativeLayouts=Layouts consAll shapes i64All
          exportEntries=map fst (oExports opts)
            ++ [q | TSig q _ _<-finalTops,takeWhile (/='@') q `elem` map fst (oExports opts)]
          -- C adapters enter through the precondition checker when one
          -- exists. It needs the same tagged boundary as the source entry;
          -- otherwise the adapter would pass boxes to a raw checked worker.
          pinnedTypeSpec=S.fromList ("main" : "machineInterrupt" : exportEntries
            ++ [checkedName q 0 | q<-exportEntries,M.member q preTab])
          compileSelected home=compileWithCatalog (fmap ((,) home) carrierCatalog)
          compileWithCatalog catalog mode selected=either error id (selected >>= specializeSelection catalog mode nativeLayouts)
          carrierCatalog
            | not (oPlugin opts || oLib opts || oQosApp opts) && Options.cgPairReturns codegen
              && Backend.tgtW (oTarget opts)==8=Just (checkedTransportCatalog specialized)
            | otherwise=Nothing
          specializeSelection catalog
            | not (Options.cgTypeSpec codegen) = NativeCore.compileSelection
            | oArc opts = NativeCore.compileSelectionTypeSpecialized pinnedTypeSpec
            | oBase opts && not (oSol opts) = NativeCore.compileSelectionBase catalog (remarkMode/=Remark.Off) pinnedTypeSpec
            | otherwise = NativeCore.compileSelection
          prepareRegions result=either error id (Regions.prepare result)
          selectRoot uts=selectSpecialized rootCons specialized (bindNames uts)
          -- The whole-program raw view (cost bounds, region context) still
          -- carries every constructor stub: the analyzer costs constructor
          -- calls from their bodies.
          -- Merging units makes private helpers visible that separate emission
          -- may have to decline. Public cost contracts must cover that tagged
          -- execution as well, including its original constructor allocation.
          compileRaw uts=prepareRegions (compileWithCatalog Nothing PreserveCallbacks (selectSpecialized allCons specialized (bindNames uts)))
          callbackMode=if Options.cgSpecialize codegen && not (oArc opts) then SpecializeCallbacks else PreserveCallbacks
          nativeUnit home cons unit=compileSelected home PreserveCallbacks (selectUnit cons unit)
          regionContext=Regions.context (fst (measureCheck tops)) (compileRaw finalTops)
          -- Receive loops take the loop form on every target. QOS app images
          -- (qa64/qx64/qrv64, --system=qos-portable) are hosted by qosp and own
          -- their heap, so the region hooks work there; they kept the per-turn
          -- trampoline until 2026-11-09, at about 120 ns per round trip
          -- (QOS docs/2026-11-09-ACTOR-ROUND-TRIP.md).
          runTurnsWith regions input=if oBuiltin opts || oArc opts || not (Options.cgReceiveTurns codegen)
            then Regions.bypass input
            else either error id (Regions.place
              (Regions.Options (regions && Options.cgLoopRegions codegen) (regions && Options.cgCallRegions codegen) True (if oQosApp opts || oBuiltin opts then Nothing else Options.cgPersistentLoop codegen) (Backend.tgtW (oTarget opts)==8)) regionContext input)
          regionProjection result=(Regions.resultProgram result,Regions.resultNotes result)
          turnPassWith regions=regionProjection . runTurnsWith regions
          -- tid collision check (fnv32 is probabilistic; fail LOUDLY)
          tidDecls =
            [ (t, ownerT ++ "." ++ n)
              | (ownerT, ownerH, uts) <-
                  ("prelude", preludeHash, preludeE)
                    : ("root", rootHash, root')
                    : [(take 12 h, h, uts) | (h, uts) <- units],
              TType n _ _ _ <- uts,
              let t = tidFor ownerH n
            ]
          -- linearity shapes come from THREE sources, most-authored
          -- first (M.union is left-biased): explicit TSigs, then the
          -- INFERRED types of unannotated binds, then the builtin
          -- prims' own types (Vec.push consumes a Vector because its
          -- type says so).  Before the latter two, an unannotated
          -- function -- main included -- could double-free a Vec and
          -- compile "linearity OK": the checker only knew declared
          -- sigs, so let-bound results of Vec prims were untracked
          -- and sigless params defaulted to unrestricted.
          li0 = buildLinInfo finalTops
          li =
            li0
              { liSigs =
                  liSigs li0
                    `M.union` M.fromList linsigs
                    `M.union` builtinLinShapes (liLinTys li0)
              }
          linearity = checkLinearity li finalTops
          lerrs = linearityDiagnostics linearity
      -- real tid clash check: same tid, different qualified type name
      let byTid = M.fromListWith (++) [(t, [q]) | (t, q) <- tidDecls]
          bad = [(t, qs) | (t, qs) <- M.toList byTid, length (S.toList (S.fromList qs)) > 1]
      unless (null bad) $ do
        putStrLn "=== TYPEID COLLISION (content-addressed tid clash; rename a type) ==="
        forM_ bad $ \(t, qs) -> putStrLn ("  tid " ++ show t ++ ": " ++ unwords qs)
        exitFailure
      unless (null (liLinTys li)) $
        putStrLn ("linear types: " ++ unwords (liLinTys li))
      unless (null lerrs) $ do
        putStrLn "=== LINEARITY: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchoredDiagnostics lerrs)
        Editor.diagnostics report "linearity" lerrs
        exitFailure
      -- ---- resource equations (docs/2026-10-02-RESOURCE-BOUNDS.md) ----
      -- The pass runs when a signature declares a bound (`| work f <= ...`),
      -- or on --cost for the report.  A declared bound is checked against
      -- the derived equation: OVER and UNPROVED are compile errors.
      let declaredAny = or [True | TSig _ _ pres <- finalTops, Just (k, _) <- pres, k `elem` ["$work", "$alloc", "$live"]]
      manifest <- case oManifest opts of
        Nothing -> pure Nothing
        Just path -> do
          r <- readManifest path
          case r of
            Left err -> putStrLn ("=== MANIFEST: ERROR ===\n  * " ++ err) >> exitFailure
            Right m -> do
              body <- readFile path
              Editor.source report path body
              pure (Just m)
      when (oCost opts || declaredAny) $ do
        let costInput = compileRaw finalTops
            costProg = fst (turnPassWith False costInput)
        runCostAnalysis opts manifest finalTops tops preTab rootBinds anchored costInput costProg
      -- A root-declared nominal type changes its runtime tid with unit hash,
      -- even when its written constructor shape is identical. Structural
      -- records keep their field-based identity; imported nominals already
      -- carry their pinned unit qualification.
      let rootNominals = S.fromList [n | TType n _ _ _ <- root']
          interfaceName n = if S.member n rootNominals then n ++ "@" ++ rootHash else n
      if oLib opts
        then case lookup "Lib" rootAliases of
          Nothing -> hPutStrLn stderr "checked interface: missing library identity" >> exitFailure
          Just h -> do
            let byName = M.fromList interfaces
                missing = [meName e | e <- exports, meHash e == h, M.notMember (meQual e) byName]
                public = [(meName e, t) | e <- exports, meHash e == h,
                                         Just t <- [M.lookup (meQual e) byName]]
            unless (null missing) $ hPutStrLn stderr ("checked interface: missing inferred exports: " ++ unwords missing) >> exitFailure
            accepted [(n, canonicalTypeWith id t) | (n, t) <- public]
        else accepted [(n, canonicalTypeWith interfaceName t) | (n, t) <- interfaces, S.member n rootBinds]
      -- Optional editor inference cannot bypass or time-limit the required
      -- contract checks above. No native emission is needed for this report.
      when (oEditorJSON opts && not (oSol opts) && not (oBuiltin opts)) $ do
        let input = compileRaw finalTops
            prog = fst (turnPassWith False input)
            analysis = Resource.analyze rootBinds
              (fst (measureCheck tops)) (maybe M.empty mCoefs manifest) finalTops (Regions.programNative input) prog
        Editor.resources report (Resource.surfaceNames finalTops) prog preTab analysis
      Editor.types report notes
      unless checkOnly $ emitNative EmitInputs
        { eiOpts = opts,
          eiCodegen = codegen,
          eiNative = native,
          eiDiagnostic = diagnostic,
          eiEspHost = espHost,
          eiRemarkMode = remarkMode,
          eiStackBudget = stackBudget,
          eiHeapBudget = heapBudget,
          eiOut = out,
          eiSources = sources,
          eiAnchors = anchors,
          eiExports = exports,
          eiPreTab = preTab,
          eiInterfaces = interfaces,
          eiInterfaceName = interfaceName,
          eiTops = tops,
          eiTops0RL = tops0RL,
          eiFinalTops = finalTops,
          eiPreludeTops = preludeTops,
          eiForeignTops = foreignTops,
          eiPreludeE' = preludeE',
          eiPreludeHash = preludeHash,
          eiRoot' = root',
          eiRoot'' = root'',
          eiRootHash = rootHash,
          eiUnits' = units',
          eiCheckedLowering = checkedLowering,
          eiConsAll = consAll,
          eiShapes = shapes,
          eiRawAll = rawAll,
          eiI64All = i64All,
          eiPreludeEmitted = preludeEmitted,
          eiUnitsEmitted = unitsEmitted,
          eiAllCons = allCons,
          eiRootCons = rootCons,
          eiRootElided = rootElided,
          eiPreludeCons = preludeCons,
          eiPreludeElided = preludeElided,
          eiUnitConsOf = unitConsOf,
          eiUnitElided = unitElided,
          eiPinnedTypeSpec = pinnedTypeSpec,
          eiCallbackMode = callbackMode,
          eiCompileSelected = compileSelected,
          eiSelectRoot = selectRoot,
          eiNativeUnit = nativeUnit,
          eiPrepareRegions = prepareRegions
        }
