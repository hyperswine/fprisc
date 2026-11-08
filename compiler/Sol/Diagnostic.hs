-- Script output belongs to the program; host diagnostics belong to stderr.
module Sol.Diagnostic (diagnostic, verbose, withBufferedDiagnostics, tryBufferedDiagnostics) where

import Control.Exception (SomeException, onException, try)
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

-- Like withBufferedDiagnostics, but a FAILING action's held diagnostics
-- come back with the exception: the sliced trial's failure classifier
-- (Sol.Main compilePreparedSession) reads the error text to decide
-- whether the full-compile fallback is needed at all.
tryBufferedDiagnostics :: IO a -> IO (Either (SomeException, [String]) (a, [String]))
tryBufferedDiagnostics action = do
  writeIORef diagnosticBuffer (Just [])
  r <- try action
  held <- readIORef diagnosticBuffer
  writeIORef diagnosticBuffer Nothing
  pure $ case r of
    Left e -> Left (e, maybe [] reverse held)
    Right a -> Right (a, maybe [] reverse held)

verbose :: String -> IO ()
verbose msg = do
  enabled <- (== Just "1") <$> lookupEnv "SOL_VERBOSE"
  when enabled (diagnostic msg)
