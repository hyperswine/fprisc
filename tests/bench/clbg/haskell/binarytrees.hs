-- Benchmarks Game binary-trees, single-threaded.
{-# LANGUAGE BangPatterns #-}
-- Without these GHC shares one tree across iterations (full laziness
-- floats make d out of the loop, CSE merges the two children), which
-- the rules forbid: every tree is built node by node.
{-# OPTIONS_GHC -fno-full-laziness -fno-cse #-}
import Data.Bits (shiftL)
import Data.List (foldl')
import System.Environment (getArgs)

data Tree = Nil | Node !Tree !Tree

make :: Int -> Tree
make 0 = Node Nil Nil
make d = Node (make (d - 1)) (make (d - 1))

check :: Tree -> Int
check Nil = 0
check (Node l r) = 1 + check l + check r

main :: IO ()
main = do
  args <- getArgs
  let n = case args of (a:_) -> read a; [] -> 18
      minDepth = 4
      maxDepth = max (minDepth + 2) n
      stretch = maxDepth + 1
  putStrLn $ "stretch tree of depth " ++ show stretch ++ "\t check: " ++ show (check (make stretch))
  let long = make maxDepth
  long `seq` mapM_ (\d -> do
      let iters = 1 `shiftL` (maxDepth - d + minDepth) :: Int
          s = foldl' (\ !acc _ -> acc + check (make d)) 0 [1 .. iters]
      putStrLn $ show iters ++ "\t trees of depth " ++ show d ++ "\t check: " ++ show s)
    [minDepth, minDepth + 2 .. maxDepth]
  putStrLn $ "long lived tree of depth " ++ show maxDepth ++ "\t check: " ++ show (check long)
