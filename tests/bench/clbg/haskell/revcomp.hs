-- Benchmarks Game reverse-complement, single-threaded.
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Builder (Builder, byteString, char7, hPutBuilder)
import Data.Char (toUpper)
import System.Environment (getArgs)
import System.IO (stdout)

complementTable :: B.ByteString
complementTable = B.pack [ comp (toEnum i) | i <- [0 .. 255 :: Int] ]
  where
    pairs = zip "ACGTUMRWSYKVHDBN" "TGCAAKYWSRMBDHVN"
    comp c = maybe c id (lookup (toUpper c) pairs)

complement :: Char -> Char
complement c = B.index complementTable (fromEnum c)

-- | Splits the file into (header, sequence lines) records.
records :: [B.ByteString] -> [(B.ByteString, [B.ByteString])]
records (h : rest) | B.isPrefixOf (B.pack ">") h =
  let (body, more) = break (B.isPrefixOf (B.pack ">")) rest
  in (h, body) : records more
records (_ : rest) = records rest
records [] = []

lines60 :: B.ByteString -> Builder
lines60 s
  | B.null s = mempty
  | otherwise = let (a, b) = B.splitAt 60 s in byteString a <> char7 '\n' <> lines60 b

main :: IO ()
main = do
  args <- getArgs
  let path = case args of (p:_) -> p; [] -> "data/fasta-2500000.txt"
  contents <- B.readFile path
  hPutBuilder stdout $ mconcat
    [ byteString h <> char7 '\n' <> lines60 (B.map complement (B.reverse (B.concat body)))
    | (h, body) <- records (B.lines contents) ]
