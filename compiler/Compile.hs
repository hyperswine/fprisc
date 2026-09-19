module Compile (compileMain, parseFile) where

import Data.List (sortBy)
import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Arc (lowerArc, lowerRaw, arcExterns, arcRev)
import Inline (inlineSmall)
import Codegen (Target, codegenRev, emitProgram, externals, rv32, rv64, tgtName, tgtFuel, tgtArc, tgtWeak, normArc)
import Data.Char (isAlphaNum, ord)
import Numeric (showHex)
import A64 (deTlsQosAppA64, lowerA64, a64Rev)
import X64 (lowerX64, deTlsQosApp, x64Rev)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.State.Strict (runState)
import Data.List (isPrefixOf)
import qualified Data.List as List
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC
import Infer (builtinLinShapes, inferTops)
import Safety (safetyCheck)
import System.Environment (lookupEnv)
import Struct (erasePSig, expandStructs, sigTable, specialize, structTable)
import Modules (LoadResult (..), ModExport (..), hashAST, loadProgram)
import Precond (PreNote (..), PreStatus (..), applyPreconds, preTable, renderNote, validatePre)
import Home (underHome)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getArgs)
import qualified System.Info
import StdBridge (runStdCheck)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Text.Megaparsec (errorBundlePretty, parse)

data Opts = Opts
  { oTarget :: Target,
    oBuiltin :: Bool,
    oBase :: Bool, -- the posix SYSTEM: a hosted executable on this machine (hal/posix); the ISA is the build host's
    oSystem :: Maybe String, -- --system=bare-metal|qos-native|qos-portable|posix (docs/PROFILES.md)
    oProfileFlag :: Maybe String, -- --profile=builtin|base|extbase|sol, when the file does not say
    oArc :: Bool,
    oRaw :: Bool, -- a RAW unit: allocation-free, no ownership instrumentation (Arc.lowerRaw)
    oLib :: Bool, -- a LIBRARY unit: the file is compiled as an imported module (names qualified), no main, weak shared stubs
    oExports :: [(String, String)], -- C-callable trampolines: (fpr function, C symbol)
    oHardFloat :: Bool, -- exports follow the lp64d ABI (floats in fa0..); default lp64, soft
    oA64 :: Bool, -- lower the rv64 emission (the shared RISC IR) to AArch64
    oA64Mac :: Bool, -- AArch64 with Mach-O syntax (macOS): _sym, @PAGE, TLV
    oX64 :: Bool, -- lower it to x86-64 (SysV) instead
    oQosApp :: Bool, -- qx64: QOS-x86_64 app image (plain-global cells, no TLS)
    oQosSingle :: Bool, -- qa64single: global hart cell for hosts without TP-relative TLS
    oPlugin :: Bool, -- emit root binds in fpr_modtab for a loadable plugin
    oRvv :: Bool,
    oStdCheck :: Bool, -- run the std proof pass (StdBridge + StdCheck) and stop
    oSol :: Bool, -- the HostedBytecode/sol VIEW of the one grammar: `>` top-level eval accepted (auto-on for .sol input)
    oPrelude :: Maybe FilePath,
    oNoSafety :: Bool,
    oFiles :: [FilePath]
  }

parseArgs :: [String] -> Opts
parseArgs = foldl step (Opts rv64 False False Nothing Nothing False False False [] False False False False False False False False False False Nothing False [])
  where
    -- profile aliases (Target.hs): the AOT profiles resolved to their
    -- default ISA for this build.  bare-metal -> rv64 (QEMU virt);
    -- qos-native -> rv64 .qa is built by tools, so the alias maps the
    -- codegen the same way; qos-portable -> qx64 (x86-64 build host).
    -- hosted-bytecode is NOT an fprc target: that profile is the sol
    -- executable (fp-risc/sol).
    -- the SYSTEM: where the program runs (docs/PROFILES.md).  bare-metal
    -- and qos-native are rv64 (QEMU virt, the board); qos-portable is
    -- an x86-64 QOS app image; posix is an executable for the host this
    -- compiler was built on -- the rv64 emission is the IR, the
    -- lowering is the host's ISA.
    step o "--system=bare-metal" = o {oTarget = rv64, oSystem = Just "bare-metal"}
    step o "--system=qos-native" = o {oTarget = rv64, oSystem = Just "qos-native"}
    step o "--system=qos-portable" = o {oTarget = rv64, oX64 = True, oQosApp = True, oSystem = Just "qos-portable"}
    step o "--system=posix" = case (System.Info.os, System.Info.arch) of
      ("darwin", "aarch64") -> o {oTarget = rv64, oBase = True, oA64 = True, oA64Mac = True, oSystem = Just "posix"}
      (_, "aarch64") -> o {oTarget = rv64, oBase = True, oA64 = True, oSystem = Just "posix"}
      (_, "x86_64") -> o {oTarget = rv64, oBase = True, oX64 = True, oSystem = Just "posix"}
      (os', arch') -> error ("--system=posix: no hosted lowering for " ++ os' ++ "/" ++ arch' ++ " (x86_64 and aarch64 are supported)")
    -- the PROFILE: what the program is written against.  The file says
    -- it (`profile base.`); the flag is for files that do not.
    step o "--profile=builtin" = o {oProfileFlag = Just "builtin"}
    step o "--profile=base" = o {oProfileFlag = Just "base"}
    step o "--profile=extbase" = o {oProfileFlag = Just "extbase"}
    step o "--profile=sol" = o {oProfileFlag = Just "sol"}
    -- the 1.x spellings, kept: a system and (for builtin) a profile at once
    step o "--profile=bare-metal-builtin" = (step o "--system=bare-metal") {oProfileFlag = Just "builtin"}
    step o "--profile=bare-metal" = step o "--system=bare-metal"
    step o "--profile=qos-native" = step o "--system=qos-native"
    step o "--profile=qos-portable" = step o "--system=qos-portable"
    step o "--arc" = o {oArc = True}
    step o "--lib" = o {oLib = True}
    step o "--raw" = o {oRaw = True}
    step o "--float-abi=hard" = o {oHardFloat = True}
    step o "--float-abi=soft" = o {oHardFloat = False}
    step o "--stdcheck" = o {oStdCheck = True}
    step o "--sol" = o {oSol = True}
    step o "--target=rv32" = o {oTarget = rv32}
    step o "--target=rv64" = o {oTarget = rv64}
    step o "--target=a64" = o {oTarget = rv64, oA64 = True} -- rv64 emission is the IR
    step o "--target=a64mac" = o {oTarget = rv64, oA64 = True, oA64Mac = True} -- same lowering, Mach-O syntax
    step o "--target=x64" = o {oTarget = rv64, oX64 = True} -- likewise
    step o "--target=qx64" = o {oTarget = rv64, oX64 = True, oQosApp = True} -- QOS-x86_64
    step o "--target=qa64" = o {oTarget = rv64, oA64 = True, oQosApp = True} -- QOS-aarch64
    step o "--target=qa64single" = o {oTarget = rv64, oA64 = True, oQosApp = True, oQosSingle = True} -- QOS-aarch64, global hart cell
    step o "--target=qa64mac" = o {oTarget = rv64, oA64 = True, oA64Mac = True, oQosApp = True} -- QOS app, Apple Silicon
    step o "--plugin" = o {oPlugin = True}
    step o "--rvv" = o {oRvv = True}
    step o a
      | "--prelude=" `isPrefixOf` a = o {oPrelude = Just (drop (length "--prelude=") a)}
      | "--export=" `isPrefixOf` a = o {oExports = oExports o ++ exportSpecs (drop (length "--export=") a)}
      | a == "--no-safety" = o {oNoSafety = True}
      | otherwise = o {oFiles = oFiles o ++ [a]}

-- `--export=name,name:c_symbol,...`: an fpr function and the C symbol it
-- is callable as (default: the same name)
exportSpecs :: String -> [(String, String)]
exportSpecs = map one . filter (not . null) . splitOn ','
  where
    one spec = case break (== ':') spec of
      (n, ':' : c) -> (n, c)
      (n, _) -> (n, n)
    splitOn c str = case break (== c) str of
      (a, _ : rest) -> a : splitOn c rest
      (a, []) -> [a]

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
    ++ concat [ arg i k | (i, k) <- reverse (zip [0 :: Int ..] params) ]
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
    -- the float ABI: this link is -mabi=lp64 (SOFT float), under which C
    -- passes a double as its bits in an integer register -- which is
    -- FP-RISC's own convention, so nothing moves.  --float-abi=hard
    -- (lp64d) would put them in fa0.. and need the fmv moves.
    arg i k
      | isF k && not hard = if intSlot i /= i then [ "    mv " ++ a i ++ ", " ++ a (intSlot i) ] else []
      | isF k = [ "    " ++ (if k == KF64 then "fmv.x.d " else "fmv.x.w ") ++ a i ++ ", fa" ++ show (fltSlot i) ]
      | otherwise =
          [ "    mv " ++ a i ++ ", " ++ a (intSlot i) | intSlot i /= i ]
            ++ case k of
              KInt -> [ "    slli " ++ a i ++ ", " ++ a i ++ ", 1", "    ori " ++ a i ++ ", " ++ a i ++ ", 1" ]
              KBool -> [ "    beqz " ++ a i ++ ", 1f", "    la " ++ a i ++ ", fpr_true", "    j 2f",
                         "1:  la " ++ a i ++ ", fpr_false", "2:" ]
              KUnit -> [ "    la " ++ a i ++ ", fpr_unit" ]
              _ -> []
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
      | isAlphaNum c = [c]
      | otherwise = "_x" ++ pad (showHex (ord c) "")
    pad str = if length str < 2 then '0' : str else str

parseFile :: FilePath -> IO [STop]
parseFile p = snd <$> parseFileSrc p

-- keep the source: bindAnchors scans it for the file:line of every
-- top-level definition (spans step 1)
parseFileSrc :: FilePath -> IO (String, [STop])
parseFileSrc p = do
  src <- readFile p
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
compileMain = do
  setLocaleEncoding utf8
  opts0 <- parseArgs <$> getArgs
  -- --stdcheck: parse the single file and run the std proof pass
  -- (StdBridge lowers the checkable fragment into StdCheck's interval /
  -- measure / WCET engine); no code is generated.
  when (oStdCheck opts0) $ do
    inp <- case oFiles opts0 of
      [i] -> pure i
      _ -> putStrLn "usage: fprc --stdcheck <in.fpr>" >> exitFailure >> pure ""
    tops <- parseFile inp
    runStdCheck tops
    exitSuccess
  (inp, out) <- case oFiles opts0 of
    [i, o] -> pure (i, o)
    _ -> putStrLn "usage: fprc [--system=posix|bare-metal|qos-native|qos-portable] [--profile=builtin|base|extbase|sol] [--arc] [--target=rv32|rv64|a64|a64mac|x64|qx64|qa64|qa64single|qa64mac] [--plugin] [--rvv] [--stdcheck] [--prelude=FILE] <in.fpr> <out.s>" >> exitFailure >> pure ("", "")
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
  let system = fromMaybe "bare-metal" (oSystem opts0)
      opts = opts0 {oBuiltin = profile == "builtin", oSol = oSol opts0 || profile == "sol"}
  -- the matrix (docs/PROFILES.md): builtin is bare metal only, sol is
  -- the posix host only, base and extbase run anywhere with a HAL
  when (profile == "builtin" && system /= "bare-metal") $
    refuse ("profile builtin runs on the bare-metal system only, not " ++ system ++ " (--system=bare-metal)")
  when (profile == "sol" && system /= "posix") $
    refuse ("profile sol runs on the posix system (the VM: `fpr run`), not " ++ system)
  when (oBuiltin opts && (oA64 opts || oX64 opts || oQosApp opts || oRvv opts || tgtName (oTarget opts) /= "rv64")) $ do
    hPutStrLn stderr "profile builtin currently supports scalar RV64 only"
    exitFailure
  when (oBase opts && (oBuiltin opts || oQosApp opts || oPlugin opts || oRvv opts)) $ do
    hPutStrLn stderr "--system=posix is a plain hosted executable: no builtin/arc, no QOS app image, no plugin, no RVV"
    exitFailure
  when (oArc opts && not (oBuiltin opts)) $ do
    hPutStrLn stderr "--arc needs profile builtin (the raw ABI)"
    exitFailure
  when (oRaw opts && not (oArc opts)) $ do
    hPutStrLn stderr "--raw needs --arc (it is the raw ABI without the ownership instrumentation)"
    exitFailure
  when ((oLib opts || not (null (oExports opts))) && not (oArc opts && oBuiltin opts)) $ do
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
  (preludeSrc, preludeTops) <- maybe (pure ("", [])) parseFileSrc prelude
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
  lr <- loadProgram preludeTops inp rootTops
  case lr of
    Left e -> putStrLn e >> exitFailure
    Right (LoadResult tops0RL exports notes units0L root0L rootHash unitAnchors unitSources) -> do
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
          (pathErrsM, tops0R) = expandPathLits ptbl tops0RL
          (pathErrsR, root0) = expandPathLits ptbl root0L
          unitsPR = [(h, expandPathLits ptbl uts) | (h, uts) <- units0L]
          units0 = [(h, ts) | (h, (_, ts)) <- unitsPR]
          pathErrs = List.nub (pathErrsM ++ pathErrsR ++ concat [es | (_, (es, _)) <- unitsPR])
      unless (null pathErrs) $ do
        putStrLn "=== PATH LITERALS: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored pathErrs)
        exitFailure
      -- autodrop: mechanical discharge of the drop-what-you-receive law
      -- (conservative destructure-then-dead shape; see FPRISC.autoDrop)
      let (tops0S, asNotes) = aritySpill tops0R
      mapM_ putStrLn asNotes
      let (tops0, adNotes) = autoDrop tops0S
      mapM_ putStrLn adNotes
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
          -- autodrop must reach the ASTs codegen actually consumes:
          -- root codegen reads finalTops (derived from tops0, already
          -- dropped above), but UNIT codegen reads units0 -- without
          -- this, the pass reports insertions the emitted units never
          -- contain (the mvutick +1 arcLive/frame leak).  root0 is
          -- transformed too so root' -- used for cons/tid tables --
          -- matches what the root emits.  Notes are dropped here:
          -- the merged pass above already printed the same lines.
          root' = expandU (fst (autoDrop (fst (aritySpill root0))))
          units = [(h, expandU (fst (autoDrop (fst (aritySpill uts))))) | (h, uts) <- units0]
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
          preFragErrs = validatePre preTab
      unless (null preFragErrs) $ do
        putStrLn "=== PRECONDITION: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored preFragErrs)
        exitFailure
      let (pnAll, tops') = applyPreconds preTab tops
          preludeE' = snd (applyPreconds preTab preludeE)
          root'' = snd (applyPreconds preTab root')
          units' = [(h, snd (applyPreconds preTab uts)) | (h, uts) <- units]
          rootBinds = S.fromList [fst3 b | b@TBind {} <- root']
          pnRoot = [n | n <- pnAll, S.member (pnCaller n) rootBinds]
          nDis = length [() | n <- pnAll, pnStatus n == Discharged]
          nRt = length [() | n <- pnAll, pnStatus n == RuntimeCheck]
          nTrap = length [() | n <- pnAll, pnStatus n == BuiltinTrap]
      -- per-obligation notes are telemetry, not signal: 100+ lines per
      -- compile buried the errors.  FPR_PRECOND_NOTES=1 restores them;
      -- the one-line summary below always prints.
      verbosePre <- (== Just "1") <$> lookupEnv "FPR_PRECOND_NOTES"
      when verbosePre $ mapM_ (putStrLn . renderNote) pnRoot
      unless (null pnAll) $
        putStrLn ("precond: " ++ show (length pnAll) ++ " obligations: "
                  ++ show nDis ++ " discharged, " ++ show nRt
                  ++ " runtime-checked, " ++ show nTrap ++ " builtin traps")
      -- typecheck the merged expanded program; rewritten tops carry
      -- operator sites resolved to prims / Str.+ / s.(+)
      let (terrs, notes, holes, linsigs, topsRW) = inferTops sigs structs tops'
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
      unless (null [() | (n, _) <- holes, null n]) $
        mapM_ (\(_, t) -> putStrLn ("note: ?? hole (runtime trap) : " ++ t)) [h | h@(n, _) <- holes, null n]
      -- the safe/unsafe line (Safety.hs): recursion and unsafe-taint
      -- must be DECLARED.  --no-safety exists for transition only.
      unless (oNoSafety opts || oBuiltin opts) $ do
        let preludeNames = S.fromList [n | TBind n _ _ _ <- preludeTops]
            (serrs, ssug) = safetyCheck preludeNames tops' notes
        unless (null serrs) $ do
          putStrLn "=== SAFETY: the safe/unsafe line ==="
          mapM_ (putStrLn . ("  * " ++)) (anchored serrs)
          sug <- lookupEnv "FPR_UNSAFE_SUGGEST"
          when (sug == Just "1" && not (null ssug)) $ do
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
          consAll =
            M.unions
              ( collectCons preludeHash preludeE
                  : collectCons rootHash root'
                  : [collectCons h uts | (h, uts) <- units]
              )
          shapes = collectShapes finalTops -- structural fnv ids: globally consistent
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
      -- ---- per-unit CODEGEN (separate compilation) ----
      -- Each unit is expanded already (preludeE/units/root'). For codegen
      -- we also need operator sites resolved locally (Int prim / Str.+),
      -- which inferTops does; a unit typechecks standalone WITH the prelude
      -- in scope. Cross-unit monomorphization clones live in the ROOT
      -- (specialize ran on the whole program above); finalTops' root
      -- portion carries them.
      let resolveUnit uts =
            let (_, _, _, _, rw) = inferTops sigs structs (preludeE' ++ uts)
                bn = S.fromList ([fst3 b | b@(TBind {}) <- uts])
             in [t | t@(TBind n _ _ _) <- rw, S.member n bn]
                  ++ [t | t <- rw, not (isTBind t)]
          compileUnit uts = M.map (fmap eraseCast) (fst (runState (compileTop uts >>= liftFix) (DEnv 0 consAll shapes [])))
          preludeExt = arities preludeE'
          unitExt = M.unions [arities uts | (_, uts) <- units']
          sourceExt = M.union preludeExt unitExt
          extFor = M.union (if oArc opts then arcExterns else M.empty) sourceExt -- own names win via prog-first lookup
          tgt = (oTarget opts) {tgtFuel = not (oBuiltin opts), tgtArc = oArc opts, tgtWeak = oLib opts}
          a64 = oA64 opts
          a64mac = oA64Mac opts
          x64 = oX64 opts
          qapp = oQosApp opts
          qsingle = oQosSingle opts
          lower | a64 && qapp = deTlsQosAppA64 a64mac qsingle . lowerA64 a64mac
                | a64 = lowerA64 a64mac
                | x64 && qapp = deTlsQosApp . lowerX64
                | x64 = lowerX64
                | otherwise = id
          rvv = oRvv opts && not a64 && not x64 -- no RVV lowering in the PoCs
          spec = not x64 -- SysV callee-saved registers can't host the s6+ spec loops
          tname = if qsingle then "qa64singler" ++ show a64Rev
                  else if a64mac then "a64macr" ++ show a64Rev
                  else if a64 && qapp then "qa64r" ++ show a64Rev
                  else if a64 then "a64r" ++ show a64Rev
                  else if x64 && qapp then "qx64r" ++ show x64Rev
                  else if x64 then "x64r" ++ show x64Rev
                  else tgtName tgt
          tag = "g" ++ show codegenRev ++ "pc1-" ++ tname ++ (if rvv then "-rvv" else "") ++ (if oBuiltin opts then "-builtin" else "") ++ (if oArc opts then "-arc" ++ show arcRev else "")
          unitDir = takeDirectory out </> "units"
          -- --arc: lower ownership, then inline the small helpers at
          -- their sites (Inline.hs) before the generator sees the unit
          own prog = if oArc opts then do
                       lowered <- either (\e -> hPutStrLn stderr e >> exitFailure) (pure . inlineSmall 3 24) ((if oRaw opts then lowerRaw else lowerArc) sourceExt prog)
                       -- FPR_DUMP_CORE=name prints that function's Core as the generator sees it
                       dump <- lookupEnv "FPR_DUMP_CORE"
                       forM_ [(n, d) | Just want <- [dump], (n, d) <- M.toList lowered, takeWhile (/= '@') n == want] $ \(n, d) ->
                         hPutStrLn stderr ("core " ++ n ++ ": " ++ show d ++ "\nnormalized: " ++ show (fmap normArc d))
                       pure lowered
                     else pure prog
          emitUnit path exps ext uts = do
            cached <- doesFileExist path
            if cached
              then pure (path, "cached")
              else do
                prog <- own (compileUnit uts)
                -- FORCE before the write: an `error` raised while the
                -- assembly is lazily produced must propagate, never
                -- leave an empty file the cache then serves as a valid
                -- compiled unit (the bbspi arity>8 incident)
                let (asm0, vnotes) = emitProgram tgt rvv spec [] (M.union (if oArc opts then arcExterns else M.empty) ext) exps prog
                    asm = lower asm0
                mapM_ putStrLn vnotes
                length asm `seq` writeFile path asm
                wcetSummary ("unit " ++ takeFileName path) asm
                pure (path, show (M.size prog) ++ " supercombinators")
      createDirectoryIfMissing True unitDir
      -- prelude unit (unqualified names; the always-linked stdlib unit).
      -- The prelude is self-contained, so resolve its own operators.
      let preludeResolved = let (_, _, _, _, rw) = inferTops sigs structs preludeE' in rw
      preludeOut <-
        if oArc opts || null preludeTops
          then pure []
          else do
            r <- emitUnit (unitDir </> ("prelude-" ++ take 12 preludeHash ++ "-" ++ tag ++ ".s"))
                          (bindNames preludeE') M.empty preludeResolved
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
                 (bindNames uts) extFor (resolveUnit uts)
      -- the root: exports its own binds; modtab (all dep exports) lives
      -- here. Root codegen uses the FULLY specialized+resolved tops
      -- (finalTops), filtered to root's own names + any monomorphized
      -- clones (clones have no home unit; they ride with the root).
      let rootNames = S.fromList ([fst3 b | b@(TBind {}) <- root'])
          unitNames = S.fromList (concat [[fst3 b | b@(TBind {}) <- uts] | (_, uts) <- units])
          preludeNames = S.fromList (map fst3 [b | b@(TBind {}) <- preludeE, True])
          rootProgTops =
            [ t | t@(TBind n _ _ _) <- finalTops,
                  S.member n rootNames
                    || (not (S.member n unitNames) && not (S.member n preludeNames))
            ]
          -- The raw ARC ABI needs one representation solution across imports.
          -- Until signatures/layouts are serialized, do not reuse ARC unit code.
          rootProgRaw = compileUnit (if oArc opts then finalTops else rootProgTops)
          rootExports =
            [ ModExport rootHash n n (length ps)
              | oPlugin opts,
                TBind n ps _ _ <- root'
            ]
          imageExports = exports ++ rootExports
      when (oBuiltin opts && not (oArc opts) && M.member "machineInterrupt" rootProgRaw) $ do
        hPutStrLn stderr "machineInterrupt requires --arc (raw, allocation-free handler ABI)"
        exitFailure
      rootProgSym <- case symbolize rootProgRaw of
        Left e -> hPutStrLn stderr ("error: " ++ e) >> exitFailure
        Right p -> pure p
      rootProg <- own rootProgSym
      let (rootAsm0, rootVNotes) = emitProgram tgt rvv spec imageExports extFor (if oArc opts then M.keysSet rootProg else bindNames root') rootProg
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
        when (length ps > 8) $ bad "more than 8 parameters: the C entry is register-only"
        ks <- either bad pure (traverse ckindOf as)
        rk <- either bad pure (ckindOf r)
        putStrLn ("export " ++ csym ++ " : " ++ unwords (map show ks) ++ " -> " ++ show rk ++ "  (" ++ q ++ ")")
        pure (trampoline (oHardFloat opts) csym ("fpr_fn_" ++ mangleName q) ks rk)
      let rootAsm = lower rootAsm0 ++ unlines (concat tramps)
      mapM_ putStrLn rootVNotes
      writeFile out rootAsm
      wcetSummary "root" rootAsm
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

-- G1 (docs/FUEL-RC-ABI.md): with FPRC_WCET=1, print the per-emission
-- safepoint-distance table. The program bound is the max over ALL
-- emissions linked together (root + units), plus the C-entry bounds
-- (G2) for each counted ccall.
wcetSummary :: String -> String -> IO ()
wcetSummary what asm = do
  w <- lookupEnv "FPRC_WCET"
  case w of
    Just "1" -> do
      let rows = [drop 8 l | l <- lines asm, take 8 l == "# wcet: "]
          parse r = case words r of
            (fn : kvs) -> (fn, [(takeWhile (/= '=') kv, drop 1 (dropWhile (/= '=') kv)) | kv <- kvs])
            _ -> ("?", [])
          segOf (_, kvs) = maybe (0 :: Int) (\v -> if v == "UNBOUNDED" then maxBound else read v) (lookup "segmax" kvs)
          parsed = map parse rows
          top = take 12 (sortBy (\a b -> compare (segOf b) (segOf a)) parsed)
      hPutStrLn stderr ("[wcet] " ++ what ++ ": " ++ show (length parsed) ++ " function(s), max segment " ++ (case parsed of [] -> "0"; _ -> show (maximum (map segOf parsed))) ++ " IR insns between safepoints")
      mapM_ (\(fn, kvs) -> hPutStrLn stderr ("[wcet]   " ++ fn ++ "  segmax=" ++ maybe "?" id (lookup "segmax" kvs) ++ "  ccalls=" ++ maybe "?" id (lookup "ccalls" kvs))) top
    _ -> pure ()


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
