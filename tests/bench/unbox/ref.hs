-- unbox bench Haskell references (ghc -O2). argv: mode. Same workloads as the .fpr files.
{-# LANGUAGE BangPatterns #-}
import System.Environment (getArgs)
import Data.List (foldl')
data Tree = Leaf | Node Tree !Int Tree
build :: Int -> Int -> Tree
build 0 _ = Leaf
build d k = Node (build (d-1) (2*k)) k (build (d-1) (2*k+1))
total :: Tree -> Int
total Leaf = 0
total (Node l k r) = total l + k + total r
half :: Int -> Maybe Int
half x = if even x then Just (x `div` 2) else Nothing
{-# NOINLINE rounds #-}
rounds :: Int -> (Int -> Int) -> Int
rounds r f = sum [f i | i <- [1..r]]
main :: IO ()
main = do
  [m] <- getArgs
  let n = 1000000 :: Int
  print $ case m of
    "sum"    -> rounds 20 (\i -> sum [i - i + 1 .. n])
    "map"    -> rounds 20 (\i -> sum (map (+1) [i - i + 1 .. n]))
    "filter" -> rounds 20 (\i -> sum (filter even [i - i + 1 .. n]))
    "fold"   -> let xs = [1..n] in length xs `seq` rounds 20 (\i -> foldl' (\a x -> a + x*3) (i-i) xs)
    "rev"    -> let xs = [1..n] in length xs `seq` rounds 20 (\i -> length (reverse (drop (i-i) xs)))
    "option" -> let go 0 !a = a; go i !a = go (i-1) (maybe (a+1) (a+) (half i)) in go (20000000::Int) 0
    "tuple"  -> let step (a,b) = (b, (a+b) `mod` 1000003)
                    go :: Int -> (Int,Int) -> Int
                    go 0 (a,_) = a; go i p = go (i-1) (step p) in go 20000000 (0,1)
    "tree"   -> rounds 10 (\i -> total (build 20 (i-i+1)))
    _ -> error m
