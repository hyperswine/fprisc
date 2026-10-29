-- Script output belongs to the program; host diagnostics belong to stderr.
module Sol.Diagnostic (diagnostic, verbose, withBufferedDiagnostics) where

import Control.Exception (onException)
import Control.Monad (when)
import Data.IORef
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

-- While a compile is a TRIAL (the sliced-prelude attempt, Sol.Slice), its
-- diagnostics are held back: a trial that fails is retried with the full
-- prelude, and only that compile's diagnostics may reach the user.
diagnosticBuffer :: IORef (Maybe [String])
diagnosticBuffer = unsafePerformIO (newIORef Nothing)
{-# NOINLINE diagnosticBuffer #-}

diagnostic :: String -> IO ()
diagnostic msg = do
  buffering <- readIORef diagnosticBuffer
  case buffering of
    Just held -> writeIORef diagnosticBuffer (Just (msg : held))
    Nothing -> hPutStrLn stderr msg

-- Run an action with diagnostics held. Returns the result and the held
-- lines (in order); on an exception the held lines are dropped.
withBufferedDiagnostics :: IO a -> IO (a, [String])
withBufferedDiagnostics action = do
  writeIORef diagnosticBuffer (Just [])
  r <- action `onException` writeIORef diagnosticBuffer Nothing
  held <- readIORef diagnosticBuffer
  writeIORef diagnosticBuffer Nothing
  pure (r, maybe [] reverse held)

verbose :: String -> IO ()
verbose msg = do
  enabled <- (== Just "1") <$> lookupEnv "SOL_VERBOSE"
  when enabled (diagnostic msg)
