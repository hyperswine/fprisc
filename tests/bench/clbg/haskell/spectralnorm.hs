-- Benchmarks Game spectral-norm, single-threaded.
{-# LANGUAGE BangPatterns #-}
import Data.Array.Unboxed (UArray, listArray, (!))
import System.Environment (getArgs)

type Vec = UArray Int Double

a :: Int -> Int -> Double
a i j = 1.0 / fromIntegral ((i + j) * (i + j + 1) `div` 2 + i + 1)

-- row i of M times v, summed in index order
mulBy :: (Int -> Int -> Double) -> Int -> Vec -> Vec
mulBy m n v = listArray (0, n - 1) [row i 0 0 | i <- [0 .. n - 1]]
  where
    row !i !j !s | j == n = s
                 | otherwise = row i (j + 1) (s + m i j * v ! j)

av, atv, atav :: Int -> Vec -> Vec
av = mulBy a
atv = mulBy (flip a)
atav n = atv n . av n

main :: IO ()
main = do
  args <- getArgs
  let n = case args of (s:_) -> read s; [] -> 2000
      u0 = listArray (0, n - 1) (replicate n 1.0) :: Vec
      step (u, _) = let v = atav n u in (atav n v, v)
      (u, v) = iterate step (u0, u0) !! 10
      dot p q = go 0 0 where
        go !i !s | i == n = s
                 | otherwise = go (i + 1) (s + p ! i * q ! i)
      vBv = dot u v
      vv = dot v v
  u `seq` putStrLn (showFixed 9 (sqrt (vBv / vv)))

-- | Fixed notation with d decimals, rounded from the exact binary value
-- the way C's printf rounds (ties to even), unlike showFFloat, which
-- rounds the shortest decimal representation.
showFixed :: Int -> Double -> String
showFixed d x = sign ++ ip ++ "." ++ fp
  where
    n = round (abs (toRational x) * 10 ^ d) :: Integer
    sign = if x < 0 || isNegativeZero x then "-" else ""
    s = show n
    padded = replicate (d + 1 - length s) '0' ++ s
    (ip, fp) = splitAt (length padded - d) padded
