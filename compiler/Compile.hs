module Compile (compileMain, checkedInterface, parseFile) where

import Data.List (sortBy)
import Data.Maybe (fromMaybe,isJust)
import System.IO (hClose, hPutStr, hPutStrLn, openTempFile, stderr)
import Arc (lowerArcWith, lowerRawWith, arcExterns, arcRev)
import qualified Compiler.Native.Representation as NativeRep
import Core.Typed.Callback (CallbackMode(..))
import qualified Compiler.Native.Exports as Exports
import Codegen.Export.Plan (FloatABI(..))
import Codegen.Target.RV.Export (renderAdapter)
import qualified Compiler.Native.Core as NativeCore
import qualified Compiler.Native.Linked as Linked
import qualified Compiler.Native.Imports as NativeImports
import Compiler.DataLayout (Layouts(..))
import Mono (specializeCompatibility, qualifyAux)
import Inline (inlineSmall, inlineCompatibilityWithImports, vecPeekCompatibility)
import qualified Compiler.Native.Regions as Regions
import qualified Compiler.Native.Regions.Typed as TypedRegions
import qualified Core.Typed.Syntax as TCore
import qualified Core.Typed.Fusion as TypedFusion
import qualified Core.VectorRead as VectorRead
import qualified Codegen.Target.RV as RV
import qualified Codegen as Backend (tgtW)
import Codegen.Target.Common (Tune (..), dataSyntax, functionSymbol)
import Codegen (Target, codegenRev, emitCheckedProgramWithImports, Emission (..), NativeMode (..), NativeBackend (..), Granularity (..), Strict (..), externals, tgtName, tgtFuel, tgtArc, tgtWeak, tgtHal, tgtFloatInline, tgtSimd, tgtFusion, tgtScalarFast, tgtIndexedMemory, tgtScalarWorkers, tgtFieldWorkers, tgtPipelineInline, tgtReuse, tgtTypedIr, tgtPolicy, tgtNative)
import Codegen.Policy (Policy (..), Profile (..), StackPolicy (..), policyWidth)
import Codegen.Target.X64 (x64InterfaceRev, x64SelectionRev)
import Codegen.Target.A64 (ObjectFormat (..), HartAccess (..), a64HostedInterfaceRev, a64InterfaceRev, a64SelectionRev)
import Data.Char (ord)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Control.Monad (forM, forM_, unless, when)
import Data.List (intercalate, isPrefixOf)
import qualified Data.List as List
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Core.Syntax
import Core.CacheIdentity (CallArities(..),coreCacheIdentity)
import qualified Compiler.Options as Options
import Compiler.CommandLine
import Core.Identity (Namespace(..))
import Core.Pretty
import Frontend.Syntax
import Frontend.Parser (program)
import Frontend.Desugar
import Frontend.Paths
import Frontend.Linearity
import Frontend.Traverse
import Frontend.Normalize
import Frontend.Diagnostics
import qualified Diagnostic.Render as Diagnostic
import Ownership.Shape
import Core.Opt.Normalize (normArc)
import Type.Syntax (Scheme(..), Type(..))
import Infer.Result
import Frontend.Desugar.Typed (prepareChecked,selectCheckedUnit,checkedCallArities,specializeCheckedSource,specializedTops,selectUnit,selectSpecialized)
import Infer (inferTopsChecked, aotProf, builtinEnv, builtinLinShapes, canonicalTypeWith, inferTopsInterfaces)
import Safety (measureCheck, checkSafety, safetyDiagnostics, safetySuggestions, trustedLibraryPaths)
import qualified Cost
import Manifest (Manifest (..), readManifest, renderNs)
import Struct (expandStructs, sigTable, structTable)
import Modules (LoadResult (..), ModExport (..), hashAST, loadProgram)
import Precond (PreNote (..), PreStatus (..), applyPreconds, checkedName, preTable, renderNote, validatePre, validatePreUses)
import Home (underHome)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.Environment (getArgs)
import qualified System.Info
import StdBridge (runStdCheck)
import System.Exit (ExitCode (..), exitFailure, exitSuccess, exitWith)
import Control.Exception (try)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Environment (withArgs)
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Text.Megaparsec (errorBundlePretty, parse)

-- a module reached by two spellings (`ep` and `../programs/mods/ep`, a pin
-- and a path) is ONE unit: its hash is its identity.  Listed twice it was
-- compiled once (the cache) and linked twice (duplicate symbols, 2026-10-02).
dedupeUnits :: [(String, b)] -> [(String, b)]
dedupeUnits = go S.empty
  where
    go _ [] = []
    go seen ((h, u) : r)
      | S.member h seen = go seen r
      | otherwise = (h, u) : go (S.insert h seen) r

-- `Addr.symbol "name"` -> CVar "$sym.name": the address of a linker symbol,
-- the builtin profile's `extern char name[]`.  Rewritten on lifted Core
-- before ownership lowering; Representation types it 'a', Arc passes it
-- through unowned, Codegen emits one `la`.  A non-literal argument is a
-- compile error: the name IS the link, there is nothing to compute.
symbolize :: Prog -> Either String Prog
symbolize = traverse (\(ps, b) -> (,) ps <$> go b)
  where
    go e = case e of
      CApp (CVar "Addr.symbol") (CStr s) -> Right (CVar ("$sym." ++ s))
      CApp (CVar "Addr.symbol") _ -> Left "Addr.symbol takes a string literal naming a linker symbol"
      CVar "Addr.symbol" -> Left "Addr.symbol is not a function value: apply it to a string literal"
      CApp f a -> CApp <$> go f <*> go a
      CLam ps b -> CLam ps <$> go b
      CLet n a b -> CLet n <$> go a <*> go b
      CIf c t f -> CIf <$> go c <*> go t <*> go f
      CMk t v fs -> CMk t v <$> traverse go fs
      CTagEq t v x -> CTagEq t v <$> go x
      CProj i x -> CProj i <$> go x
      _ -> Right e

parseFile :: FilePath -> IO [STop]
parseFile p = snd <$> parseFileSrc p

-- keep the source: bindAnchors scans it for the file:line of every
-- top-level definition (spans step 1)
parseFileSrc :: FilePath -> IO (String, [STop])
parseFileSrc p = do
  bytes <- BS.readFile p
  -- a source file is UTF-8 text; a byte order mark is skipped (an editor
  -- wrote it, it is not a character) and a byte that is not UTF-8 is
  -- refused by name, not reported as a decoding exception or a parse error
  let body = fromMaybe bytes (BS.stripPrefix (BS.pack [0xEF, 0xBB, 0xBF]) bytes)
  src <- case TE.decodeUtf8' body of
    Right t -> pure (T.unpack t)
    Left _ -> do
      let bad = length (takeWhile id (zipWith (==) (BS.unpack body) (BS.unpack (TE.encodeUtf8 (TE.decodeUtf8With TEE.lenientDecode body)))))
      hPutStrLn stderr ("error: " ++ p ++ ": byte " ++ show bad ++ " is not UTF-8 (a source file is UTF-8 text)")
      exitFailure
  case parse program p src of
    Left e -> putStrLn (errorBundlePretty e) >> exitFailure >> pure (src, [])
    Right tops -> pure (src, tops)

-- top-level bind name -> arity, for the extern-known-globals map:
-- cross-unit references stay KNOWN (direct calls, 0-ary `call`,
-- fpr_obj_ value refs) because the importer parsed the dep anyway.
arities :: [STop] -> M.Map String Int
arities tops = M.fromList [(n, length ps) | TBind n ps _ _ <- tops]

isMain :: STop -> Bool
isMain (TBind "main" _ _ _) = True
isMain _ = False

bindNames :: [STop] -> S.Set String
bindNames = M.keysSet . arities

compileMain :: IO ()
compileMain = compileWithInterface (const (pure ()))

-- The manual Builtin RV32 runtime does not provide Base's boxed numeric
-- ABI. Refuse before code generation, including imported definitions and
-- unsaturated primitives. Base RV32 supports these through runtime boxes.
builtinWideFloat :: Core -> Bool
builtinWideFloat = coreHasName $ \n ->
  any (`isPrefixOf` n) ["F64.", "F32.", "I64."]
    || n `elem` ["f64frombits", "f32frombits"] || i32WidePrimitive n

i32WidePrimitive :: String -> Bool
i32WidePrimitive n = n `elem` map ("I32." ++)
  ["ofI64", "toI64", "toI64U", "ofF32", "ofF32U", "ofF64", "ofF64U",
   "toF32", "toF32U", "toF64", "toF64U", "ofF32Bits", "toF32Bits"]

coreHasName :: (String -> Bool) -> Core -> Bool
coreHasName test e = case e of
  CVar n -> test n
  CApp f a -> coreHasName test f || coreHasName test a
  CLam _ b -> coreHasName test b
  CLet _ a b -> coreHasName test a || coreHasName test b
  CIf c a b -> any (coreHasName test) [c,a,b]
  CMk _ _ xs -> any (coreHasName test) xs
  CTagEq _ _ a -> coreHasName test a
  CProj _ a -> coreHasName test a
  _ -> False

-- Return interfaces only after the SAME normal checker has accepted the unit.
-- No diagnostic parsing, alternate inference path or code-generation required.
checkedInterface :: FilePath -> IO [(Name, String)]
checkedInterface file = do
  ref <- newIORef []
  result <- try (withArgs ["--check-only", "--lib", file, "/dev/null"]
                  (compileWithInterface (writeIORef ref))) :: IO (Either ExitCode ())
  case result of
    Left ExitSuccess -> readIORef ref
    Left code -> exitWith code
    Right () -> readIORef ref

compileWithInterface :: ([(Name, String)] -> IO ()) -> IO ()
compileWithInterface accepted = do
  setLocaleEncoding utf8
  args <- getArgs
  let opts0 = parseCompileArguments args
      checkOnly = oCheckOnly opts0
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
  (rootSrc0, rootTopsParsed) <- parseFileSrc inp
  -- the PROFILE is the file's: `profile base.` (or `unsafe base.`), a
  -- .sol file is sol; the flag serves a file that says nothing, and
  -- may not contradict one that does.  Base is the default.
  let declared = case declaredProfile rootTopsParsed of
        Just d -> Just d
        Nothing | takeExtension inp == ".sol" -> Just "sol"
                | otherwise -> Nothing
      refuse m = hPutStrLn stderr ("error: " ++ m) >> exitFailure
  profile <- case (declared, oProfileFlag opts0) of
    (Just d, Just f) | d /= f -> refuse ("the file declares `profile " ++ d ++ ".` but the command line asks for " ++ f) >> pure d
    (Just d, _) -> pure d
    (Nothing, Just f) -> pure f
    (Nothing, Nothing) -> pure "base"
  configured <- Options.readCompilerOptions
  let configuration = Options.disableInlining (oNoInline opts0) configured
      codegen = Options.codegenOptions configuration
      native = Options.nativeOptions codegen
      diagnostic = Options.diagnosticOptions configuration
  let system = fromMaybe "bare-metal" (oSystem opts0)
      espHost = oHost opts0 == Just "esp-idf" -- the posix system on an ESP-IDF board (docs/2026-09-23-ESP-IDF.md)
      opts = opts0 {oBuiltin = profile == "builtin", oSol = oSol opts0 || profile == "sol", oNoInline = not (Options.cgInline codegen)}
  -- the posix system's hosts: this machine (unix, the default) and esp-idf
  case oHost opts0 of
    Just h | h /= "esp-idf" -> refuse ("--host=" ++ h ++ ": the posix system's hosts are unix (this machine, the default) and esp-idf")
    Just h | system /= "posix" -> refuse ("--host=" ++ h ++ " is a kind of posix host: it goes with --system=posix, not " ++ system)
    _ -> pure ()
  -- the matrix (docs/2026-09-19-PROFILES.md): builtin is bare metal only, sol is
  -- the posix host only, base and extbase run anywhere with a HAL
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
  -- --prelude=FILE as given; no flag = the prelude beside the binary
  -- (core/prelude.fpr under Home.fprHome), so `fpr compile x.fpr x.s`
  -- means the same thing from any directory; --prelude= (empty) = none
  prelude <- case oPrelude opts of
    Just "" -> pure Nothing
    Just f -> pure (Just f)
    Nothing | oBuiltin opts -> pure Nothing
            | otherwise -> underHome ("core" </> "prelude.fpr")
  let opts' = opts {oPrelude = prelude}
  (preludeSrc, preludeTops0) <- maybe (pure ("", [])) parseFileSrc prelude
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
  foreignTops <- fmap concat . forM (envForeign ++ oForeign opts) $ \f -> do
    ts <- parseFile f
    let strays = [n | TBind n _ _ _ <- ts]
    unless (null strays) $ do
      hPutStrLn stderr ("--foreign=" ++ f ++ ": declarations only; it defines " ++ unwords (take 5 strays))
      exitFailure
    pure [t | t@(TSig {}) <- ts]
  let preludeTops = preludeTops0 ++ foreignTops
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
  lr <- loadProgram preludeTops inp rootTops
  case lr of
    Left e -> putStrLn e >> exitFailure
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
              [ M.singleton inp rootSrc,
                maybe M.empty (`M.singleton` preludeSrc) (oPrelude opts'),
                unitSources
              ]
          anchored = map (anchorMsg sources anchors)
          anchoredDiagnostics = map (Diagnostic.renderSourceDiagnostic sources anchors)
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
        exitFailure
      -- A received message dies with its turn (docs/2026-10-24-REGIONS-STAGE1.md):
      -- the runtime releases every root an actor took when the turn that
      -- took it ends, so the compiler inserts no `drop` any more (the
      -- autoDrop pass of docs/2026-08-25-MEMORY.md is retired).
      let (tops0, asNotes) = aritySpill tops0R
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
          root' = expandU (fst (aritySpill root0))
          units = [(h, expandU (fst (aritySpill uts))) | (h, uts) <- units0]
          tops = expandU tops0
      unless (null preludeExpErrs) $ do
        putStrLn "=== SIG/STRUCT: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored preludeExpErrs)
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
      let inferred = inferTopsChecked (Namespace rootHash) aotProf sigs structs tops'
          terrs = inferenceDiagnostics inferred
          notes = inferenceNotes inferred
          holes = inferenceHoles inferred
          linsigs = inferenceLinearity inferred
          interfaces = inferenceInterfaces inferred
      unless (null terrs) $ do
        putStrLn "=== TYPE ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchoredDiagnostics terrs)
        exitFailure
      -- typed holes: NAMED holes typecheck everything around them and
      -- then refuse to compile, with the inferred type -- exactly the
      -- "let it typecheck, don't let it ship" contract.  ?? holes were
      -- elaborated to runtime traps and pass through.
      let named = [(n, t) | (n, t) <- holes, not (null n)]
      unless (null named) $ do
        putStrLn "=== TYPED HOLES ==="
        mapM_ (\(n, t) -> putStrLn ("  * got into a typed hole, ?" ++ n ++ " : " ++ t)) named
        unless (null [t | (_, t) <- holes, False]) (pure ())
        exitFailure
      case inferenceEvidence inferred of
        Right (Just _) -> pure ()
        Left reason -> hPutStrLn stderr ("compiler inference evidence: " ++ reason) >> exitFailure
        Right Nothing -> hPutStrLn stderr "compiler inference evidence: capture missing" >> exitFailure
      checkedLowering <- either (\reason -> hPutStrLn stderr ("compiler typed Core: " ++ reason) >> exitFailure) pure (prepareChecked inferred)
      unless (null [() | (n, _) <- holes, null n]) $
        mapM_ (\(_, t) -> putStrLn ("note: ?? hole (runtime trap) : " ++ t)) [h | h@(n, _) <- holes, null n]
      -- the safe/unsafe line (Safety.hs): recursion and unsafe-taint
      -- must be DECLARED.  --no-safety exists for transition only.
      unless (oNoSafety opts || oBuiltin opts) $ do
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
          when (Options.diagUnsafeSuggest diagnostic && not (null ssug)) $ do
            putStrLn "-- paste-ready signatures (inferred types):"
            mapM_ (putStrLn . ("SUGGEST " ++)) ssug
          exitFailure
      -- One owned source product supplies the compatibility analyses and
      -- typed structure transformation. Units keep their checked projections;
      -- root clones preserve types/identities before layout and closure lifting.
      specialized <- case specializeCheckedSource checkedLowering of
        Left specErrs -> do
          putStrLn "=== SIG/STRUCT: ERRORS ==="
          mapM_ (putStrLn . ("  * " ++)) (anchored specErrs)
          exitFailure
        Right source -> pure source
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
          shapes = collectShapes finalTops -- structural fnv ids: globally consistent
          nativeLayouts=Layouts consAll shapes
          compileSelected mode selected=either error id (selected >>= NativeCore.compileSelection mode nativeLayouts)
          prepareRegions result=either error id (Regions.prepare result)
          selectRoot uts=selectSpecialized (M.keysSet consAll) specialized (bindNames uts)
          compileRaw uts=prepareRegions (compileSelected PreserveCallbacks (selectRoot uts))
          callbackMode=if Options.cgSpecialize codegen && not (oArc opts) then SpecializeCallbacks else PreserveCallbacks
          nativeUnit unit=compileSelected PreserveCallbacks (selectUnit (M.keysSet consAll) unit)
          regionContext=Regions.context (fst (measureCheck tops)) (compileRaw finalTops)
          runTurnsWith regions input=if oBuiltin opts || oArc opts || not (Options.cgReceiveTurns codegen)
            then Regions.bypass input
            else either error id (Regions.place
              (Regions.Options (regions && Options.cgLoopRegions codegen) (regions && Options.cgCallRegions codegen) (not (oQosApp opts))) regionContext input)
          runTurns=runTurnsWith True
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
            Right m -> pure (Just m)
      when (oCost opts || declaredAny) $ do
        let costProg = fst (turnPassWith False (compileRaw finalTops))
            (measTable, _) = measureCheck tops
            surface = M.fromList [(n, [case p of PVar v -> v; PSig v _ -> v; _ -> "arg" ++ show i | (i, p) <- zip [1 :: Int ..] ps]) | TBind n ps _ _ <- firstClauses finalTops]
            firstClauses ts = M.elems (M.fromListWith (\_ old -> old) [(n, t) | t@(TBind n _ _ _) <- ts])
            coefs = maybe M.empty mCoefs manifest
            prims = maybe M.empty mPrims manifest
            (declared0, declErrs) = Cost.declaredBounds (M.keysSet coefs) surface costProg finalTops
            -- the manifest binds the coefficients; without one a bound that
            -- uses them stays symbolic and cannot be judged
            declared = M.map (\d -> d {Cost.dWork = Cost.substCoefs coefs <$> Cost.dWork d, Cost.dAlloc = Cost.substCoefs coefs <$> Cost.dAlloc d, Cost.dLive = Cost.substCoefs coefs <$> Cost.dLive d}) declared0
            eqs = Cost.costProgram measTable declared costProg
            rootNames = [n | n <- S.toList rootBinds, M.member n costProg]
            priceW g = fst <$> M.lookup g prims
            priceA g = snd <$> M.lookup g prims
            -- checked and printed in the function's surface parameter names
            verdicts =
              [ (n, kind, derivedC', declC, verdict)
                | (n, d) <- M.toList declared,
                  Just (Cost.CostEq w a l _, _) <- [M.lookup n eqs],
                  (kind, derivedC, Just declC, price) <- [("work", w, Cost.dWork d, priceW), ("alloc", a, Cost.dAlloc d, priceA), ("live", l, Cost.dLive d, priceA)],
                  let derivedC' = Cost.resolvePrims price derivedC
                      verdict = case Cost.coefsIn declC of
                        [] -> Cost.checkBoundsWith (renamerFor n) derivedC' declC
                        ks -> Cost.Unproved ["coefficient " ++ k ++ " (bind it in a manifest: --manifest=FILE)" | k <- ks]
              ]
            renamerFor n =
              let ren = M.fromList (zip (fst (M.findWithDefault ([], CErr "") n costProg)) (M.findWithDefault [] n surface))
                  r p = M.findWithDefault p p ren
                  rn c = case c of
                    Cost.CP p -> Cost.CP (r p)
                    Cost.CLen p -> Cost.CLen (r p)
                    Cost.CW p -> Cost.CW (r p)
                    Cost.CA p -> Cost.CA (r p)
                    _ -> c
               in rn
            failed = [v | v@(_, _, _, _, verdict) <- verdicts, verdict /= Cost.Proven]
            renderV (n, kind, d, c, v) = n ++ ": declared " ++ kind ++ " <= " ++ Cost.prettyIn surface costProg n c ++ "   derived " ++ Cost.prettyIn surface costProg n d ++ "   " ++ Cost.renderVerdict v
        when (oCost opts) $ do
          putStrLn "cost (work in abstract ops; alloc in requested cell bytes; live where it differs; ω = opaque):"
          mapM_ putStrLn (Cost.renderReport surface costProg (M.map fst eqs) (M.keysSet (M.filter (\d -> Cost.dLive d /= Nothing) declared)) rootNames)
          unless (null verdicts) $ do
            putStrLn "declared bounds:"
            mapM_ (putStrLn . ("  " ++) . renderV) verdicts
          let sizes = [(n, sz) | (n, d) <- M.toList declared, Just sz <- [Cost.dSize d]]
          unless (null sizes) $ do
            putStrLn "assumed result sizes (declared, not verified by this pass):"
            mapM_ (\(n, sz) -> putStrLn ("  " ++ n ++ ": size <= " ++ Cost.prettyIn surface costProg n sz)) sizes
        -- ---- the judgement against a target (stage 3) ----
        let orDash x = if null x then "-" else x
        budgetFails <- case manifest of
          Nothing -> pure []
          Just m -> do
            putStrLn ("target " ++ mName m ++ ": compiler " ++ orDash (mCompiler m) ++ ", runtime " ++ orDash (mRuntime m) ++ ", " ++ orDash (mHardware m) ++ "; " ++ show (fromRational (mNsPerOp m) :: Double) ++ " ns/op")
            unless (null (mAssume m)) $ putStrLn ("assumptions: " ++ intercalate "; " (mAssume m))
            let judge n = case M.lookup n eqs of
                  Nothing -> Nothing
                  Just (Cost.CostEq w _ _ _, _) ->
                    let w' = Cost.resolvePrims priceW w
                        shown = Cost.prettyIn surface costProg n w'
                        budget = M.lookup n (mBudgets m)
                        line = case (Cost.evalConst w', Cost.omegas w', budget) of
                          (Just ops, _, Just b) ->
                            let ns = fromIntegral ops * mNsPerOp m
                             in (ns <= b, "work " ++ show ops ++ " ops → " ++ renderNs ns ++ (if ns <= b then "   PROVEN within budget " else "   OVER budget ") ++ renderNs b)
                          (Just ops, _, Nothing) -> (True, "work " ++ show ops ++ " ops → " ++ renderNs (fromIntegral ops * mNsPerOp m))
                          (Nothing, [], Just b) -> (False, "work <= " ++ shown ++ "   UNPROVED against budget " ++ renderNs b ++ " (parametric: bound the parameters with preconditions)")
                          (Nothing, [], Nothing) -> (True, "work <= " ++ shown ++ "   (parametric; × " ++ show (fromRational (mNsPerOp m) :: Double) ++ " ns)")
                          (Nothing, os, Just b) -> (False, "work <= " ++ shown ++ "   UNPROVED against budget " ++ renderNs b ++ " (opaque: " ++ intercalate ", " os ++ ")")
                          (Nothing, os, Nothing) -> (True, "work <= " ++ shown ++ "   UNPROVED (opaque: " ++ intercalate ", " os ++ ")")
                     in Just line
                width = maximum (8 : map length rootNames)
                rows = [(n, l) | n <- rootNames, Just l <- [judge n]]
            mapM_ (\(n, (_, l)) -> putStrLn ("  " ++ n ++ replicate (width - length n) ' ' ++ "  " ++ l)) rows
            let unknownBudgets = [f | f <- M.keys (mBudgets m), f `notElem` rootNames]
            unless (null unknownBudgets) $ putStrLn ("  (budgets for names not in this program: " ++ intercalate ", " unknownBudgets ++ ")")
            pure [n ++ ": " ++ l | (n, (ok, l)) <- rows, not ok]
        unless (null declErrs && null failed && null budgetFails) $ do
          putStrLn "=== COST: ERRORS ==="
          mapM_ (putStrLn . ("  * " ++)) (anchored declErrs)
          mapM_ (putStrLn . ("  * " ++) . renderV) failed
          mapM_ (putStrLn . ("  * " ++)) budgetFails
          exitFailure
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
      when checkOnly exitSuccess
      -- ---- per-unit CODEGEN (separate compilation) ----
      -- Every unit consumes its owned projection of merged source checking.
      -- Rechecking only a unit plus prelude loses transitive import types and
      -- could silently emit defaulted integer operations after ignored errors.
      -- Surface specialization clones still belong to the root compatibility
      -- path until that transformation preserves typed contracts too.
      let owned uts = either error id (selectCheckedUnit checkedLowering (bindNames uts))
          preludeChecked = owned preludeE'
          checkedUnits = [(h,uts,owned uts) | (h,uts)<-units']
          -- --cost: every boundary placed, by rule, and a count of the pure
          -- groups declined; FPR_RECEIVE_NOTES=1 lists the declined ones too
          -- (docs/2026-10-24-REGIONS-STAGE2.md)
          reportTurns result = when ((Options.diagReceiveNotes diagnostic) || oCost opts) $ do
            let ns=Regions.resultNotes result
                declined = [n | n <- ns, "turn-regions (declined): " `isPrefixOf` n]
            mapM_ (hPutStrLn stderr) (if (Options.diagReceiveNotes diagnostic) then ns else filter (`notElem` declined) ns)
            when (not (Options.diagReceiveNotes diagnostic) && not (null declined)) $
              hPutStrLn stderr ("turn-regions: " ++ show (length declined) ++ " self-tail-call group(s) declined (unbounded or unproven state); FPR_RECEIVE_NOTES=1 lists them")
            when (not (Options.cgLoopRegions codegen) && any ("turn-regions (candidate): " `isPrefixOf`) ns) $
              hPutStrLn stderr "turn-regions: the candidates above are not placed (FPR_NO_LOOP_REGIONS=1)"
          checkBuiltinWidth p = do
            when (oArc opts && any (coreHasName i32WidePrimitive . snd) (M.elems p)) $ do
              hPutStrLn stderr "I32 conversions with I64/F32/F64 currently require the manual ABI; --arc/--raw bridge ownership adapters are not implemented"
              exitFailure
            when (oBuiltin opts && tgtName (oTarget opts) == "rv32"
                   && any (builtinWideFloat . snd) (M.elems p)) $ do
              hPutStrLn stderr "profile builtin RV32: F64 and I64 require a 64-bit value ABI; F32 also requires the boxed Base runtime; I32 wide conversions require Base"
              exitFailure
          -- Checked entries can be owned by the root (including contracts
          -- added to prelude functions). Every unit also needs the physical
          -- arity of any checked global it references, including root entries.
          checkedExt = arities [t | t@(TBind n _ _ _) <- finalTops, "$precond" `isPrefixOf` n]
          sourceExt = M.union checkedExt (checkedCallArities checkedLowering)
          extFor = M.union (if oArc opts then arcExterns else M.empty) sourceExt -- own names win via prog-first lookup
          -- primitive arities for direct calls: the compiler's builtin
          -- schemes, and every bare signature (foreign declarations --
          -- a signature with a definition names a global, which the
          -- generator finds first)
          halAr =
            M.unions
              [ M.fromList [(n, length as) | TSig n (as, _) _ <- preludeE' ++ concatMap snd units' ++ root'],
                M.map (\(Forall _ _ t) -> arrows t) builtinEnv,
                -- pair-free reads planned by Core.Typed.VectorRead (vec.c)
                M.fromList (VectorRead.peekArities++[("$receiveLoop", 2), ("$regionSeq", 1), ("$regionOpen", 1), ("$regionMark", 1), ("$regionRoom", 1), ("$regionCycle", 2), ("$loopLeave", 2), ("$callPend", 1), ("$callLeave", 2)]) ]
          arrows (TFn _ r) = 1 + arrows r
          arrows _ = 0 :: Int
          tgt = (oTarget opts) {tgtFuel = not (oBuiltin opts), tgtArc = oArc opts, tgtWeak = oLib opts, tgtHal = halAr, tgtFloatInline = (Options.cgFloatInline codegen), tgtSimd=(oA64 opts || oX64 opts) && (Options.cgSimd codegen), tgtFusion=(Options.cgFusion codegen),
                               tgtScalarFast = True, tgtIndexedMemory = (Options.cgIndexedMemory codegen), tgtScalarWorkers = (Options.cgScalarWorkers codegen), tgtFieldWorkers = (Options.cgFieldWorkers codegen), tgtPipelineInline = (Options.cgPipelineInline codegen), tgtReuse = (Options.cgReuse codegen), tgtTypedIr = (Options.diagTypedIr diagnostic), tgtPolicy = irPolicy, tgtNative = nativeMode}
          a64 = oA64 opts
          a64mac = oA64Mac opts
          x64 = oX64 opts
          x64mac = oX64Mac opts
          qapp = oQosApp opts
          qsingle = oQosSingle opts
          -- the profile the typed-IR lowering states; everything but hosted
          -- Base is refused by name (Codegen.Policy)
          irPolicy = Policy
            { polProfile = if oArc opts then BuiltinArc
                           else if oBuiltin opts then (if tgtName (oTarget opts) == "rv32" then Builtin32 else Builtin)
                           else if tgtName (oTarget opts) == "rv32" then Rv32
                           else if qapp then QosApp
                           else HostedBase,
              polFuel = not (oBuiltin opts),
              polStackCheck = if oBuiltin opts then StackStatic else if (Options.nativeShallowStack native) then StackCheckShallow else StackCheckEveryEntry,
              polFloatInline = (Options.cgFloatInline codegen) }
          -- direct backends: the AArch64 hart read follows the
          -- target runtime ABI (x28 under fpr build, the TLV cell on a64mac
          -- without --base, local-exec TLS on a64 ELF)
          nativeMode = Just NativeMode
              { nmGranularity = Options.nativeGranularity native,
                nmStrict = (Options.nativeStrict native),
                nmTargetName = if x64 then "x64" else if a64 then "a64" else tgtName (oTarget opts),
                nmBackend = if a64 && not qapp
                              then Just (DirectA64 (if a64mac then MachO else ELF) (if oBase opts then HartX28 else if a64mac then HartTlvMachO else HartTlsElf))
                              -- a loaded QOS app (and plugin): the hart is x28, or the
                              -- global cell under qa64single (docs/2026-10-22-TYPED-IR-QOS.md)
                              else if a64 && qapp
                                then Just (DirectA64 (if a64mac then MachO else ELF) (if oQosSingle opts then HartGlobal else HartX28))
                              else if x64 then Just (if qapp then DirectQX64 else DirectX64 (if x64mac then MachO else ELF))
                              -- a posix module (--module on rv64) reads the hart through
                              -- initial-exec TLS and is assembled under .option pic
                              -- (docs/2026-10-23-TYPED-RV64-MODULES.md). Plain bare-metal
                              -- plugins retain tp, just like bare-metal executables.
                              -- a QOS RISC-V app or plugin (qrv64) borrows the host's hart cell through
                              -- fpr_g_tlsoff (docs/2026-10-23-TYPED-QRV64.md)
                              -- the ESP-IDF host (rv32) keeps its hart in fpr_esp_hart
                              -- (docs/2026-10-23-TYPED-QRV64.md)
                              else if not a64 && not x64 && tgtName (oTarget opts) `elem` ["rv32", "rv64"]
                                      && (not qapp || tgtName (oTarget opts) == "rv64")
                                then Just (DirectRV (policyWidth irPolicy)
                                             (if espHost then RV.HartTlsEsp else if qapp then RV.HartQos else if oBase opts && oPlugin opts then RV.HartTlsIe else if oBase opts then RV.HartTls else RV.HartTp))
                              else Nothing,
                nmSelfLoops = (Options.nativeSelfLoops native), nmForwardParams = (Options.nativeForwardParams native),
                nmTune = Tune (Options.nativeEntryArgs native) (Options.nativeShrinkWrap native) (Options.nativeFpPool native) (Options.nativeLinkPairs native), nmSplitEntry = (Options.nativeSplitEntry native) }
          -- Every selected backend owns the whole output. A named subset can
          -- no longer permit another function or kernel to bypass typed IR.
          strictCheck what fallbacks = unless (null fallbacks) (strictFail what fallbacks)
          strictFail what fallbacks = do
            hPutStrLn stderr ("typed-ir strict: " ++ what ++ ": " ++ show (length fallbacks) ++ " function(s) did not take the native backend:")
            mapM_ (\(n, r) -> hPutStrLn stderr ("  " ++ n ++ ": " ++ r)) fallbacks
            exitFailure
          directCheck what emission = do
            strictCheck what (emScalarFallbacks emission)
            strictCheck what (emRefusals emission)
          -- a loaded posix module reaches external symbols through the GOT;
          -- the pass works on target syntax and leaves its own output
          -- alone, so it also covers the typed backend's text and a
          -- translation-free unit (docs/2026-10-22-TYPED-IR-RETIREMENT.md)
          moduleFinal = if oBase opts && oPlugin opts
                          then (if a64 || x64 then id else \t -> if null t then t else "    .option pic\n" ++ t) . posixPic a64 (a64mac || x64mac)
                          else id
          rvv = oRvv opts && not a64 && not x64 -- no RVV lowering in the PoCs
          spec = True -- x64 lowers the extra saved registers through its shadow bank
          -- every distinct lowering its own cache tag: a QOS app on Apple Silicon
          -- and a hosted posix program once shared "a64macr" while generating
          -- different code, and hosted AArch64 now reads its hart from x28
          tname0 = if qsingle then "qa64singler" ++ show a64InterfaceRev
                  else if a64mac && qapp then "qa64macr" ++ show a64InterfaceRev
                  else if a64mac then (if oPlugin opts && oBase opts then "module-" else "") ++ "a64macx28r" ++ show a64HostedInterfaceRev
                  else if a64 && qapp then "qa64r" ++ show a64InterfaceRev
                  else if a64 then "a64x28r" ++ show a64HostedInterfaceRev
                  else if x64 && qapp then "qx64r" ++ show x64InterfaceRev
                  else if x64mac then (if oPlugin opts && oBase opts then "module-" else "") ++ "x64macr" ++ show x64InterfaceRev
                  else if x64 then "x64r" ++ show x64InterfaceRev
                  else if espHost then "rv32-idftls1"
                  else if qapp then "qrv64r" ++ show RV.rvSelectionRev
                  else if oBase opts then "rv64posixr" ++ show RV.rvSelectionRev
                  else tgtName tgt
          tname = (if oBase opts && oPlugin opts then "posix-module-" else "") ++ tname0
          -- A root can constrain a global foreign primitive used inside an
          -- unchanged imported unit. Cache that contract context as well as
          -- source/prelude/shape identity so another root cannot reuse raw calls.
          contractHash = hashAST [t | t@(TSig n _ _) <- tops, M.member n preTab]
          -- A separate native-only cache policy prevents old fallback units
          -- bypassing directCheck, while tname retains module ABI identity.
          backendTag = "-tirbe" ++ (if x64 then "x64-" ++ show x64SelectionRev else if a64 then show a64SelectionRev else tgtName (oTarget opts) ++ "-" ++ show RV.rvSelectionRev)
            ++ (if a64 || x64 then "-native1" else "")
            ++ Options.nativeOptionFlags (a64 && not qapp) native
          tag = "g" ++ show codegenRev ++ backendTag ++ Options.optimizationFlags codegen
            ++ "rt3pc5-c" ++ take 12 contractHash ++ "-" ++ tname ++ (if rvv then "-rvv" else "")
            ++ Options.vectorOptionFlags codegen ++ (if oBuiltin opts then "-builtin" else "") ++ (if oArc opts then "-arc" ++ show arcRev else "")
          unitDir = takeDirectory out </> "units"
          -- --arc: lower ownership, then inline the small helpers at
          -- their sites (Inline.hs) before the generator sees the unit
          arcSignatures=NativeRep.signatures (Linked.artifactCore (artifactOf Linked.RootArtifact))
          own=ownWith M.empty
          ownWith imports prog = if oArc opts then do
                       lowered <- either (\e -> hPutStrLn stderr e >> exitFailure) (pure . inlineSmall 3 24) ((if oRaw opts then lowerRawWith else lowerArcWith) (M.restrictKeys arcSignatures (M.keysSet prog)) sourceExt prog)
                       -- FPR_DUMP_CORE=name prints that function's Core as the generator sees it
                       let dump = Options.diagCore diagnostic
                       forM_ [(n, d) | Just want <- [dump], (n, d) <- M.toList lowered, takeWhile (/= '@') n == want] $ \(n, d) ->
                         hPutStrLn stderr ("core " ++ n ++ ": " ++ show d ++ "\nnormalized: " ++ show (fmap normArc d))
                       pure lowered
                     -- Base checked owners were already inlined before
                     -- region placement. Only compatibility bodies/templates
                     -- and their vector-read transform run here.
                     else do
                       let inl = (if oNoInline opts then id else inlineCompatibilityWithImports checkedCallbackTargets imports pureOutside 3 24) (if (not (Options.cgVecPeek codegen)) then prog else vecPeekCompatibility checkedCallbackTargets prog)
                       let dump = Options.diagCore diagnostic
                       forM_ [(n, d) | Just want <- [dump], (n, d) <- M.toList inl, takeWhile (/= '@') n == want] $ \(n, d) ->
                         hPutStrLn stderr ("core " ++ n ++ ": " ++ show d)
                       pure inl
          pureOutside g = maybe False (> 0) (M.lookup g extFor) || maybe False (> 0) (M.lookup g halAr) || g `elem` corePrimNames
          corePrimNames = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">=", "strcat", "str", "String.len"]
          mono ns ext p = if (not (Options.cgSpecialize codegen)) || oArc opts then p else specializeCompatibility checkedCallbackTargets importedPrivateNames ns halAr ext p
          checkedCallbackTargets=typedRegionNames `S.union` S.fromList [name | (_,Linked.SymbolOwner _ definition)<-M.toList (Linked.linkedSymbols linked),
            name<-case definition of Linked.SourceDefinition n _ _->[n];Linked.PrivateDefinition _ (TCore.CodeId n) _->[n];_->[]]
          typedRegionNames=S.unions [M.keysSet (TypedRegions.programFunctions p) | p<-M.elems typedRegionPrograms]
          -- constructor stub ownership.  Every unit's Core holds a stub per
          -- constructor of the program (compileTop's conGlobals: the inliner
          -- and `known` need them); the SYMBOL is defined once, by the owner,
          -- and elided from every other unit's emission.  The prelude unit
          -- owns the builtin and prelude constructors when it is emitted,
          -- else the root does; a unit owns its own types; the root its own.
          -- Under --arc nothing is elided (the root is the whole program).
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
          rootNames = S.fromList ([fst3 b | b@(TBind {}) <- root'])
          rootLoweredNames = bindNames root''
          unitNames = S.fromList (concat [[fst3 b | b@(TBind {}) <- uts] | (_, uts) <- units'])
          preludeNames = bindNames preludeE'
          rootProgTops =
            [ t | t@(TBind n _ _ _) <- finalTops,
                  S.member n rootLoweredNames
                    || (not (S.member n unitNames) && not (S.member n preludeNames))
            ]
          rootNative=compileSelected PreserveCallbacks (selectRoot (if oArc opts then finalTops else rootProgTops))
          artifactResults=
            Linked.artifact Linked.RootArtifact
              (if oArc opts then M.keysSet (NativeCore.nativeProgram rootNative) else bindNames root'' `S.union` rootCons)
              (if oArc opts then S.empty else rootElided) rootNative
            : [Linked.artifact (Linked.PreludeArtifact preludeHash) (bindNames preludeE' `S.union` preludeCons)
                preludeElided (nativeUnit preludeChecked) | preludeEmitted]
            ++ [Linked.artifact (Linked.DependencyArtifact h) (bindNames uts `S.union` unitConsOf h)
                (unitElided h) (nativeUnit unit) | (h,uts,unit)<-checkedUnits,unitsEmitted]
          linkedResult=do
            base<-sequence artifactResults >>= Linked.linkArtifacts
            original<-checkedStage "callback specialization before inlining" (Linked.specializeLinked callbackMode base)
            inlined<-if oArc opts || oNoInline opts then pure original else
              do inlined<-checkedStage "checked Base inlining" (Linked.inlineLinked 3 24 original)
                 checkedStage "callback specialization after inlining" (Linked.specializeLinked callbackMode inlined)
            vectors<-if oArc opts || not (Options.cgVecPeek codegen) then pure inlined else
              checkedStage "checked vector reads" (Linked.planVectorReadsLinked inlined)
            normalized<-if oArc opts || oBuiltin opts || Backend.tgtW (oTarget opts)/=8 || not (Options.cgReuse codegen) then pure vectors else
              checkedStage "checked Base normalization" (Linked.normalizeLinked vectors)
            if oArc opts || not (Options.cgFusion codegen) then pure (normalized,[]) else
              checkedStage "checked vector fusion" (Linked.fuseLinked normalized)
          checkedStage label=either (Left . ((label++": ")++)) Right
          (linked,fusionNotes)=either error id linkedResult
          declarationsResult=do
            (verified,_)<-linkedResult
            base<-NativeImports.codeDeclarations verified
            NativeImports.withRegions typedRegionPrograms base
          declarations=either error id declarationsResult
          artifactOf key=Linked.linkedArtifacts linked M.! key
          artifactRaw=prepareRegions . Linked.artifactCore
          regionArtifacts=M.map (runTurns . artifactRaw) (Linked.linkedArtifacts linked)
          typedRegionPrograms=M.mapMaybe Regions.resultTyped regionArtifacts
          artifactRegions key=regionArtifacts M.! key
          ready templates key exports prog=either (\reason->hPutStrLn stderr reason >> exitFailure) pure
            (NativeImports.prepareEmissionWithImports templates declarations key exports prog)
          importedPrivateNames=S.unions [NativeImports.preservedCode declarations key
            | key<-M.keys (Linked.linkedArtifacts linked),key/=Linked.RootArtifact]
          rootProgRaw=Regions.resultProgram (artifactRegions Linked.RootArtifact)
          -- a constructor is global everywhere: a clone that references one
          -- links against the owner's symbol, so qualifyAux leaves the name
          importedCore = M.unions
            [qualifyAux (prefix key) (Linked.artifactExports a `S.union` allCons `S.union` NativeImports.preservedCode declarations key) (Regions.resultProgram (artifactRegions key))
              | (key,a)<-M.toList (Linked.linkedArtifacts linked),key/=Linked.RootArtifact]
          prefix (Linked.PreludeArtifact h)="$specaux.p"++take 12 h++"."
          prefix (Linked.DependencyArtifact h)="$specaux.u"++take 12 h++"."
          prefix Linked.RootArtifact=error "native link: root is not an imported artifact"
          applyReport label asm = when (Options.diagApply diagnostic) $ hPutStrLn stderr
            ("apply " ++ label ++ ": dispatch=" ++ show (length [() | l <- lines asm, "fpr_apply" `List.isInfixOf` l, any (`List.isInfixOf` l) ["call ", "bl "]])
             ++ " known-partial=" ++ show (length [() | l <- lines asm, "# pap-create:" `List.isPrefixOf` l])
             ++ " static-descriptors=" ++ show (length [() | l <- lines asm, "# static-pap:" `List.isPrefixOf` l]))
          emitUnit pathBase ext artifact = do
            let placed=artifactRegions (Linked.artifactId artifact)
                exps=Linked.artifactExports artifact
                elide=Linked.artifactElided artifact
                unitProgram=Regions.resultProgram placed
                path=pathBase++"-c"++coreCacheIdentity elide (CallArities ext halAr) unitProgram++"-"++tag++".s"
            reportTurns placed
            checkBuiltinWidth unitProgram
            cached <- doesFileExist path
            if cached
              then do
                when (Options.diagApply diagnostic) (readFile path >>= applyReport (takeFileName path))
                pure (path, "cached")
              else do
                prog <- own (mono (takeFileName path) M.empty unitProgram)
                prepared<-ready M.empty (Linked.artifactId artifact) exps prog
                -- FORCE before the write: an `error` raised while the
                -- assembly is lazily produced must propagate, never
                -- leave an empty file the cache then serves as a valid
                -- compiled unit (the bbspi arity>8 incident)
                let emission = emitCheckedProgramWithImports (if oArc opts then S.empty else checkedCallbackTargets) (NativeImports.readyTemplates prepared) tgt rvv spec []
                      (NativeImports.importArities prepared `M.union` M.union (if oArc opts then arcExterns else M.empty) ext)
                      (NativeImports.readySymbols prepared) elide (NativeImports.readyProgram prepared)
                    vnotes = emNotes emission
                    asm = moduleFinal (unlines (["# typed IR: no translation"] ++ emNative emission ++ emData emission))
                directCheck ("unit " ++ takeFileName path) emission
                mapM_ putStrLn vnotes
                -- written beside it and renamed whole: a build running at the
                -- same time (check_base runs many) finds the unit complete or
                -- absent, never half-written and taken as cached
                length asm `seq` writeWhole path asm
                nativeSummary (Options.diagNativeInsns diagnostic) ("unit " ++ takeFileName path) asm
                applyReport (takeFileName path) asm
                pure (path, show (M.size prog) ++ " supercombinators")
      -- Validate the complete linked ownership/interface product before any
      -- artifact is reused or emitted. Later legacy passes consume projections;
      -- they do not replace the retained checked inputs with inferred evidence.
      either (\reason->hPutStrLn stderr reason >> exitFailure) (const (pure ())) linkedResult
      mapM_ (putStrLn . TypedFusion.renderNote) fusionNotes
      either (\reason->hPutStrLn stderr reason >> exitFailure) (const (pure ())) declarationsResult
      createDirectoryIfMissing True unitDir
      -- prelude unit (unqualified names; the always-linked stdlib unit).
      -- The prelude is self-contained, so resolve its own operators.
      preludeOut <-
        if oArc opts || null preludeTops
          then pure []
          else do
            r <- emitUnit (unitDir </> ("prelude-" ++ take 12 preludeHash)) extFor (artifactOf (Linked.PreludeArtifact preludeHash))
            pure [r]
      -- dep module units (hash-qualified; filename carries the prelude
      -- hash too -- unit code depends on prelude arities -- AND a hash of
      -- the whole program's record SHAPES: a unit's row-typed projections
      -- (`st.uart`) compile to a tag chain over the shapes this program
      -- declares, so a unit compiled under one program is wrong for
      -- another with a different shape set (the uartroute/timerroute
      -- incident: a cached svc unit from a program without the field)
      let shapesHash = hashAST [TShape (concat fs) [] | fs <- M.keys shapes]
      unitOuts <- forM (if oArc opts then [] else checkedUnits) $ \(h, uts, unit) ->
        emitUnit (unitDir </> ("u-" ++ take 12 h ++ "-p" ++ take 8 preludeHash ++ "-s" ++ take 8 shapesHash))
                 extFor (artifactOf (Linked.DependencyArtifact h))
      -- the root: exports its own binds; modtab (all dep exports) lives
      -- here. Root codegen uses the FULLY specialized+resolved tops
      -- (finalTops), filtered to root's own names + any monomorphized
      -- clones (clones have no home unit; they ride with the root).
      let rootExports =
            [ ModExport rootHash n n (length ps) ""
              | oPlugin opts,
                TBind n ps _ _ <- rootProgTops, S.member n rootNames
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
          opaque n = any (ownsUnsafe n) unsafeMarkers
                     || any (\(_, _, pres) -> any (\p -> (fst <$> p) == Just "$size") pres) (contractFor n)
          stamp e = case M.lookup (meQual e) checkedTypes of
            Nothing -> ""
            Just ty | opaque (meQual e) || oManifest opts /= Nothing -> ""
                    | otherwise -> "fpr-interface-1/g" ++ show codegenRev
                        ++ "/" ++ preludeHash ++ "/" ++ hashAST foreignTops
                        ++ "/" ++ tname ++ "/hardfloat=" ++ show (oHardFloat opts)
                        ++ "/" ++ canonicalTypeWith interfaceName ty
                        ++ "/precond=2"
                        ++ "/contracts=" ++ show (contractFor (meQual e))
                        ++ "/arity=" ++ show (meArity e)
          checkedTarget n = if M.member n preTab then checkedName n 0 else n
          imageExports = [e {meInterface = stamp e, meQual = checkedTarget (meQual e)} | e <- rawExports]
      -- Dynamic module lookup is a function-value boundary too. Its public
      -- identity/stamp stays the source API; the code pointer checks inputs.
      -- A curried implementation with fewer physical arguments cannot be
      -- flattened without delaying body effects, so refuse that export shape.
      let sourceArities = arities tops
          badContractExports = [meName e | e <- rawExports, M.member (meQual e) preTab,
            Just ps <- [M.lookup (meQual e) preTab],
            Just a <- [M.lookup (meQual e) sourceArities], a /= length ps]
      unless (null badContractExports) $ do
        hPutStrLn stderr ("precondition: dynamic exports require matching signature and implementation arity: " ++ unwords badContractExports)
        exitFailure
      when (oBuiltin opts && not (oArc opts) && M.member "machineInterrupt" rootProgRaw) $ do
        hPutStrLn stderr "machineInterrupt requires --arc (raw, allocation-free handler ABI)"
        exitFailure
      checkBuiltinWidth rootProgRaw
      reportTurns (artifactRegions Linked.RootArtifact)
      rootProgSym <- case symbolize rootProgRaw of
        Left e -> hPutStrLn stderr ("error: " ++ e) >> exitFailure
        Right p -> pure p
      -- Checked private code retains its home code/PAP identity. Only
      -- compatibility lifts still need copied, qualified definitions.
      importedSym <- if (not (Options.cgSpecialize codegen)) || oArc opts then pure M.empty else case symbolize importedCore of
        Left e -> hPutStrLn stderr ("error: " ++ e) >> exitFailure
        Right p -> pure p
      let borrowed=M.restrictKeys importedSym importedPrivateNames
      rootProg <- ownWith borrowed (mono ("root" ++ take 12 rootHash) importedSym rootProgSym)
      rootReady<-ready borrowed Linked.RootArtifact
        (if oArc opts then M.keysSet rootProg else Linked.artifactExports (artifactOf Linked.RootArtifact)) rootProg
      let rootEmission = emitCheckedProgramWithImports (if oArc opts then S.empty else checkedCallbackTargets) (NativeImports.readyTemplates rootReady) tgt rvv spec imageExports (NativeImports.importArities rootReady `M.union` extFor)
                                     (NativeImports.readySymbols rootReady)
                                     (Linked.artifactElided (artifactOf Linked.RootArtifact)) (NativeImports.readyProgram rootReady)
          rootVNotes = emNotes rootEmission
      -- Declaration admission produces checked plans; rendering only consumes
      -- their explicit sources, conversions, destinations and schedule.
      exports <- case Exports.prepareExports (if oHardFloat opts then HardFloat else SoftFloat)
        (oExports opts) tops0RL (M.map (length . fst) rootProg) (functionSymbol . checkedTarget) of
          Left err -> hPutStrLn stderr ("export " ++ Exports.exportSource err ++ ": " ++ Exports.exportMessage err) >> exitFailure
          Right checked -> pure checked
      tramps <- forM exports $ \entry -> do
        putStrLn (Exports.exportDescription entry)
        pure (renderAdapter (Exports.exportAdapter entry))
      -- the constructor-name table: what lets `print` say `Some 42` instead of
      -- `<613153155.1 42>`.  The root unit sees every unit's constructors
      -- (consAll), so it carries one table for the whole image; the runtime
      -- holds a weak empty one (runtime.c fpr_contab) for images without.
      let conRows = [ (tid, var, ar, reverse (takeWhile (/= '.') (reverse (takeWhile (/= '@') c))))
                    | (c, (tid, var, ar)) <- M.toList consAll, tid >= 0x20000000 ]
                    -- a record shape: its field names in storage order, comma-separated
                    ++ [ (sid, 0, length fs, intercalate "," fs) | (fs, sid) <- M.toList shapes ]
          dir = if tgtName tgt == "rv32" then ".word" else ".quad"
          conTab
            | oBuiltin opts || oLib opts || oPlugin opts = ""
            | otherwise = unlines $
                [ "", "# constructor names, for render", "    .section .rodata", "    .balign 8" ]
                  ++ concat [ [ ".Lfprcon" ++ show i ++ ":", "    .byte " ++ intercalate ", " (map (show . ord) nm ++ ["0"]) ]
                            | (i, (_, _, _, nm)) <- zip [0 :: Int ..] conRows ]
                  ++ [ "    .balign 8", "    .globl fpr_contab", "fpr_contab:" ]
                  ++ concat [ [ "    " ++ dir ++ " " ++ show tid, "    " ++ dir ++ " " ++ show var,
                                "    " ++ dir ++ " " ++ show ar, "    " ++ dir ++ " .Lfprcon" ++ show i ]
                            | (i, (tid, var, ar, _)) <- zip [0 :: Int ..] conRows ]
                  ++ [ "    " ++ dir ++ " 0", "    " ++ dir ++ " 0", "    " ++ dir ++ " 0", "    " ++ dir ++ " 0", "" ]
      let rootAsm = moduleFinal (unlines (["# typed IR: no translation"] ++ emNative rootEmission ++ emData rootEmission
                                   ++ dataSyntax directFormat (lines conTab))) ++ unlines (concat tramps)
          directFormat = if a64mac || x64mac then MachO else ELF
      directCheck "root" rootEmission
      mapM_ putStrLn rootVNotes
      applyReport "root" rootAsm
      writeFile out rootAsm
      nativeSummary (Options.diagNativeInsns diagnostic) "root" rootAsm
      -- the link list: everything the root's image needs beyond out itself
      writeFile (out ++ ".units") (unlines (map fst (preludeOut ++ unitOuts)))
      -- the ABI stamp half the compiler owns: mkqa folds this into the
      -- manifest (abi = "<QOS_ABI_VERSION>.<codegenRev>"); the loader
      -- refuses a mismatch.  Same artifact discipline as .units.
      writeFile (out ++ ".abirev") (show codegenRev)
      forM_ (preludeOut ++ unitOuts) $ \(p, note) -> putStrLn ("unit " ++ p ++ " (" ++ note ++ ")")
      putStrLn ("wrote " ++ out ++ " (" ++ show (M.size rootProg) ++ " supercombinators, linearity OK)")
      when (not (null imageExports)) $
        putStrLn ("module table: " ++ show (length [e | e <- imageExports, meArity e >= 1]) ++ " remote-callable exports")
      putStrLn "assumed external symbols (the fpr_g_ HAL/runtime contract):"
      putStrLn ("  " ++ unwords (externals extFor rootProg))

fst3 :: STop -> String
fst3 (TBind n _ _ _) = n
fst3 _ = ""

-- a cache file appears whole: written to a temp name in its directory, renamed
writeWhole :: FilePath -> String -> IO ()
writeWhole path text = do
  (tmp, h) <- openTempFile (takeDirectory path) (takeFileName path ++ ".tmp")
  hPutStr h text
  hClose h
  renameFile tmp path

-- Target instruction distances between safepoints. This is not an elapsed
-- time certificate or a bound on the bodies of runtime calls.
nativeSummary :: Bool -> String -> String -> IO ()
nativeSummary enabled what asm =
  when enabled $ do
    let label = "# native-insns-v1: "
        rows = [drop (length label) l | l <- lines asm,label `isPrefixOf` l]
        parse r = case words r of
          fn:kvs -> (fn,[(takeWhile (/= '=') kv,drop 1 (dropWhile (/= '=') kv)) | kv <- kvs])
          [] -> ("?",[])
        distance (_,kvs) = maybe (0::Int) (\v -> if v=="UNBOUNDED" then maxBound else read v) (lookup "segmax" kvs)
        parsed = map parse rows
        top = take 12 (sortBy (\a b -> compare (distance b) (distance a)) parsed)
    unless (null parsed) $ do
      hPutStrLn stderr ("[native-insns-v1] "++what++": "++show (length parsed)++" function(s), max segment "++show (maximum (map distance parsed))++" target instructions between safepoints")
      mapM_ (\(fn,kvs) -> hPutStrLn stderr ("[native-insns-v1]   "++fn++"  segmax="++maybe "?" id (lookup "segmax" kvs)++"  exittail="++maybe "?" id (lookup "exittail" kvs)++"  ccalls="++maybe "?" id (lookup "ccalls" kvs))) top

splitOn :: Char -> String -> [String]
splitOn c str = case break (== c) str of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOn c rest


-- Shared host modules resolve externally visible addresses through the GOT.
-- Local labels keep direct PC-relative addresses. x64 borrows main's static
-- TLS through the initial-exec model, never a module-local TLS block.
posixPic :: Bool -> Bool -> String -> String
posixPic a64 mach asm = unlines (go (lines asm))
  where
    locals = S.fromList [init l | l <- lines asm, not (null l), last l == ':']
    external n = not (S.member n locals)
    go [] = []
    go (l:rest)
      | a64, ["adrp", reg, sym] <- words l, external (takeWhile (/= '@') sym),
        next:tail' <- rest, "add " `isPrefixOf` dropWhile (== ' ') next =
          let r = filter (/= ',') reg; n = takeWhile (/= '@') sym
          in (if mach then ["    adrp " ++ r ++ ", " ++ n ++ "@GOTPAGE", "    ldr " ++ r ++ ", [" ++ r ++ ", " ++ n ++ "@GOTPAGEOFF]"]
                      else ["    adrp " ++ r ++ ", :got:" ++ n, "    ldr " ++ r ++ ", [" ++ r ++ ", :got_lo12:" ++ n ++ "]"]) ++ go tail'
      | not a64, ["leaq", src, dst] <- words l,
        let n = takeWhile (/= '(') src, "(%rip)," `List.isSuffixOf` src, external n =
          ("    movq " ++ n ++ "@GOTPCREL(%rip), " ++ dst) : go rest
      | not a64, "%fs:" `List.isInfixOf` l, "@tpoff" `List.isInfixOf` l =
          let ws = words l; args = takeWhile (/= "#") (drop 1 ws)
              n = takeWhile (/= '@') (drop 4 (head [w | w <- args, "%fs:" `isPrefixOf` w]))
              scratch = if "%r11" `List.isInfixOf` l then "%r10" else "%r11"
              old = "%fs:" ++ n ++ "@tpoff"
              replace [] = []
              replace xs | old `isPrefixOf` xs = "%fs:(" ++ scratch ++ ")" ++ replace (drop (length old) xs)
                         | otherwise = head xs : replace (tail xs)
          in ["    pushq " ++ scratch, "    movq " ++ n ++ "@GOTTPOFF(%rip), " ++ scratch, replace l, "    popq " ++ scratch] ++ go rest
      | not mach, dropWhile (== ' ') l == ".section .rodata" = ".section .data.rel.ro" : go rest
      | otherwise = l : go rest
