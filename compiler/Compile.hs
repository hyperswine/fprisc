module Compile (compileMain, checkedInterface, parseFile) where

import Data.List (sortBy)
import Data.Maybe (fromMaybe,isJust)
import System.IO (hClose, hPutStr, hPutStrLn, openTempFile, stderr)
import Arc (lowerArc, lowerRaw, arcExterns, arcRev)
import Mono (specializeFunctions, qualifyAux)
import Inline (inlineSmall, inlineWith, vecPeek)
import ReceiveTurns (receiveTurns)
import qualified Codegen.Target.RV as RV
import Codegen.Target.Common (Tune (..), dataSyntax)
import Codegen (Target, codegenRev, emitProgramWith, Emission (..), NativeMode (..), NativeBackend (..), Granularity (..), Strict (..), externals, tgtName, tgtFuel, tgtArc, tgtWeak, tgtHal, tgtFloatInline, tgtSimd, tgtFusion, tgtScalarFast, tgtIndexedMemory, tgtScalarWorkers, tgtFieldWorkers, tgtPipelineInline, tgtReuse, tgtTypedIr, tgtPolicy, tgtNative)
import Codegen.Policy (Policy (..), Profile (..), StackPolicy (..), policyWidth)
import Codegen.Target.X64 (x64InterfaceRev, x64SelectionRev)
import Codegen.Target.A64 (ObjectFormat (..), HartAccess (..), a64HostedInterfaceRev, a64InterfaceRev, a64SelectionRev)
import Data.Char (isAlphaNum, isAscii, ord)
import Numeric (showHex)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.State.Strict (runState)
import Data.List (intercalate, isPrefixOf)
import qualified Data.List as List
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Core.Syntax
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
import Ownership.Shape
import Core.Opt.Normalize (normArc)
import Type.Syntax (Scheme(..), Type(..))
import Infer.Result
import Frontend.Desugar.Checked (prepareChecked, lowerToUntyped)
import Infer (inferTopsChecked, aotProf, builtinEnv, builtinLinShapes, canonicalTypeWith, inferTops, inferTopsInterfaces)
import Safety (measureCheck, safetyCheck, trustedLibraryPaths)
import qualified Cost
import Manifest (Manifest (..), readManifest, renderNs)
import Struct (erasePSig, expandStructs, sigTable, specialize, structTable)
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

-- C-callable entry points for exported functions (RV64, the builtin
-- profile).  The fpr function keeps its own convention: every parameter
-- in a0..a7 by position, raw Word/Addr/float bits as 64-bit words,
-- Int TAGGED, Bool/Unit as the immortal objects.  The trampoline is the
-- difference between that and the C ABI, and nothing else -- no
-- allocation, no runtime.  Types come from the function's DECLARED
-- signature: an export is a contract, so it must be written down.
data CKind = KInt | KWord | KAddr | KBool | KUnit | KF64 | KF32 deriving (Eq, Show)

ckindOf :: Ty -> Either String CKind
ckindOf (TCon "Int" []) = Right KInt
ckindOf (TCon "Word" []) = Right KWord
ckindOf (TCon "Addr" []) = Right KAddr
ckindOf (TCon "Bool" []) = Right KBool
ckindOf (TCon "Unit" []) = Right KUnit
ckindOf (TCon "F64" []) = Right KF64
ckindOf (TCon "F32" []) = Right KF32
ckindOf t = Left ("not a C-representable type: " ++ show t ++ " (Int, Word, Addr, Bool, Unit, F64, F32 cross the boundary)")

trampoline :: Bool -> String -> String -> [CKind] -> CKind -> [String]
trampoline hard csym target params result =
  [ "",
    "# export " ++ csym ++ " -> " ++ target ++ " (" ++ unwords (map show params) ++ " -> " ++ show result ++ ")",
    "    .section .text." ++ csym ++ ",\"ax\",@progbits",
    "    .balign 4",
    "    .globl " ++ csym,
    csym ++ ":",
    "    addi sp, sp, -16",
    "    sd ra, 8(sp)"
  ]
    -- C puts integer arguments in a0.. and float arguments in fa0.. by
    -- their own counts; fpr wants position i in a_i.  Walk the positions
    -- from the highest down so an a_j (j <= i) is read before anything
    -- overwrites it.
    -- positions 8 and up: C passed them on ITS stack (16(sp) on, above this
    -- frame); fpr wants them in the hart's spill cells, cell j at 8*(1+j)(tp)
    -- (Codegen.hs spillRef).  Read, convert, store -- before the register
    -- moves below, which need t1 no more.
    ++ concat [ ("    ld t1, " ++ show (16 + 8 * (cSlot i - 8)) ++ "(sp)")
                  : conv "t1" k
                  ++ [ "    sd t1, " ++ show (8 * (1 + (i - 8))) ++ "(tp)" ]
              | (i, k) <- zip [0 :: Int ..] params, i >= 8 ]
    ++ concat [ arg i k | (i, k) <- reverse (zip [0 :: Int ..] params), i < 8 ]
    ++ [ "    call " ++ target ]
    ++ res result
    ++ [ "    ld ra, 8(sp)",
         "    addi sp, sp, 16",
         "    ret" ]
  where
    isF k = k == KF64 || k == KF32
    -- under the soft-float ABI every parameter is an integer-register
    -- parameter, so the C slot IS the position
    intSlot i = if hard then length [() | k <- take i params, not (isF k)] else i
    fltSlot i = length [() | k <- take i params, isF k]
    a i = "a" ++ show i
    cSlot i = intSlot i -- (a stacked float under lp64d is refused where exports are checked)
    conv r k = case k of
      KInt -> [ "    slli " ++ r ++ ", " ++ r ++ ", 1", "    ori " ++ r ++ ", " ++ r ++ ", 1" ]
      KBool -> [ "    beqz " ++ r ++ ", 1f", "    la " ++ r ++ ", fpr_true", "    j 2f",
                 "1:  la " ++ r ++ ", fpr_false", "2:" ]
      KUnit -> [ "    la " ++ r ++ ", fpr_unit" ]
      _ -> []
    -- the float ABI: this link is -mabi=lp64 (SOFT float), under which C
    -- passes a double as its bits in an integer register -- which is
    -- FP-RISC's own convention, so nothing moves.  --float-abi=hard
    -- (lp64d) would put them in fa0.. and need the fmv moves.
    arg i k
      | isF k && not hard = if intSlot i /= i then [ "    mv " ++ a i ++ ", " ++ a (intSlot i) ] else []
      | isF k = [ "    " ++ (if k == KF64 then "fmv.x.d " else "fmv.x.w ") ++ a i ++ ", fa" ++ show (fltSlot i) ]
      | otherwise =
          [ "    mv " ++ a i ++ ", " ++ a (intSlot i) | intSlot i /= i ]
            ++ conv (a i) k
    res k = case k of
      KInt -> [ "    srai a0, a0, 1" ]
      KBool -> [ "    lw a0, 4(a0)" ]
      KF64 | hard -> [ "    fmv.d.x fa0, a0" ]
      KF32 | hard -> [ "    fmv.w.x fa0, a0" ]
      _ -> []

-- the symbol encoding Codegen uses for fpr_fn_ names (kept in step)
mangleName :: String -> String
mangleName = concatMap enc
  where
    enc c
      | isAscii c && isAlphaNum c = [c]
      | otherwise = "_x" ++ pad (showHex (ord c) "")
    pad str = if length str < 2 then '0' : str else str

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
          -- A root may also add a contract to an existing prelude function.
          -- Every unit must see the resulting checked callable's signature,
          -- even if its implementation belongs to a different home unit.
          checkedSignatures = [t | t@(TSig n _ _) <- tops', "$precond" `isPrefixOf` n]
          sharedContext = [t | t@(TSig n _ _) <- tops, n `S.member` foreignContracts]
                            ++ sharedEntryTops ++ checkedSignatures
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
          terrs = inferenceErrors inferred
          notes = inferenceNotes inferred
          holes = inferenceHoles inferred
          linsigs = inferenceLinearity inferred
          topsRW = inferenceTops inferred
          interfaces = inferenceInterfaces inferred
      unless (null terrs) $ do
        putStrLn "=== TYPE ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored terrs)
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
            (serrs, ssug) = safetyCheck preludeNames tops notes
        unless (null serrs) $ do
          putStrLn "=== SAFETY: the safe/unsafe line ==="
          mapM_ (putStrLn . ("  * " ++)) (anchored serrs)
          when (Options.diagUnsafeSuggest diagnostic && not (null ssug)) $ do
            putStrLn "-- paste-ready signatures (inferred types):"
            mapM_ (putStrLn . ("SUGGEST " ++)) ssug
          exitFailure
      -- specialize generic calls; clones land in the merged program used
      -- for whole-program analyses. Per-unit codegen re-expands + rewrites
      -- its own tops (deterministic), so operator resolution is local.
      let (specErrs, topsSpec) = specialize sigs structs topsRW
      unless (null specErrs) $ do
        putStrLn "=== SIG/STRUCT: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored specErrs)
        exitFailure
      let finalTops = erasePSig topsSpec
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
          compileRaw uts = let (p, st) = runState (lowerToUntyped checkedLowering uts >>= liftFix) (DEnv 0 consAll shapes [] [])
                            in (M.map (fmap eraseCast) p, S.fromList (dJoins st))
          turnContext = fst (compileRaw finalTops)
          -- regions (the compiler-placed loop and call kinds) change no work
          -- and no allocation: the cost report sees the program without them
          -- the whole program's cost equations, once (lazy: only a build with
          -- call regions on computes them)
          contextEqs = Cost.costProgram (fst (measureCheck tops)) M.empty turnContext
          turnPassWith regions (p, joins) = if oBuiltin opts || oArc opts || (not (Options.cgReceiveTurns codegen)) then (p, [])
                       else receiveTurns (regions && (Options.cgLoopRegions codegen)) (regions && (Options.cgCallRegions codegen)) contextEqs (M.fromList interfaces) finalTops turnContext joins p
          turnPass = turnPassWith True
          compileUnit = fst . turnPass . compileRaw
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
          lerrs = lcheck li finalTops
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
        mapM_ (putStrLn . ("  * " ++)) (anchored lerrs)
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
      -- Each unit is expanded already (preludeE/units/root'). For codegen
      -- we also need operator sites resolved locally (Int prim / Str.+),
      -- which inferTops does; a unit typechecks standalone WITH the prelude
      -- in scope. Cross-unit monomorphization clones live in the ROOT
      -- (specialize ran on the whole program above); finalTops' root
      -- portion carries them.
      let resolveUnit uts =
            let (_, _, _, _, rw) = inferTops sigs structs (preludeE' ++ sharedContext ++ uts)
                bn = S.fromList ([fst3 b | b@(TBind {}) <- uts])
             in [t | t@(TBind n _ _ _) <- rw, S.member n bn]
                  ++ [t | t <- rw, not (isTBind t)]
          -- --cost: every boundary placed, by rule, and a count of the pure
          -- groups declined; FPR_RECEIVE_NOTES=1 lists the declined ones too
          -- (docs/2026-10-24-REGIONS-STAGE2.md)
          reportTurns uts = when ((Options.diagReceiveNotes diagnostic) || oCost opts) $ do
            let ns = snd (turnPass (compileRaw uts))
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
          preludeExt = arities (resolveUnit preludeE')
          unitExt = M.unions [arities (resolveUnit uts) | (_, uts) <- units']
          -- Checked entries can be owned by the root (including contracts
          -- added to prelude functions), but every unit needs their physical
          -- callable arity for direct calls/PAPs.
          checkedExt = arities [t | t@(TBind n _ _ _) <- finalTops, "$precond" `isPrefixOf` n]
          sourceExt = M.unions [checkedExt, preludeExt, unitExt]
          extFor = M.union (if oArc opts then arcExterns else M.empty) sourceExt -- own names win via prog-first lookup
          -- primitive arities for direct calls: the compiler's builtin
          -- schemes, and every bare signature (foreign declarations --
          -- a signature with a definition names a global, which the
          -- generator finds first)
          halAr =
            M.unions
              [ M.fromList [(n, length as) | TSig n (as, _) _ <- preludeE' ++ concatMap snd units' ++ root'],
                M.map (\(Forall _ _ t) -> arrows t) builtinEnv,
                -- the internal pair-free vector reads (Inline.vecPeek, vec.c)
                M.fromList [("$vec.at", 2), ("$vec.get", 2), ("$vec.len", 1), ("$receiveLoop", 2), ("$regionSeq", 1), ("$regionMark", 1), ("$regionRoom", 1), ("$regionCycle", 2), ("$loopLeave", 2), ("$callPend", 1), ("$callLeave", 2)] ]
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
              polStackCheck = if oBuiltin opts then StackStatic else if (Options.nativeShallowStack native) then StackCheckLegacyShallow else StackCheckEveryEntry,
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
            strictCheck what (emFallbacks emission)
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
          own prog = if oArc opts then do
                       lowered <- either (\e -> hPutStrLn stderr e >> exitFailure) (pure . inlineSmall 3 24) ((if oRaw opts then lowerRaw else lowerArc) sourceExt prog)
                       -- FPR_DUMP_CORE=name prints that function's Core as the generator sees it
                       let dump = Options.diagCore diagnostic
                       forM_ [(n, d) | Just want <- [dump], (n, d) <- M.toList lowered, takeWhile (/= '@') n == want] $ \(n, d) ->
                         hPutStrLn stderr ("core " ++ n ++ ": " ++ show d ++ "\nnormalized: " ++ show (fmap normArc d))
                       pure lowered
                     -- base: inline small non-recursive functions at their
                     -- saturated sites within the unit (Inline.hs), with
                     -- function-valued arguments substituted
                     else do
                       let inl = (if oNoInline opts then id else inlineWith pureOutside 3 24) (if (not (Options.cgVecPeek codegen)) then prog else vecPeek prog)
                       let dump = Options.diagCore diagnostic
                       forM_ [(n, d) | Just want <- [dump], (n, d) <- M.toList inl, takeWhile (/= '@') n == want] $ \(n, d) ->
                         hPutStrLn stderr ("core " ++ n ++ ": " ++ show d)
                       pure inl
          pureOutside g = maybe False (> 0) (M.lookup g extFor) || maybe False (> 0) (M.lookup g halAr) || g `elem` corePrimNames
          corePrimNames = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">=", "strcat", "str", "String.len"]
          mono ns ext p = if (not (Options.cgSpecialize codegen)) || oArc opts then p else specializeFunctions ns halAr ext p
          preludeResolved = resolveUnit preludeE'
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
          -- a constructor is global everywhere: a clone that references one
          -- links against the owner's symbol, so qualifyAux leaves the name
          importedCore = M.unions
            (qualifyAux ("$specaux.p" ++ take 12 preludeHash ++ ".") (bindNames preludeE' `S.union` allCons) (compileUnit preludeResolved)
             : [qualifyAux ("$specaux.u" ++ take 12 h ++ ".") (bindNames uts `S.union` allCons) (compileUnit (resolveUnit uts)) | (h,uts) <- units'])
          applyReport label asm = when (Options.diagApply diagnostic) $ hPutStrLn stderr
            ("apply " ++ label ++ ": dispatch=" ++ show (length [() | l <- lines asm, "fpr_apply" `List.isInfixOf` l, any (`List.isInfixOf` l) ["call ", "bl "]])
             ++ " known-partial=" ++ show (length [() | l <- lines asm, "# pap-create:" `List.isPrefixOf` l])
             ++ " static-descriptors=" ++ show (length [() | l <- lines asm, "# static-pap:" `List.isPrefixOf` l]))
          emitUnit path exps elide ext uts = do
            reportTurns uts
            checkBuiltinWidth (compileUnit uts)
            cached <- doesFileExist path
            if cached
              then do
                when (Options.diagApply diagnostic) (readFile path >>= applyReport (takeFileName path))
                pure (path, "cached")
              else do
                prog <- own (mono (takeFileName path) M.empty (compileUnit uts))
                -- FORCE before the write: an `error` raised while the
                -- assembly is lazily produced must propagate, never
                -- leave an empty file the cache then serves as a valid
                -- compiled unit (the bbspi arity>8 incident)
                let emission = emitProgramWith tgt rvv spec [] (M.union (if oArc opts then arcExterns else M.empty) ext) exps elide prog
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
      createDirectoryIfMissing True unitDir
      -- prelude unit (unqualified names; the always-linked stdlib unit).
      -- The prelude is self-contained, so resolve its own operators.
      preludeOut <-
        if oArc opts || null preludeTops
          then pure []
          else do
            r <- emitUnit (unitDir </> ("prelude-" ++ take 12 preludeHash ++ "-" ++ tag ++ ".s"))
                          (bindNames preludeE' `S.union` preludeCons) preludeElided checkedExt preludeResolved
            pure [r]
      -- dep module units (hash-qualified; filename carries the prelude
      -- hash too -- unit code depends on prelude arities -- AND a hash of
      -- the whole program's record SHAPES: a unit's row-typed projections
      -- (`st.uart`) compile to a tag chain over the shapes this program
      -- declares, so a unit compiled under one program is wrong for
      -- another with a different shape set (the uartroute/timerroute
      -- incident: a cached svc unit from a program without the field)
      let shapesHash = hashAST [TShape (concat fs) [] | fs <- M.keys shapes]
      unitOuts <- forM (if oArc opts then [] else units') $ \(h, uts) ->
        emitUnit (unitDir </> ("u-" ++ take 12 h ++ "-p" ++ take 8 preludeHash ++ "-s" ++ take 8 shapesHash ++ "-" ++ tag ++ ".s"))
                 (bindNames uts `S.union` unitConsOf h) (unitElided h) extFor (resolveUnit uts)
      -- the root: exports its own binds; modtab (all dep exports) lives
      -- here. Root codegen uses the FULLY specialized+resolved tops
      -- (finalTops), filtered to root's own names + any monomorphized
      -- clones (clones have no home unit; they ride with the root).
      let rootNames = S.fromList ([fst3 b | b@(TBind {}) <- root'])
          rootLoweredNames = bindNames root''
          unitNames = S.fromList (concat [[fst3 b | b@(TBind {}) <- uts] | (_, uts) <- units'])
          preludeNames = bindNames preludeE'
          rootProgTops =
            [ t | t@(TBind n _ _ _) <- finalTops,
                  S.member n rootLoweredNames
                    || (not (S.member n unitNames) && not (S.member n preludeNames))
            ]
          -- The raw ARC ABI needs one representation solution across imports.
          -- Until signatures/layouts are serialized, do not reuse ARC unit code.
          rootProgRaw = compileUnit (if oArc opts then finalTops else rootProgTops)
          rootExports =
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
      reportTurns (if oArc opts then finalTops else rootProgTops)
      rootProgSym <- case symbolize rootProgRaw of
        Left e -> hPutStrLn stderr ("error: " ++ e) >> exitFailure
        Right p -> pure p
      -- Imported private lifts are renamed into the root before cloning.
      importedSym <- if (not (Options.cgSpecialize codegen)) || oArc opts then pure M.empty else case symbolize importedCore of
        Left e -> hPutStrLn stderr ("error: " ++ e) >> exitFailure
        Right p -> pure p
      rootProg <- own (mono ("root" ++ take 12 rootHash) importedSym rootProgSym)
      let rootEmission = emitProgramWith tgt rvv spec imageExports extFor
                                     (if oArc opts then M.keysSet rootProg else bindNames root'' `S.union` rootCons)
                                     (if oArc opts then S.empty else rootElided) rootProg
          rootVNotes = emNotes rootEmission
      -- the C-callable entries: each export needs a declared signature
      -- over C-representable types, a function of that arity, <= 8 params
      let baseName = takeWhile (/= '@')
          sigsByBase = M.fromListWith (++) [ (baseName q, [(q, as, r)]) | TSig q (as, r) _ <- tops0RL ]
      tramps <- forM (oExports opts) $ \(n, csym) -> do
        let bad m = hPutStrLn stderr ("export " ++ n ++ ": " ++ m) >> exitFailure
        (q, as, r) <- case M.lookup n sigsByBase of
          Just [one] -> pure one
          Just _ -> bad "ambiguous: more than one signature by that name"
          Nothing -> bad "no declared signature (an export is a contract: write `name : A -> B .`)"
        ps <- case M.lookup q rootProg of
          Just (ps, _) -> pure ps
          Nothing -> bad "no such function in this unit"
        when (length ps /= length as) $ bad ("signature has " ++ show (length as) ++ " parameters, the function " ++ show (length ps))
        -- 8 in registers, the rest from C's stack into the hart's spill
        -- cells: the native convention's 64.  Past that a function takes
        -- a spilled tuple, which C cannot build: pass a Layout pointer.
        when (length ps > 64) $ bad "more than 64 parameters: pass a pointer to a Layout instead (docs/2026-09-19-LAYOUTS.md)"
        when (oHardFloat opts && length ps > 8) $ bad "more than 8 parameters under --float-abi=hard: stacked float arguments are not lowered yet"
        ks <- either bad pure (traverse ckindOf as)
        rk <- either bad pure (ckindOf r)
        putStrLn ("export " ++ csym ++ " : " ++ unwords (map show ks) ++ " -> " ++ show rk ++ "  (" ++ q ++ ")")
        pure (trampoline (oHardFloat opts) csym ("fpr_fn_" ++ mangleName (checkedTarget q)) ks rk)
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

isTBind :: STop -> Bool
isTBind TBind {} = True
isTBind _ = False

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

-- A Layout's two casts (FPRISC.expandLayout) are `$cast x`: typed a -> b so
-- a nominal pointer type can stand for an Addr, and the identity in fact.
-- Erased here, so no backend, no representation pass and no ARC lowering
-- ever meets it: `Block.at a` IS `a`.
eraseCast :: Core -> Core
eraseCast = go
  where
    go c = case c of
      CApp (CVar "$cast") x -> go x
      CApp f x -> CApp (go f) (go x)
      CLam ps b -> CLam ps (go b)
      CLet n e b -> CLet n (go e) (go b)
      CIf a b d -> CIf (go a) (go b) (go d)
      CMk t k es -> CMk t k (map go es)
      CTagEq t k e -> CTagEq t k (go e)
      CProj i e -> CProj i (go e)
      _ -> c

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
