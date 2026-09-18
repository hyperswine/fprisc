-- Home.hs -- where the toolchain's own files are.
--
-- `fpr` is one binary that needs three things on disk beside it: the
-- prelude (core/prelude.fpr), the std modules a program `use`s, and the
-- .fpr store of committed versions.  In a checkout all three sit around
-- the binary; an installed tree (`qos.py install`, the Homebrew formula)
-- keeps that layout under libexec and puts a SYMLINK on the PATH.  So
-- home is: $FPR_HOME when set, else the directory the executable really
-- lives in -- canonicalized, because on macOS getExecutablePath answers
-- with the path as invoked (the symlink), and a symlink's directory has
-- none of those files.
--
-- Callers ask two questions: `fprHome` for the root, and `underHome` for
-- "does this relative file exist below it" -- the fallback a `use` takes
-- after the importer-relative path misses.  Neither touches the resolution
-- order of anything that already resolved: a program in the tree still
-- finds "../std/mvu" first, exactly as before.
module Home (fprHome, underHome) where

import Control.Exception (SomeException, try)
import System.Directory (canonicalizePath, doesFileExist)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, (</>))

fprHome :: IO FilePath
fprHome = do
  env <- lookupEnv "FPR_HOME"
  case env of
    Just d | not (null d) -> pure d
    _ -> do
      exe <- getExecutablePath
      real <- try (canonicalizePath exe) :: IO (Either SomeException FilePath)
      pure (takeDirectory (either (const exe) id real))

-- the path under home when the file is there, else Nothing
underHome :: FilePath -> IO (Maybe FilePath)
underHome rel = do
  h <- fprHome
  let p = h </> rel
  ok <- doesFileExist p
  pure (if ok then Just p else Nothing)
