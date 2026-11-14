-- Benchmarks Game mandelbrot, single-threaded.
{-# LANGUAGE BangPatterns #-}
import Data.Bits (shiftL, (.|.))
import Data.ByteString.Builder (Builder, hPutBuilder, string7, word8)
import Data.Word (Word8)
import System.Environment (getArgs)
import System.IO (stdout)

inSet :: Double -> Double -> Bool
inSet cr ci = go 0 0 0 0 0
  where
    go :: Int -> Double -> Double -> Double -> Double -> Bool
    go !i !zr !zi !tr !ti
      | i == 50 || tr + ti > 4.0 = tr + ti <= 4.0
      | otherwise =
          let zi' = 2.0 * zr * zi + ci
              zr' = tr - ti + cr
          in go (i + 1) zr' zi' (zr' * zr') (zi' * zi')

main :: IO ()
main = do
  args <- getArgs
  let n = case args of (s:_) -> read s; [] -> 4000 :: Int
      fn = fromIntegral n :: Double
      pixel ci x = inSet (2.0 * fromIntegral x / fn - 1.5) ci
      -- byte starting at pixel x0, padded with 0 bits past the row end
      byte ci x0 = go x0 (0 :: Word8)
        where go !x !acc
                | x == x0 + 8 = acc
                | x < n && pixel ci x = go (x + 1) (acc `shiftL` 1 .|. 1)
                | otherwise = go (x + 1) (acc `shiftL` 1)
      row y = let ci = 2.0 * fromIntegral y / fn - 1.0
              in mconcat [word8 (byte ci x0) | x0 <- [0, 8 .. n - 1]]
      image :: Builder
      image = string7 ("P4\n" ++ show n ++ " " ++ show n ++ "\n")
              <> mconcat (map row [0 .. n - 1])
  hPutBuilder stdout image
