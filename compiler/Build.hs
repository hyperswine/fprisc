-- Build.hs -- `fpr build` and `fpr run`: the Base profile as one command.
--
--   fpr build prog.fpr [-o out] [--harts N] [--cc CC] [-v] [--keep]
--   fpr run   prog.fpr [args...]
--   fpr build prog.fpr --system=esp-idf [-o dir]      an ESP32-P4 image
--   fpr run   prog.fpr --system=esp-idf [--port P]    flash it and be its console
--
-- A program becomes an ordinary executable for THIS machine: the
-- compiler lowers it for the host ISA (--profile=base), and the C
-- compiler links the generated assembly with the shared core runtime
-- (runtime) and the hosted HAL (machine/posix), both found beside the
-- fpr binary (Home.hs).  No Makefile, no QOS: the same three parts a
-- bare-metal image is made of, with libc as the board.
module Build (buildMain, runMain) where

import Data.List (isInfixOf)
import Control.Monad (unless, when)
import Data.Maybe (fromMaybe)
import qualified Compile
import FPRISC (declaredProfile)
import Home (fprHome)
import qualified Sol.Main
import Data.Bits (xor)
import Data.Time.Clock (UTCTime)
import Data.Word (Word64)
import Numeric (showHex)
import System.Directory (XdgDirectory (..), makeAbsolute, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, renameFile, getModificationTime, getTemporaryDirectory, getXdgDirectory, removeFile)
import System.Environment (getExecutablePath, lookupEnv, withArgs)
import qualified System.Environment
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.FilePath (dropExtension, takeBaseName, takeDirectory, takeExtension, takeFileName, (</>))
import System.IO (IOMode (..), hPutStrLn, openFile, stderr)
import qualified System.Info
import System.Posix.Process (executeFile, getProcessID)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, rawSystem, readProcess, waitForProcess)
import Control.Exception (SomeException, try)

data Plan = Plan
  { pSource :: FilePath,
    pOut :: Maybe FilePath,
    pHarts :: Int,
    pKeep :: Bool,
    pVerbose :: Bool,
    pCC :: Maybe String,
    pWith :: [FilePath], -- the program's own HAL: C / asm sources linked beside the runtime
    pCFlags :: [String],
    pLink :: [String],
    pSystem :: String, -- "posix" (this machine), or "esp-idf" (a board: machine/esp-idf)
    pPort :: Maybe String, -- esp-idf: the board's serial port
    pRest :: [String]
  }

usage :: String
usage = "usage: fpr build <prog.fpr> [-o out] [--harts N] [--cc CC] [-v] [--keep]\n                 [--with hal.c]... [--cflag F]... [--link F]...\n       fpr run <prog.fpr> [args...]\n       fpr build|run <prog.fpr> --system=esp-idf [-o dir] [--port P] [-v]"

-- The hart CAP compiled in is this machine's processor count (it was a flat 2,
-- so a server on a ten-core machine ran on two threads).  The running program
-- uses the cores IT finds, up to the cap (machine/posix/main.c), so a binary
-- built here and run on a smaller machine does not oversubscribe it; a
-- cross-build for a bigger one says --harts.  (docs/BOUNDS.md: the arrays are
-- still static per hart; discovering the count at boot is the full fix.)
plan :: [String] -> IO Plan
plan args = do
  cores <- onlineCores
  go (Plan "" Nothing (max 2 cores) False False Nothing [] [] [] "posix" Nothing []) args
  where
    go p ("-o" : o : rest) = go p {pOut = Just o} rest
    go p ("--harts" : n : rest) = go p {pHarts = read n} rest
    go p ("--cc" : c : rest) = go p {pCC = Just c} rest
    go p ("--keep" : rest) = go p {pKeep = True} rest
    go p ("--with" : f : rest) = go p {pWith = pWith p ++ [f]} rest
    go p ("--cflag" : f : rest) = go p {pCFlags = pCFlags p ++ [f]} rest
    go p ("--link" : f : rest) = go p {pLink = pLink p ++ [f]} rest
    go p ("-v" : rest) = go p {pVerbose = True} rest
    go p ("--system=posix" : rest) = go p {pSystem = "posix"} rest
    go p ("--system=esp-idf" : rest) = go p {pSystem = "esp-idf"} rest
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
build :: Plan -> IO FilePath
build p = do
  home <- fprHome
  let prelude = home </> "core" </> "prelude.fpr"
      runtime = home </> "runtime" -- the language runtime
      machine = home </> "machine" -- the machine layer under it, one per system (docs/HAL.md)
  ok <- doesFileExist prelude
  unless ok $ hPutStrLn stderr ("fpr build: no prelude at " ++ prelude ++ " (set FPR_HOME to the fprisc checkout)") >> exitFailure
  -- one cache directory per user: the compiled prelude and every
  -- `use`d unit are cached beside the outputs (Compile's units/), so
  -- the second build of anything is a link
  cache <- getXdgDirectory XdgCache "fpr"
  pid <- getProcessID
  let dir = cache </> "build"
      asm = dir </> (takeBaseName (pSource p) ++ "-" ++ show pid ++ ".s")
      out = fromMaybe (dropExtension (pSource p)) (pOut p)
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
  (_, _, _, ch) <- createProcess (proc self ["compile", "--system=posix", "--prelude=" ++ prelude, pSource p, asm])
                     {std_out = if pVerbose p then Inherit else UseHandle logh}
  cc0 <- waitForProcess ch
  when (cc0 /= ExitSuccess) $ do
    -- a complaint in a shape isDiagnostic does not know (a module's parse
    -- error is megaparsec's own text) must still be heard: fall back to the
    -- log's tail rather than exit 1 in silence
    unless (pVerbose p) $ do
      ls <- lines <$> readFile logf
      let said = dropWhile (not . isDiagnostic) ls
      hPutStrLn stderr (unlines (if null said then drop (length ls - 12) ls else said))
    removeFile logf
    exitWith cc0
  removeFile logf
  units <- words <$> readFile (asm ++ ".units")
  cc <- case pCC p of
    Just c -> pure c
    Nothing -> fromMaybe "cc" <$> lookupEnv "FPR_CC"
  let ctx = if System.Info.arch == "aarch64" then "ctx_a64.S" else "ctx_x64.S"
      core = [runtime </> f | f <- ["runtime.c", "actors.c", "bits.c", "vec.c", "sstr.c", "mod.c", "buddy.c"]]
      posix = [machine </> "posix" </> f | f <- ["main.c", "hal.c", "park.c", "host.c", "base.c", "base_file.c", "os_fs.c", "os_clock.c", "os_io.c", "os_proc.c", "os_watch.c", "os_net.c", "os_term.c"]] ++ [machine </> "unix" </> ctx]
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
      fixed = if System.Info.arch == "aarch64" then ["-ffixed-x27", "-ffixed-x28", "-DFPR_HART_X28"] else [] -- x28 carries the hart (runtime/fpr.h)
      cflags = ["-O2", "-w", "-DFPR_POSIX", "-DFPR_NHARTS=" ++ show (pHarts p), "-I" ++ runtime, "-I" ++ machine </> "posix"] ++ fixed
      linux = if System.Info.os == "linux" then ["-no-pie", "-Wl,-z,noexecstack"] else []
      -- the runtime's objects are cached per hart count, rebuilt only
      -- when their source is newer: a warm build compiles the program
      -- and links, nothing more
      -- ... and per FLAGS: an object built with other flags is not this object
      -- ... and per COMPILER: --cc is how a cross build (qos/tools/buildroot)
      -- asks for a target binary, and an object another toolchain's gcc built
      -- against another libc is not this object either -- without cc in the
      -- key a warm host build silently hands its own .o files to the linker
      rtdir = cache </> "rt" </> (System.Info.arch ++ "-h" ++ show (pHarts p) ++ "-" ++ showHex (fnv64 (cc ++ " " ++ unwords cflags)) "")
  createDirectoryIfMissing True rtdir
  -- an object is stale when ANY header is newer, not just its own source: a
  -- changed struct in fpr.h (the hart block) otherwise links new objects
  -- against old ones, which is a crash with no message
  hdrs <- fmap concat (mapM headersIn [runtime, machine </> "posix"])
  hdrTime <- if null hdrs then pure Nothing else Just . maximum <$> mapM getModificationTime hdrs
  objs <- mapM (objectFor cc cflags rtdir hdrTime) (posix ++ core)
  -- --with: a program that IS a host brings the device primitives it calls
  -- (the fpr_g_ names it leaves undefined) as C beside the runtime.  They
  -- are compiled with the runtime's flags plus --cflag, never cached.
  let args = cflags ++ pCFlags p ++ linux ++ [asm] ++ units ++ objs ++ pWith p ++ pLink p ++ ["-lpthread", "-lm", "-o", out]
  code <- rawSystem cc args
  when (code /= ExitSuccess) $ hPutStrLn stderr ("fpr build: " ++ cc ++ " failed") >> exitWith code
  if pKeep p
    then hPutStrLn stderr ("fpr build: kept " ++ asm)
    else mapM_ (\f -> doesFileExist f >>= \e -> when e (removeFile f)) [asm, asm ++ ".units", asm ++ ".abirev"]
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
    code <- rawSystem cc (cflags ++ ["-c", src, "-o", obj])
    when (code /= ExitSuccess) $ hPutStrLn stderr ("fpr build: " ++ cc ++ " failed on " ++ src) >> exitWith code
  pure obj

-- the profile the file declares (`profile sol.` or a .sol name means the VM)
profileOf :: FilePath -> IO String
profileOf src = do
  tops <- Compile.parseFile src
  pure (fromMaybe (if takeExtension src == ".sol" then "sol" else "base") (declaredProfile tops))

buildMain :: [String] -> IO ()
buildMain args = do
  p <- plan args
  unless (null (pRest p)) $ hPutStrLn stderr usage >> exitFailure
  when (pSystem p == "esp-idf") $ espIdf "build.sh" p []
  prof <- profileOf (pSource p)
  when (prof == "sol") $ hPutStrLn stderr "fpr build: a sol program runs on the VM (`fpr run`, `fpr sol`); it is not built into an executable" >> exitFailure
  out <- build p
  hPutStrLn stderr ("fpr build: " ++ out)

runMain :: [String] -> IO ()
runMain args = do
  p <- plan args
  when (pSystem p == "esp-idf") $ do
    unless (null (pRest p)) $ hPutStrLn stderr "fpr run: a board program is started with no arguments (Sys.args is [] there)" >> exitFailure
    espIdf "run.sh" p (maybe [] (: []) (pPort p))
  prof <- profileOf (pSource p)
  when (prof == "sol") $ withArgs (pSource p : pRest p) Sol.Main.main >> exitWith ExitSuccess
  -- A program that has not changed is not compiled again: the executable is
  -- kept under a key of everything that made it (runKey), so a script starts
  -- as fast as it runs.  FPR_NO_RUN_CACHE=1 builds afresh into a temp file.
  off <- lookupEnv "FPR_NO_RUN_CACHE"
  exe <- case off of
    Just v | not (null v) -> do
      tmp <- getTemporaryDirectory
      pid <- getProcessID
      build p {pOut = Just (tmp </> ("fpr-run-" ++ takeBaseName (pSource p) ++ "-" ++ show pid))}
    _ -> do
      key <- runKey p
      cache <- getXdgDirectory XdgCache "fpr"
      let dir = cache </> "run"
          kept = dir </> (takeBaseName (pSource p) ++ "-" ++ key)
      createDirectoryIfMissing True dir
      have <- doesFileExist kept
      if have then pure kept else do
        pid <- getProcessID
        let fresh = kept ++ ".tmp" ++ show pid -- built beside it, renamed whole: two runs at once never see half a file
        _ <- build p {pOut = Just fresh}
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
runKey :: Plan -> IO String
runKey p = do
  home <- fprHome
  self <- getExecutablePath
  srcs <- closure home [] [pSource p]
  let rtDirs = [home </> "runtime", home </> "machine" </> "posix", home </> "machine" </> "unix"]
  rtFiles <- fmap concat (mapM listed rtDirs)
  stamps <- mapM stamp (self : (home </> "core" </> "prelude.fpr") : rtFiles ++ pWith p)
  bodies <- mapM readFileStrict srcs
  foreignDecls <- lookupEnv "FPR_FOREIGN"
  let text = unlines (srcs ++ bodies ++ stamps ++ [show (pHarts p), show (pCC p), unwords (pCFlags p ++ pLink p), show foreignDecls])
  pure (showHex (fnv64 text) "")
  where
    listed d = do
      e <- doesDirectoryExist d
      if e then map (d </>) <$> listDirectory d else pure []
    stamp f = do
      e <- doesFileExist f
      if not e then pure (f ++ " missing") else do
        t <- getModificationTime f
        pure (f ++ " " ++ show t)
    readFileStrict f = do
      e <- doesFileExist f
      if not e then pure "" else do
        t <- readFile f
        length t `seq` pure t
    closure _ seen [] = pure (reverse seen)
    closure home seen (f : rest)
      | f `elem` seen = closure home seen rest
      | otherwise = do
          e <- doesFileExist f
          if not e then closure home seen rest else do
            t <- readFileStrict f
            deps <- mapM (resolve home (takeDirectory f)) (usesIn t)
            closure home (f : seen) (rest ++ deps)
    resolve home dir nm0 = do
      let nm = takeWhile (/= '#') nm0
          file = if takeExtension nm == ".fpr" then nm else nm ++ ".fpr"
          here = if take 1 file == "/" then file else dir </> file
      e <- doesFileExist here
      pure (if e then here else home </> file)
    usesIn t = [takeWhile (/= '"') r | l <- lines t, Just r <- [after "use \"" l]]
    after pat l
      | null l = Nothing
      | take (length pat) l == pat = Just (drop (length pat) l)
      | otherwise = after pat (drop 1 l)

fnv64 :: String -> Word64
fnv64 = foldl (\h c -> (h `xor` fromIntegral (fromEnum c)) * 1099511628211) 14695981039346656037

-- --system=esp-idf: the board's build and console live beside its machine
-- layer (machine/esp-idf/build.sh, run.sh, console.py), in ESP-IDF's tools;
-- fpr hands over and exits with their status -- for `run`, the program's own.
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
    hPutStrLn stderr ("fpr build: " ++ (out </> "idf" </> "fpr_esp.bin") ++ " (flash with: fpr run --system=esp-idf, or idf.py -B " ++ (out </> "idf") ++ " flash)")
  exitWith code

