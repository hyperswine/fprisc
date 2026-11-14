-- Benchmarks Game fasta, single-threaded.
{-# LANGUAGE BangPatterns #-}
import qualified Data.ByteString.Char8 as B
import Data.List (scanl')
import System.Environment (getArgs)
import System.IO (stdout, hSetBuffering, BufferMode (BlockBuffering))

alu :: B.ByteString
alu = B.pack
  "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGG\
  \TCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCG\
  \GGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG\
  \AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTC\
  \TCAAAAA"

iub, homosapiens :: [(Char, Double)]
iub = [ ('a', 0.27), ('c', 0.12), ('g', 0.12), ('t', 0.27)
      , ('B', 0.02), ('D', 0.02), ('H', 0.02), ('K', 0.02), ('M', 0.02)
      , ('N', 0.02), ('R', 0.02), ('S', 0.02), ('V', 0.02), ('W', 0.02)
      , ('Y', 0.02) ]
homosapiens = [ ('a', 0.3029549426680), ('c', 0.1979883004921)
              , ('g', 0.1975473066391), ('t', 0.3015094502008) ]

width :: Int
width = 60

repeatFasta :: String -> B.ByteString -> Int -> IO ()
repeatFasta header src n = do
  B.putStrLn (B.pack header)
  let len = B.length src
      src2 = src <> B.take width src
      go !k !left
        | left <= 0 = return ()
        | otherwise = do
            let l = min width left
            B.putStrLn (B.take l (B.drop k src2))
            go ((k + l) `mod` len) (left - l)
  go 0 n

-- | Writes the sequence and returns the generator's seed afterwards.
randomFasta :: String -> [(Char, Double)] -> Int -> Int -> IO Int
randomFasta header table n seed0 = do
  B.putStrLn (B.pack header)
  let cum = zip (map fst table) (drop 1 (scanl' (+) 0 (map snd table)))
      pick r = go cum
        where go [(c, _)] = c
              go ((c, p) : rest) = if p > r then c else go rest
              go [] = error "empty table"
      step s = let s' = (s * 3877 + 29573) `mod` 139968
               in Just (pick (fromIntegral s' / 139968.0), s')
      go !seed !left
        | left <= 0 = return seed
        | otherwise = do
            let l = min width left
                (line, Just seed') = B.unfoldrN l step seed
            B.putStrLn line
            go seed' (left - l)
  go seed0 n

main :: IO ()
main = do
  args <- getArgs
  let n = case args of (s:_) -> read s; [] -> 2500000
  hSetBuffering stdout (BlockBuffering (Just 65536))
  repeatFasta ">ONE Homo sapiens alu" alu (2 * n)
  s <- randomFasta ">TWO IUB ambiguity codes" iub (3 * n) 42
  _ <- randomFasta ">THREE Homo sapiens frequency" homosapiens (5 * n) s
  return ()
