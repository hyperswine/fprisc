-- Optional phase wall times. Force results at boundaries so Haskell laziness
-- cannot charge type checking or lowering to the first VM instruction.
module Sol.Startup (phase, phaseIO) where

import Control.DeepSeq (NFData, force)
import Control.Exception (evaluate)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (lookupEnv)
import Text.Printf (printf)
import Sol.Diagnostic (diagnostic)

phase :: NFData a => String -> IO a -> IO a
phase name action = do
  enabled <- (== Just "1") <$> lookupEnv "SOL_TIMINGS"
  if not enabled then action else do
    start <- getMonotonicTimeNSec
    result <- action >>= evaluate . force
    end <- getMonotonicTimeNSec
    diagnostic (printf "[sol timing] %s: %.3f ms" name (fromIntegral (end - start) / 1e6 :: Double))
    pure result

-- For completed I/O operations such as commit, whose work is performed before
-- returning. Unlike phase this does not force a pure result's internal fields.
phaseIO :: String -> IO a -> IO a
phaseIO name action = do
  enabled <- (== Just "1") <$> lookupEnv "SOL_TIMINGS"
  if not enabled then action else do
    start <- getMonotonicTimeNSec
    result <- action
    end <- getMonotonicTimeNSec
    diagnostic (printf "[sol timing] %s: %.3f ms" name (fromIntegral (end - start) / 1e6 :: Double))
    pure result
