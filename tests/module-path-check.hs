-- Run with: runghc -icompiler tests/module-path-check.hs
import Home (underHome)
import System.Directory
import System.Environment (setEnv, unsetEnv)
import System.FilePath ((</>), searchPathSeparator)
import System.IO (hClose, openTempFile)
import Control.Exception (bracket)
import Control.Monad (unless)

main :: IO ()
main = bracket acquire removeDirectoryRecursive $ \root -> do
  let home = root </> "home"
      one = root </> "external-one"
      two = root </> "external-two"
  mapM_ (createDirectoryIfMissing True) [home, one, two]
  writeFile (home </> "local.fpr") "home"
  writeFile (one </> "local.fpr") "external"
  writeFile (one </> "shared.fpr") "first"
  writeFile (two </> "shared.fpr") "second"
  setEnv "FPR_HOME" home
  setEnv "FPR_PATH" (one ++ [searchPathSeparator] ++ two)
  check "home precedes extra roots" (Just (home </> "local.fpr")) =<< underHome "local.fpr"
  check "extra roots preserve order" (Just (one </> "shared.fpr")) =<< underHome "shared.fpr"
  check "missing module" Nothing =<< underHome "absent.fpr"
  unsetEnv "FPR_PATH"
  check "no implicit external dependency" Nothing =<< underHome "shared.fpr"
  putStrLn "module search path: OK"
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (p, h) <- openTempFile tmp "fpr-module-path"
      hClose h
      removeFile p
      createDirectory p
      pure p
    check label expected actual = unless (actual == expected) (error (label ++ ": " ++ show actual))
