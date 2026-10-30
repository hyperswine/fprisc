-- Build.hs -- `fpr build` and `fpr run`: the Base profile as one command.
--
--   fpr build prog.fpr [-o out] [--harts N] [--cc CC] [-v] [--keep]
--   fpr run   prog.fpr [args...]
--   fpr build prog.fpr --host=esp-idf [-o dir]        an ESP32-P4 image
--   fpr run   prog.fpr --host=esp-idf [--port P]      flash it and be its console
--
-- Both are the posix system.  On its unix host (the default) a program
-- becomes an ordinary executable for THIS machine: the compiler lowers it
-- for the host ISA, and the C compiler links the generated assembly with
-- the shared core runtime (runtime) and the hosted HAL (machine/posix),
-- both found beside the fpr binary (Home.hs).  No Makefile, no QOS: the
-- same three parts a bare-metal image is made of, with libc as the board.
-- On the esp-idf host the same parts are built as an ESP-IDF project by
-- machine/esp-idf/build.sh (docs/2026-09-23-ESP-IDF.md).
module Build (buildMain, runMain, runMainIn, isDiagnostic, checkKey, onlineCores) where

import Data.List (isPrefixOf)
import Data.List (isInfixOf)
import Control.Monad (unless, when)
import Data.Maybe (fromMaybe)
import qualified Compile
import Codegen (codegenRev)
import qualified Compiler.Options as Options
import Frontend.Normalize (declaredProfile)
import Home (fprHome, underHome)
import qualified Sol.Main
import Data.Bits (xor)
import Data.List (foldl')
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Data.Time.Clock (UTCTime)
import Data.Word (Word64)
import Numeric (showHex)
import System.Directory (XdgDirectory (..), makeAbsolute, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, renameFile, getModificationTime, getTemporaryDirectory, getXdgDirectory, removeFile, canonicalizePath)
import System.Environment (getExecutablePath, withArgs)
import qualified System.Environment
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.FilePath (dropExtension, takeBaseName, takeDirectory, takeExtension, takeFileName, (</>))
import System.IO (IOMode (..), hClose, hPutStrLn, openFile, stderr)
import qualified System.Info
import System.Posix.Process (executeFile, getProcessID)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, rawSystem, readProcess, waitForProcess)
import Control.Exception (SomeException, try)

data Plan = Plan
  { pSource :: FilePath,
    pOut :: Maybe FilePath,
    pHarts :: Int,
    pModule :: Bool, -- host shared module, with no private runtime
    pKeep :: Bool,
    pVerbose :: Bool,
    pCC :: Maybe String,
    pWith :: [FilePath], -- the program's own HAL: C / asm sources linked beside the runtime
    pCFlags :: [String],
    pLink :: [String],
    pHost :: String, -- the posix system's host: "unix" (this machine), or "esp-idf" (a board: machine/esp-idf)
    pPort :: Maybe String, -- esp-idf: the board's serial port
    pCost :: Bool, -- --cost: print the root functions' work/alloc equations
    pManifest :: Maybe String, -- --manifest=FILE: judge them against a target manifest (passed through)
    pRemarks :: Maybe String, -- native advisory reporting; forwarded without affecting codegen keys
    pRest :: [String],
    pTarget :: Maybe (String, String), -- --target=linux-aarch64|linux-x86_64|linux-riscv64|macos-x86_64: a cross build (os, arch); Nothing is this machine
    pRelease :: Bool, -- --release: the toolchain's default code generation only (releaseGuard)
    pCompileDir :: Maybe FilePath -- where the compiler runs (a project's root: its .fpr/store); Nothing is here
  }

usage :: String
usage = "usage: fpr build --target=qos-portable [-v]  (installed QOS SDK project)\n       fpr build <prog.fpr> [-o out] [--harts N] [--cc CC] [-v] [--keep] [--module] [--release]\n                 [--target=linux-aarch64|linux-x86_64|linux-riscv64 --cc CROSS-GCC]\n                 [--target=macos-x86_64]  (on a Mac: x86-64 Mach-O, runs under Rosetta)\n                 [--with hal.c]... [--cflag F]... [--link F]...\n       fpr run <prog.fpr> [args...]\n       fpr build|run <prog.fpr> --host=esp-idf [-o dir] [--port P] [-v]"

-- The hart CAP compiled in is this machine's processor count (it was a flat 2,
-- so a server on a ten-core machine ran on two threads).  The running program
-- uses the cores IT finds, up to the cap (machine/unix/main.c), so a binary
-- built here and run on a smaller machine does not oversubscribe it; a
-- cross-build for a bigger one says --harts.  (docs/2026-09-19-BOUNDS.md: the arrays are
-- still static per hart; discovering the count at boot is the full fix.)
plan :: [String] -> IO Plan
plan args = do
  cores <- onlineCores
  go (Plan "" Nothing (max 2 cores) False False False Nothing [] [] [] "unix" Nothing False Nothing Nothing [] Nothing False Nothing) args
  where
    go p ("-o" : o : rest) = go p {pOut = Just o} rest
    go p ("--harts" : n : rest) = go p {pHarts = read n} rest
    go p ("--cc" : c : rest) = go p {pCC = Just c} rest
    go p ("--module" : rest) = go p {pModule = True} rest
    go p ("--keep" : rest) = go p {pKeep = True} rest
    go p ("--release" : rest) = go p {pRelease = True} rest
    go p ("--cost" : rest) = go p {pCost = True} rest
    go p ("--remarks" : rest) = go p {pRemarks = Just "hot"} rest
    go p (a : rest) | "--remarks=" `isPrefixOf` a = go p {pRemarks = Just (drop (length "--remarks=") a)} rest
    go p (a : rest) | "--manifest=" `isPrefixOf` a = go p {pCost = True, pManifest = Just a} rest
    go p ("--with" : f : rest) = go p {pWith = pWith p ++ [f]} rest
    go p ("--cflag" : f : rest) = go p {pCFlags = pCFlags p ++ [f]} rest
    go p ("--link" : f : rest) = go p {pLink = pLink p ++ [f]} rest
    go p ("-v" : rest) = go p {pVerbose = True} rest
    go p ("--target=linux-aarch64" : rest) = go p {pTarget = Just ("linux", "aarch64")} rest
    go p ("--target=linux-x86_64" : rest) = go p {pTarget = Just ("linux", "x86_64")} rest
    go p ("--target=linux-riscv64" : rest) = go p {pTarget = Just ("linux", "riscv64")} rest
    go p ("--target=macos-x86_64" : rest) = go p {pTarget = Just ("darwin", "x86_64")} rest
    go p ("--system=posix" : rest) = go p rest -- the only system these commands build
    go p ("--host=unix" : rest) = go p {pHost = "unix"} rest
    go p ("--host=esp-idf" : rest) = go p {pHost = "esp-idf"} rest
    go p ("--system=esp-idf" : rest) = go p {pHost = "esp-idf"} rest -- the 1.x spelling of --host=esp-idf
    go p ("--port" : d : rest) = go p {pPort = Just d} rest
    go p (a : rest)
      | null (pSource p) = go p {pSource = a} rest
      | otherwise = pure p {pRest = a : rest}
    go p [] = if null (pSource p) then hPutStrLn stderr usage >> exitFailure else pure p

-- GHC's getNumProcessors answers 1 in the non-threaded runtime fpr is built
-- with, so ask the OS; getconf spells it the same on macOS, Linux and FreeBSD
onlineCores :: IO Int
onlineCores = do
  r <- try (readProcess "getconf" ["_NPROCESSORS_ONLN"] "") :: IO (Either SomeException String)
  pure (case r of Right out | [(n, _)] <- reads out, n > 0 -> n; _ -> 2)

-- compile + link; the executable's path
build :: Options.CompilerOptions -> Plan -> IO FilePath
build configuration p = do
  let driver = Options.driverOptions configuration
  home <- fprHome
  -- the machine the executable is FOR: this one, or a --target cross build
  let (tOS, tArch) = fromMaybe (System.Info.os, System.Info.arch) (pTarget p)
      crossTarget = case pTarget p of
        Nothing -> []
        Just (_, "aarch64") -> ["--target=a64"]
        Just (_, "riscv64") -> ["--target=rv64"]
        Just ("darwin", "x86_64") -> ["--target=x64mac"]
        Just _ -> ["--target=x64"]
      -- a Mac builds the other Mac architecture with its own clang: -arch
      -- picks the target, and the SDK is the same (docs/2026-10-24-X64-MACOS.md)
      macCross = tOS == "darwin" && System.Info.os == "darwin" && tArch /= System.Info.arch
      archFlags = if macCross then ["-arch", tArch] else []
  when (macCross && tArch /= "x86_64") $ hPutStrLn stderr "fpr build: the only other Mac architecture built is macos-x86_64" >> exitFailure
  when (pTarget p /= Nothing && pCC p == Nothing && not (tOS == "darwin" && System.Info.os == "darwin")) $ hPutStrLn stderr "fpr build: a --target cross build needs --cc (e.g. --cc aarch64-linux-gnu-gcc)" >> exitFailure
  when (pTarget p /= Nothing && pModule p && tArch /= "riscv64" && tOS /= "darwin") $
    hPutStrLn stderr "fpr build: cross-built modules currently support linux-riscv64 and macos-x86_64 only" >> exitFailure
  let prelude = home </> "core" </> "prelude.fpr"
      runtime = home </> "runtime" -- the language runtime
      machine = home </> "machine" -- the machine layer under it, one per system (docs/2026-09-19-HAL.md)
  ok <- doesFileExist prelude
  unless ok $ hPutStrLn stderr ("fpr build: no prelude at " ++ prelude ++ " (set FPR_HOME to the fprisc checkout)") >> exitFailure
  -- one cache directory per user: the compiled prelude and every
  -- `use`d unit are cached beside the outputs (Compile's units/), so
  -- the second build of anything is a link
  cache <- getXdgDirectory XdgCache "fpr"
  pid <- getProcessID
  let dir = cache </> "build"
      asm = dir </> (takeBaseName (pSource p) ++ "-" ++ show pid ++ ".s")
      out = fromMaybe (dropExtension (pSource p) ++ if pModule p then if tOS == "darwin" then ".dylib" else ".so" else "") (pOut p)
  createDirectoryIfMissing True dir
  -- the compiler as a subprocess: its progress lines stay quiet unless
  -- asked for, its diagnostics (stderr) and its exit status pass through
  self <- getExecutablePath
  -- quiet on success, but a REFUSAL must be heard: the compiler reports
  -- type and safety errors on stdout, so that is kept and replayed when
  -- it fails.  (It went to /dev/null, and `fpr run` of a program the
  -- checker refused exited 1 having said nothing at all.)
  let logf = asm ++ ".log"
  logh <- openFile logf WriteMode
  (_, _, _, ch) <- createProcess (proc self (["compile", "--system=posix", "--prelude=" ++ prelude] ++ ["--plugin" | pModule p] ++ crossTarget ++ ["--cost" | pCost p] ++ maybe [] pure (pManifest p) ++ maybe [] (\mode->["--remarks="++mode]) (pRemarks p) ++ [pSource p, asm]))
                     {cwd = pCompileDir p, std_out = if pVerbose p || pCost p then Inherit else UseHandle logh}
  cc0 <- waitForProcess ch
  when (cc0 /= ExitSuccess) $ do
    -- a complaint in a shape isDiagnostic does not know (a module's parse
    -- error is megaparsec's own text) must still be heard: fall back to the
    -- log's tail rather than exit 1 in silence
    unless (pVerbose p || pCost p) $ do
      hClose logh
      ls <- lines <$> readFile logf
      let said = dropWhile (not . isDiagnostic) ls
      hPutStrLn stderr (unlines (if null said then drop (length ls - 12) ls else said))
    removeFile logf
    exitWith cc0
  removeFile logf
  -- Compile writes one path per line; cache and installed SDK paths can contain spaces.
  units <- filter (not . null) . lines <$> readFile (asm ++ ".units")
  cc <- case pCC p of
    Just c -> pure c
    Nothing -> pure (fromMaybe "cc" (Options.driverCC driver))
  let costProbe = Options.driverCostProbe driver
  let ctx = case tArch of
        "aarch64" -> "ctx_a64.S"
        "riscv64" -> "ctx_rv64.S"
        _ -> "ctx_x64.S"
      core = [runtime </> f | f <- ["runtime.c", "i32.c", "actors.c", "bits.c", "vec.c", "sstr.c", "mod.c", "buddy.c"]]
      -- the posix system: what both hosts share (machine/posix), and the unix host (machine/unix)
      posix = [machine </> "posix" </> f | f <- ["hal.c", "base.c", "base_file.c", "os_fs.c", "os_io.c", "os_watch.c", "os_net.c", "os_owned.c", "os_connection.c", "os_frame.c", "os_resolver.c", "os_tls_unavailable.c", "os_job.c", "os_module.c"]]
           ++ [machine </> "unix" </> f | f <- ["main.c", "park.c", "host.c", "os_proc.c", "os_term.c", "os_clock.c", ctx]]
      -- x28 is RESERVED on aarch64: the context switch (machine/unix/ctx_a64.S)
      -- does not save it, because QOS apps keep the hart pointer there.  Without
      -- this flag the C compiler may hold a value in x28 across a call that
      -- switches actors (spawn waits on the memory actor) and get another actor's
      -- back: a SIGSEGV one burst of 500 connections in twenty, and nowhere else.
      -- ... and x27 with it: AArch64 saves callee-saved registers in PAIRS, and
      -- Apple clang saves the (x27, x28) pair whenever a function uses x27 --
      -- -ffixed-x28 notwithstanding.  A function that saved x28 on one hart's
      -- thread and restored it after its actor migrated handed the new thread
      -- the old thread's hart (runtime/fpr.h).  With x27 reserved too, no C
      -- function ever needs that pair.  Generated code still uses x27 (its s9):
      -- it saves registers one at a time, never paired with x28.
      fixed = case tArch of
        "aarch64" -> ["-ffixed-x27", "-ffixed-x28", "-DFPR_HART_X28"]
        "riscv64" -> ["-march=rv64gc", "-mabi=lp64d", "-mcmodel=medany"]
        _ -> []
      cflags = archFlags ++ ["-O2", "-w", "-DFPR_POSIX", "-DFPR_POSIX_CODEGEN_REV=" ++ show codegenRev, "-DFPR_NHARTS=" ++ show (pHarts p), "-I" ++ runtime, "-I" ++ machine </> "posix", "-I" ++ machine </> "unix"] ++ fixed ++ ["-DFPR_COST_PROBE" | costProbe]
      linux = if tOS == "linux" then ["-no-pie", "-Wl,-z,noexecstack"] else []
      -- the runtime's objects are cached per hart count, rebuilt only
      -- when their source is newer: a warm build compiles the program
      -- and links, nothing more
      -- ... and per FLAGS: an object built with other flags is not this object
      -- ... and per COMPILER: --cc is how a cross build (qos/tools/buildroot)
      -- asks for a target binary, and an object another toolchain's gcc built
      -- against another libc is not this object either -- without cc in the
      -- key a warm host build silently hands its own .o files to the linker
      rtdir = cache </> "rt" </> (tOS ++ "-" ++ tArch ++ "-h" ++ show (pHarts p) ++ "-" ++ showHex (fnv64 (cc ++ " " ++ unwords cflags)) "")
      unitFlags = archFlags ++ fixed ++ ["-fPIC" | pModule p]
      uodir = cache </> "unit-obj" </> (tOS ++ "-" ++ tArch ++ (if pModule p then "-pic-" else "-") ++ showHex (fnv64 (cc ++ " " ++ unwords unitFlags)) "")
  createDirectoryIfMissing True rtdir
  createDirectoryIfMissing True uodir
  -- an object is stale when ANY header is newer, not just its own source: a
  -- changed struct in fpr.h (the hart block) otherwise links new objects
  -- against old ones, which is a crash with no message
  hdrs <- fmap concat (mapM headersIn [runtime, machine </> "posix", machine </> "unix"])
  hdrTime <- if null hdrs then pure Nothing else Just . maximum <$> mapM getModificationTime hdrs
  objs <- if pModule p then pure [] else mapM (objectFor cc cflags rtdir hdrTime) (posix ++ core)
  unitObjs <- mapM (unitObjectFor cc unitFlags uodir) units
  -- --with: a program that IS a host brings the device primitives it calls
  -- (the fpr_g_ names it leaves undefined) as C beside the runtime.  They
  -- are compiled with the runtime's flags plus --cflag, never cached.
  let shim = asm ++ ".module.c"
  when (pModule p) $ writeFile shim ("#include \"fpr.h\"\nconst uw fpr_posix_module_nativeabi = FPR_NATIVE_ABI;\nconst uw fpr_posix_module_codegen = " ++ show codegenRev ++ ";\n")
  let links = if pModule p then (if tOS == "darwin" then ["-dynamiclib", "-Wl,-undefined,dynamic_lookup"] else ["-shared", "-Wl,-Bsymbolic"]) ++ [shim]
              else linux ++ (if tOS == "linux" then ["-rdynamic", "-ldl"] else ["-Wl,-export_dynamic"])
      args = cflags ++ (if pModule p then ["-fPIC", "-DFPR_POSIX_MODULE"] else []) ++ pCFlags p ++ links ++ [asm] ++ unitObjs ++ objs ++ pWith p ++ pLink p ++ ["-lpthread", "-lm", "-o", out]
  code <- rawSystem cc args
  when (code /= ExitSuccess) $ hPutStrLn stderr ("fpr build: " ++ cc ++ " failed") >> exitWith code
  if pKeep p
    then hPutStrLn stderr ("fpr build: kept " ++ asm)
    else mapM_ (\f -> doesFileExist f >>= \e -> when e (removeFile f)) ([asm, asm ++ ".units", asm ++ ".abirev"] ++ [shim | pModule p])
  pure out

-- where the compiler's progress lines end and its complaint begins
isDiagnostic :: String -> Bool
isDiagnostic l = take 4 l == "=== " || take 4 l == "  * " || "rror" `isInfixOf` l

-- compile one runtime source into the cache unless its object is fresh
headersIn :: FilePath -> IO [FilePath]
headersIn d = do
  e <- doesDirectoryExist d
  if not e then pure [] else do
    fs <- listDirectory d
    pure [d </> f | f <- fs, takeExtension f == ".h"]

objectFor :: String -> [String] -> FilePath -> Maybe UTCTime -> FilePath -> IO FilePath
objectFor cc cflags rtdir hdrTime src = do
  let obj = rtdir </> (takeFileName src ++ ".o")
  fresh <- do
    e <- doesFileExist obj
    if not e then pure False else do
      ts <- getModificationTime src
      to <- getModificationTime obj
      pure (to >= ts && maybe True (to >=) hdrTime)
  unless fresh $ do
    pid <- getProcessID
    let tmp = obj ++ ".tmp." ++ show pid ++ ".o"
    code <- rawSystem cc (cflags ++ ["-c", src, "-o", tmp])
    when (code /= ExitSuccess) $ do
      doesFileExist tmp >>= \e -> when e (removeFile tmp)
      hPutStrLn stderr ("fpr build: " ++ cc ++ " failed on " ++ src)
      exitWith code
    renameFile tmp obj
  pure obj

-- assemble one cached unit .s into a cached .o unless its object is fresh
unitObjectFor :: String -> [String] -> FilePath -> FilePath -> IO FilePath
unitObjectFor cc unitFlags uodir src = do
  let obj = uodir </> (takeFileName src ++ ".o")
  fresh <- do
    e <- doesFileExist obj
    if not e then pure False else do
      ts <- getModificationTime src
      to <- getModificationTime obj
      pure (to >= ts)
  unless fresh $ do
    pid <- getProcessID
    let tmp = obj ++ ".tmp." ++ show pid ++ ".o"
    code <- rawSystem cc (unitFlags ++ ["-c", src, "-o", tmp])
    when (code /= ExitSuccess) $ do
      doesFileExist tmp >>= \e -> when e (removeFile tmp)
      hPutStrLn stderr ("fpr build: " ++ cc ++ " failed on " ++ src)
      exitWith code
    renameFile tmp obj
  pure obj

-- the profile the file declares (`profile sol.` or a .sol name means the VM)
profileOf :: FilePath -> IO String
profileOf src = do
  tops <- Compile.parseFile src
  pure (fromMaybe (if takeExtension src == ".sol" then "sol" else "base") (declaredProfile tops))

buildMain :: [String] -> IO ()
buildMain args = do
  when ("--target=qos-portable" `elem` args) $ qosPortable args
  p <- plan args
  unless (null (pRest p)) $ hPutStrLn stderr usage >> exitFailure
  when (pModule p && pHost p /= "unix") $ hPutStrLn stderr "host modules require --host=unix" >> exitFailure
  when (pHost p == "esp-idf") $ espIdf "build.sh" p []
  prof <- profileOf (pSource p)
  when (prof == "sol") $ hPutStrLn stderr "fpr build: a sol program runs on the VM (`fpr run`, `fpr sol`); it is not built into an executable" >> exitFailure
  configuration <- Options.readCompilerOptions
  when (pRelease p) $ releaseGuard "build" configuration
  out <- build configuration p
  hPutStrLn stderr ("fpr build: " ++ out)

-- QOS owns its installed desktop builder. Resolve it from the real compiler
-- location; keep app project discovery and packaging out of the POSIX plan.
-- Only QOS's own matched compiler has the builder beside it. A standalone
-- FP-RISC install never searches for a QOS SDK (that could pair a newer
-- compiler with an older QOS package): it points at `qos build`, which
-- always selects QOS's private compiler.
-- --manifest retains its existing cost-contract meaning (the QOS builder
-- refuses unsupported options instead of silently changing their meaning).
qosPortable :: [String] -> IO ()
qosPortable args = do
  self <- getExecutablePath >>= canonicalizePath
  explicit <- System.Environment.lookupEnv "QOS_PORTABLE_BUILDER"
  let builder = fromMaybe (takeDirectory (takeDirectory self) </> "tools" </> "portable_sdk.py") explicit
  exists <- doesFileExist builder
  unless exists $ hPutStrLn stderr "fpr build: QOS Portable apps are built by the QOS SDK with its own compiler; run `qos build` in the project (this fpr has no QOS builder)" >> exitWith (ExitFailure 2)
  code <- rawSystem "python3" ([builder, "build", "--compiler", self] ++ filter (/= "--target=qos-portable") args)
  exitWith code

-- A release is built the way the toolchain builds by default.  The FPR_*
-- code generation and cost-probe controls are for developing the compiler;
-- one left set in the shell would make a release differ from what its
-- manifest and toolchain say, so --release refuses them rather than ignore them.
releaseGuard :: String -> Options.CompilerOptions -> IO ()
releaseGuard cmd configured = do
  let defaults = either (error . Options.renderOptionError) id (Options.parseCompilerOptions (const Nothing))
      differs = Options.codegenOptions configured /= Options.codegenOptions defaults
             || Options.driverCostProbe (Options.driverOptions configured)
  when differs $ do
    env <- System.Environment.getEnvironment
    let set = [k | (k, _) <- env, "FPR_" `isPrefixOf` k, k `notElem` ["FPR_HOME", "FPR_PATH", "FPR_CC", "FPR_FOREIGN", "FPR_HARTS", "FPR_NO_RUN_CACHE"]]
    hPutStrLn stderr ("fpr " ++ cmd ++ " --release: builds with the toolchain's default code generation; unset " ++ unwords set)
    exitWith (ExitFailure 2)

runMain :: [String] -> IO ()
runMain = runMainIn Nothing

-- `fpr run` in a project: the program keeps the caller's working directory,
-- but its source is compiled in the project's root, where a pinned
-- `use "NAME#HASH"` finds .fpr/store (Modules.hs looks for it from the
-- compiler's working directory)
runMainIn :: Maybe FilePath -> [String] -> IO ()
runMainIn dir args = do
  p0 <- plan args
  let p = p0 {pCompileDir = dir}
  when (pModule p) $ hPutStrLn stderr "use fpr build --module, then Native.attach" >> exitFailure
  when (pHost p == "esp-idf") $ do
    unless (null (pRest p)) $ hPutStrLn stderr "fpr run: a board program is started with no arguments (Sys.args is [] there)" >> exitFailure
    espIdf "run.sh" p (maybe [] (: []) (pPort p))
  prof <- profileOf (pSource p)
  when (prof == "sol") $ withArgs (pSource p : pRest p) Sol.Main.main >> exitWith ExitSuccess
  when (pRelease p) $ Options.readCompilerOptions >>= releaseGuard "run"
  -- A program that has not changed is not compiled again: the executable is
  -- kept under a key of everything that made it (runKey), so a script starts
  -- as fast as it runs.  FPR_NO_RUN_CACHE=1 builds afresh into a temp file.
  configuration <- Options.readCompilerOptions
  exe <- if Options.driverNoRunCache (Options.driverOptions configuration) then do
      tmp <- getTemporaryDirectory
      pid <- getProcessID
      build configuration p {pOut = Just (tmp </> ("fpr-run-" ++ takeBaseName (pSource p) ++ "-" ++ show pid))}
    else do
      key <- runKey configuration p
      cache <- getXdgDirectory XdgCache "fpr"
      let dir = cache </> "run"
          kept = dir </> (takeBaseName (pSource p) ++ "-" ++ key)
      createDirectoryIfMissing True dir
      have <- doesFileExist kept
      if have && pRemarks p==Nothing then pure kept else do
        pid <- getProcessID
        let fresh = kept ++ ".tmp" ++ show pid -- built beside it, renamed whole: two runs at once never see half a file
        _ <- build configuration p {pOut = Just fresh}
        renameFile fresh kept
        pure kept
  -- BECOME the program rather than wait on it as a child: a signal sent to
  -- `fpr run` (a supervisor's SIGTERM, a test harness stopping a server) then
  -- reaches the program itself.  As a child it outlived its killed parent and
  -- ran on as an orphan -- a server still holding its port.
  executeFile exe False (pRest p) Nothing

-- Everything a run's executable is made from: the program and every module it
-- `use`s (transitively, resolved as Modules.hs resolves them: beside the
-- importer, then under the toolchain's home), the prelude, this compiler, the
-- runtime's and the posix machine layer's sources, and the plan's flags.
runKey :: Options.CompilerOptions -> Plan -> IO String
runKey configuration p = do
  home <- fprHome
  self <- getExecutablePath
  srcs <- map fst <$> sourceClosure (pSource p)
  let rtDirs = [home </> "runtime", home </> "machine" </> "posix", home </> "machine" </> "unix"]
  rtFiles <- fmap concat (mapM listed rtDirs)
  stamps <- mapM stamp (self : (home </> "core" </> "prelude.fpr") : rtFiles ++ pWith p)
  bodies <- map (show . snd) <$> sourceClosure (pSource p)
  let driver = Options.driverOptions configuration
      foreignDecls = Options.driverForeign driver
      modes = Options.codegenCacheIdentity (Options.codegenOptions configuration)
  foreignBodies <- mapM readFileStrict foreignDecls
  let text = unlines (srcs ++ bodies ++ stamps ++ foreignBodies ++
        [show (pHarts p), show (pCC p), show (Options.driverCC driver),
         show (pTarget p), unwords (pCFlags p ++ pLink p),
         show foreignDecls, show (Options.driverCostProbe driver), modes, show (pCompileDir p)])
  pure (showHex (fnv64 text) "")
  where
    listed d = do
      e <- doesDirectoryExist d
      if e then map (d </>) <$> listDirectory d else pure []

-- Everything `fpr compile --check-only FILE` reads, as a key: the file and
-- every module it uses (sourceClosure), the prelude and this compiler (their
-- stamps), the --foreign declarations, FPR_PATH, the working directory (it
-- holds .fpr/store) and the flags.  `fpr check` skips a file whose key last
-- passed.
checkKey :: [String] -> FilePath -> IO String
checkKey flags file = do
  home <- fprHome
  self <- getExecutablePath
  here <- getCurrentDirectory'
  closure <- sourceClosure file
  let srcs = [f ++ " " ++ show h | (f, h) <- closure]
      bodies = []
  stamps <- mapM stamp [self, home </> "core" </> "prelude.fpr"]
  configuration <- Options.readCompilerOptions
  let foreignDecls = Options.driverForeign (Options.driverOptions configuration)
  foreignBodies <- mapM readFileStrict foreignDecls
  path <- System.Environment.lookupEnv "FPR_PATH"
  pure (showHex (fnv64 (unlines (srcs ++ bodies ++ stamps ++ foreignDecls ++ foreignBodies ++ [show path, here, home] ++ flags))) "")
  where
    getCurrentDirectory' = makeAbsolute "."

stamp :: FilePath -> IO String
stamp f = do
  e <- doesFileExist f
  if not e then pure (f ++ " missing") else do
    t <- getModificationTime f
    pure (f ++ " " ++ show t)

readFileStrict :: FilePath -> IO String
readFileStrict f = do
  e <- doesFileExist f
  if not e then pure "" else do
    t <- readFile f
    length t `seq` pure t

-- a program and every module it `use`s, transitively, resolved as Modules.hs
-- resolves them: beside the importer, then under the home and FPR_PATH roots;
-- each with a digest of its bytes.  Read strictly as bytes: a std/http
-- closure is ~170 files, 2 MB.
sourceClosure :: FilePath -> IO [(FilePath, Word64)]
sourceClosure root = do
  home <- fprHome
  closure home [] [root]
  where
    closure _ seen [] = pure (reverse seen)
    closure home seen (f : rest)
      | f `elem` map fst seen = closure home seen rest
      | otherwise = do
          e <- doesFileExist f
          if not e then closure home seen rest else do
            bytes <- B.readFile f
            let uses = usesIn bytes
            deps <- mapM (resolve home (takeDirectory f)) uses
            -- a pinned use may resolve from the store (from the working directory)
            let pinned = [".fpr" </> "store" </> (drop 1 h ++ ".fpr") | u <- uses, let h = dropWhile (/= '#') u, not (null h)]
            closure home ((f, fnvBytes bytes) : seen) (rest ++ deps ++ pinned)
    resolve home dir nm0 = do
      let nm = takeWhile (/= '#') nm0
          file = if takeExtension nm == ".fpr" then nm else nm ++ ".fpr"
          here = if take 1 file == "/" then file else dir </> file
      e <- doesFileExist here
      if e then pure here else maybe (home </> file) id <$> underHome file
    usesIn bytes = [B8.unpack (B8.takeWhile (/= '"') (B.drop (B.length pat) r))
                   | l <- B8.lines bytes, let (_, r) = B.breakSubstring pat l, not (B.null r)]
    pat = B8.pack "use \""

fnvBytes :: B.ByteString -> Word64
fnvBytes = B.foldl' (\h c -> (h `xor` fromIntegral c) * 1099511628211) 14695981039346656037

fnv64 :: String -> Word64
fnv64 = foldl' (\h c -> (h `xor` fromIntegral (fromEnum c)) * 1099511628211) 14695981039346656037

-- --host=esp-idf: the board's build and console live beside its host layer
-- (machine/esp-idf/build.sh, run.sh, console.py), in ESP-IDF's tools; fpr
-- hands over and exits with their status -- for `run`, the program's own.
espIdf :: String -> Plan -> [String] -> IO ()
espIdf script p extra = do
  home <- fprHome
  let dir = home </> "machine" </> "esp-idf"
  out <- makeAbsolute (fromMaybe (home </> "build" </> "esp-idf" </> takeBaseName (pSource p)) (pOut p))
  env0 <- System.Environment.getEnvironment
  let env = [("FPR_ESP_OUT", out)] ++ [("FPR_ESP_VERBOSE", "1") | pVerbose p]
            ++ [kv | kv@(k, _) <- env0, k /= "FPR_ESP_OUT", not (pVerbose p && k == "FPR_ESP_VERBOSE")]
      args = if script == "build.sh" then [pSource p, out] else pSource p : extra
  (_, _, _, ph) <- createProcess (proc "sh" ((dir </> script) : args)) {env = Just env}
  code <- waitForProcess ph
  when (script == "build.sh" && code == ExitSuccess) $
    hPutStrLn stderr ("fpr build: " ++ (out </> "idf" </> "fpr_esp.bin") ++ " (flash with: fpr run --host=esp-idf, or idf.py -B " ++ (out </> "idf") ++ " flash)")
  exitWith code

