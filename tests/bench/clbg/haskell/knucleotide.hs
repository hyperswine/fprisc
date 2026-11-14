-- Benchmarks Game k-nucleotide, single-threaded.
-- A k-mer over ACGT is packed into an Int, 2 bits a base, as the key of a
-- strict IntMap; one map is built per length.
{-# LANGUAGE BangPatterns #-}
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString.Char8 as B
import Data.Char (toUpper)
import qualified Data.IntMap.Strict as M
import Data.List (sortBy)
import Data.Ord (comparing, Down (..))
import System.Environment (getArgs)

code :: Char -> Int
code 'A' = 0
code 'C' = 1
code 'G' = 2
code 'T' = 3
code _ = 0

countKmers :: B.ByteString -> Int -> M.IntMap Int
countKmers sq k = go (k - 1) start M.empty
  where
    mask = (1 `shiftL` (2 * k)) - 1
    len = B.length sq
    start = B.foldl' (\acc c -> acc `shiftL` 2 .|. code c) 0 (B.take (k - 1) sq)
    go !i !key !m
      | i >= len = m
      | otherwise =
          let key' = (key `shiftL` 2 .|. code (B.index sq i)) .&. mask
          in go (i + 1) key' (M.insertWith (+) key' 1 m)

decode :: Int -> Int -> String
decode k key = [ "ACGT" !! ((key `shiftR` (2 * (k - 1 - i))) .&. 3) | i <- [0 .. k - 1] ]

encode :: String -> Int
encode = foldl (\acc c -> acc `shiftL` 2 .|. code c) 0

frequencies :: B.ByteString -> Int -> [String]
frequencies sq k =
  [ s ++ " " ++ showFixed 3 (100.0 * fromIntegral c / total) | (s, c) <- sorted ] ++ [""]
  where
    total = fromIntegral (B.length sq - k + 1) :: Double
    sorted = sortBy (comparing (\(s, c) -> (Down c, s)))
               [ (decode k key, c) | (key, c) <- M.toList (countKmers sq k) ]

specific :: B.ByteString -> String -> String
specific sq s = show (M.findWithDefault 0 (encode s) (countKmers sq (length s))) ++ "\t" ++ s

main :: IO ()
main = do
  args <- getArgs
  let path = case args of (p:_) -> p; [] -> "data/fasta-1000000.txt"
  contents <- B.readFile path
  let ls = drop 1 (dropWhile (not . B.isPrefixOf (B.pack ">THREE")) (B.lines contents))
      sq = B.map toUpper (B.concat (takeWhile (not . B.isPrefixOf (B.pack ">")) ls))
  mapM_ putStrLn (frequencies sq 1 ++ frequencies sq 2)
  mapM_ (putStrLn . specific sq)
    ["GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"]

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
