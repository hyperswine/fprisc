-- Build the shared codegen dependency graph once for all frame oracles.
module Main (main) where
import qualified EmitA64Frames as A64
import qualified EmitX64Frames as X64
import qualified EmitRVFrames as RV
import System.Environment (getArgs, withArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    "a64":rest -> withArgs rest A64.main
    "x64":rest -> withArgs rest X64.main
    "rv":rest -> withArgs rest RV.main
    _ -> error "usage: frame-emitters {a64|x64|rv} ..."
