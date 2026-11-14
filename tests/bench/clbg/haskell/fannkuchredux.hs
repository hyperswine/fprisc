-- Benchmarks Game fannkuch-redux, single-threaded.
{-# LANGUAGE BangPatterns #-}
import Control.Monad (forM_, when)
import Data.Array.IO (IOUArray, newListArray, newArray, readArray, writeArray)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  let n = case args of (a:_) -> read a; [] -> 10 :: Int
  perm1 <- newListArray (0, n - 1) [0 .. n - 1] :: IO (IOUArray Int Int)
  perm  <- newArray (0, n - 1) 0 :: IO (IOUArray Int Int)
  count <- newArray (0, n - 1) 0 :: IO (IOUArray Int Int)
  let fill !r | r == 1 = return 1
              | otherwise = writeArray count (r - 1) r >> fill (r - 1)

      reverseTo !i !j = when (i < j) $ do
        a <- readArray perm i
        b <- readArray perm j
        writeArray perm i b
        writeArray perm j a
        reverseTo (i + 1) (j - 1)

      countFlips !flips = do
        k <- readArray perm 0
        if k == 0 then return flips
                  else reverseTo 0 k >> countFlips (flips + 1)

      -- returns Nothing when all permutations are done, else the new r
      nextPerm !r
        | r == n = return Nothing
        | otherwise = do
            p0 <- readArray perm1 0
            forM_ [0 .. r - 1] $ \i -> readArray perm1 (i + 1) >>= writeArray perm1 i
            writeArray perm1 r p0
            c <- readArray count r
            writeArray count r (c - 1)
            if c - 1 > 0 then return (Just r) else nextPerm (r + 1)

      go !r0 !maxFlips !checksum !permIndex = do
        r <- fill r0
        forM_ [0 .. n - 1] $ \i -> readArray perm1 i >>= writeArray perm i
        flips <- countFlips 0
        let maxFlips' = max maxFlips flips
            checksum' = if even permIndex then checksum + flips else checksum - flips
        next <- nextPerm r
        case next of
          Nothing -> do
            print checksum'
            putStrLn $ "Pfannkuchen(" ++ show n ++ ") = " ++ show maxFlips'
          Just r' -> go r' maxFlips' checksum' (permIndex + 1 :: Int)
  go n 0 0 0
