-- Build.hs -- `fpr build` and `fpr run`: the Base profile as one command.
--
--   fpr build prog.fpr [-o out] [--harts N] [--cc CC] [-v] [--keep]
--   fpr run   prog.fpr [args...]
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
import System.Directory (XdgDirectory (..), createDirectoryIfMissing, doesFileExist, getModificationTime, getTemporaryDirectory, getXdgDirectory, removeFile)
import System.Environment (getExecutablePath, lookupEnv, withArgs)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.FilePath (dropExtension, takeBaseName, takeExtension, takeFileName, (</>))
import System.IO (IOMode (..), hPutStrLn, openFile, stderr)
import qualified System.Info
import System.Posix.Process (getProcessID)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, rawSystem, waitForProcess)

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
    pRest :: [String]
  }

usage :: String
usage = "usage: fpr build <prog.fpr> [-o out] [--harts N] [--cc CC] [-v] [--keep]\n                 [--with hal.c]... [--cflag F]... [--link F]...\n       fpr run <prog.fpr> [args...]"

plan :: [String] -> IO Plan
plan = go (Plan "" Nothing 2 False False Nothing [] [] [] [])
  where
    go p ("-o" : o : rest) = go p {pOut = Just o} rest
    go p ("--harts" : n : rest) = go p {pHarts = read n} rest
    go p ("--cc" : c : rest) = go p {pCC = Just c} rest
    go p ("--keep" : rest) = go p {pKeep = True} rest
    go p ("--with" : f : rest) = go p {pWith = pWith p ++ [f]} rest
    go p ("--cflag" : f : rest) = go p {pCFlags = pCFlags p ++ [f]} rest
    go p ("--link" : f : rest) = go p {pLink = pLink p ++ [f]} rest
    go p ("-v" : rest) = go p {pVerbose = True} rest
    go p (a : rest)
      | null (pSource p) = go p {pSource = a} rest
      | otherwise = pure p {pRest = a : rest}
    go p [] = if null (pSource p) then hPutStrLn stderr usage >> exitFailure else pure p

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
    unless (pVerbose p) $ readFile logf >>= hPutStrLn stderr . unlines . dropWhile (not . isDiagnostic) . lines
    removeFile logf
    exitWith cc0
  removeFile logf
  units <- words <$> readFile (asm ++ ".units")
  cc <- case pCC p of
    Just c -> pure c
    Nothing -> fromMaybe "cc" <$> lookupEnv "FPR_CC"
  let ctx = if System.Info.arch == "aarch64" then "ctx_a64.S" else "ctx_x64.S"
      core = [runtime </> f | f <- ["runtime.c", "actors.c", "bits.c", "vec.c", "sstr.c", "mod.c", "buddy.c"]]
      posix = [machine </> "posix" </> f | f <- ["main.c", "hal.c", "base.c"]] ++ [machine </> "unix" </> ctx]
      cflags = ["-O2", "-w", "-DFPR_POSIX", "-DFPR_NHARTS=" ++ show (pHarts p), "-I" ++ runtime, "-I" ++ machine </> "posix"]
      linux = if System.Info.os == "linux" then ["-no-pie", "-Wl,-z,noexecstack"] else []
      -- the runtime's objects are cached per hart count, rebuilt only
      -- when their source is newer: a warm build compiles the program
      -- and links, nothing more
      rtdir = cache </> "rt" </> (System.Info.arch ++ "-h" ++ show (pHarts p))
  createDirectoryIfMissing True rtdir
  objs <- mapM (objectFor cc cflags rtdir) (posix ++ core)
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
objectFor :: String -> [String] -> FilePath -> FilePath -> IO FilePath
objectFor cc cflags rtdir src = do
  let obj = rtdir </> (takeFileName src ++ ".o")
  fresh <- do
    e <- doesFileExist obj
    if not e then pure False else do
      ts <- getModificationTime src
      to <- getModificationTime obj
      pure (to >= ts)
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
  prof <- profileOf (pSource p)
  when (prof == "sol") $ hPutStrLn stderr "fpr build: a sol program runs on the VM (`fpr run`, `fpr sol`); it is not built into an executable" >> exitFailure
  out <- build p
  hPutStrLn stderr ("fpr build: " ++ out)

runMain :: [String] -> IO ()
runMain args = do
  p <- plan args
  prof <- profileOf (pSource p)
  when (prof == "sol") $ withArgs (pSource p : pRest p) Sol.Main.main >> exitWith ExitSuccess
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let exe = tmp </> ("fpr-run-" ++ takeBaseName (pSource p) ++ "-" ++ show pid)
  out <- build p {pOut = Just exe}
  (_, _, _, h) <- createProcess (proc out (pRest p))
  code <- waitForProcess h
  exitWith code
