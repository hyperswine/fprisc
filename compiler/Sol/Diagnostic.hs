-- Script output belongs to the program; host diagnostics belong to stderr.
module Sol.Diagnostic (diagnostic, verbose) where

import Control.Monad (when)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

diagnostic :: String -> IO ()
diagnostic = hPutStrLn stderr

verbose :: String -> IO ()
verbose msg = do
  enabled <- (== Just "1") <$> lookupEnv "SOL_VERBOSE"
  when enabled (diagnostic msg)
