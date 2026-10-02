-- Manifest.hs -- a TARGET manifest: the assumptions that turn abstract
-- costs into time (docs/2026-10-02-RESOURCE-BOUNDS.md, stage 3).
--
-- A manifest names the three versions a judgement is made against and
-- binds what the cost pass cannot know from the program:
--
--     name       pi4-qos-v2
--     compiler   edfbaac
--     runtime    3c02b82
--     hardware   "Raspberry Pi 4, 1.5 GHz, one hart"
--     ns_per_op  1.3                 worst-case nanoseconds per abstract op
--     coefficient omega 12           a named coefficient a bound may use
--     primitive  print 2000 0        a primitive's work and alloc bytes
--     budget     main 5ms            a function's time budget
--     assume     "no cache model; single hart; no interrupts"
--
-- One key per line, `#` comments, quoted strings for free text.  Nothing
-- here is measured by the compiler: a manifest is a document someone
-- signs, and the report prints its name and assumptions beside every
-- number it produced.
module Manifest (Manifest (..), readManifest, parseManifest, renderNs, parseDuration) where

import Data.Char (isSpace)
import Data.List (dropWhileEnd, isPrefixOf)
import qualified Data.Map.Strict as M
import Data.Ratio (denominator, numerator, (%))

data Manifest = Manifest
  { mName :: String,
    mCompiler :: String,
    mRuntime :: String,
    mHardware :: String,
    mNsPerOp :: Rational,
    mCoefs :: M.Map String Integer,
    mPrims :: M.Map String (Integer, Integer), -- work, alloc bytes
    mBudgets :: M.Map String Rational, -- nanoseconds
    mAssume :: [String]
  }
  deriving (Show)

empty :: Manifest
empty = Manifest "" "" "" "" 0 M.empty M.empty M.empty []

readManifest :: FilePath -> IO (Either String Manifest)
readManifest path = parseManifest path <$> readFile path

parseManifest :: FilePath -> String -> Either String Manifest
parseManifest path src = do
  m <- foldl step (Right empty) (zip [1 :: Int ..] (lines src))
  if mNsPerOp m <= 0
    then Left (path ++ ": a manifest needs `ns_per_op <positive number>`")
    else if null (mName m) then Left (path ++ ": a manifest needs a `name`") else Right m
  where
    step acc (ln, raw) = do
      m <- acc
      let s = trim (takeWhile (/= '#') raw)
      if null s
        then Right m
        else case words s of
          ["name", v] -> Right m {mName = v}
          ["compiler", v] -> Right m {mCompiler = v}
          ["runtime", v] -> Right m {mRuntime = v}
          ("hardware" : _) -> Right m {mHardware = quoted (drop (length "hardware") s)}
          ["ns_per_op", v] -> (\r -> m {mNsPerOp = r}) <$> number ln v
          ["coefficient", k, v] -> (\n -> m {mCoefs = M.insert k n (mCoefs m)}) <$> integer ln v
          ["primitive", g, w, a] -> (\x y -> m {mPrims = M.insert g (x, y) (mPrims m)}) <$> integer ln w <*> integer ln a
          ["budget", f, d] -> (\ns -> m {mBudgets = M.insert f ns (mBudgets m)}) <$> maybe (Left (at ln ("not a duration: " ++ d ++ " (write 5ms, 250us, 800ns, 1s)"))) Right (parseDuration d)
          ("assume" : _) -> Right m {mAssume = mAssume m ++ [quoted (drop (length "assume") s)]}
          (k : _) -> Left (at ln ("unknown key `" ++ k ++ "` (name, compiler, runtime, hardware, ns_per_op, coefficient, primitive, budget, assume)"))
          [] -> Right m
    at ln msg = path ++ ":" ++ show ln ++ ": " ++ msg
    trim = dropWhileEnd isSpace . dropWhile isSpace
    quoted t = let u = trim t in if length u >= 2 && head u == '"' && last u == '"' then init (tail u) else u
    integer ln v = case reads v of
      [(n, "")] -> Right n
      _ -> Left (at ln ("not an integer: " ++ v))
    number ln v = maybe (Left (at ln ("not a number: " ++ v))) Right (decimal v)

-- "1.3" -> 13/10; "12" -> 12
decimal :: String -> Maybe Rational
decimal v = case break (== '.') v of
  (a, "") -> fromIntegral <$> int a
  (a, '.' : b) | not (null b), all (`elem` "0123456789") b -> do
    ia <- int (if null a then "0" else a)
    ib <- int b
    Just (fromIntegral ia + ib % (10 ^ length b))
  _ -> Nothing
  where
    int s = case reads s :: [(Integer, String)] of
      [(n, "")] -> Just n
      _ -> Nothing

-- "5ms" -> 5e6 ns
parseDuration :: String -> Maybe Rational
parseDuration d =
  let (num, unit) = span (`elem` "0123456789.") d
   in do
        n <- decimal num
        scale <- case unit of
          "ns" -> Just 1
          "us" -> Just 1000
          "µs" -> Just 1000
          "ms" -> Just 1000000
          "s" -> Just 1000000000
          _ -> Nothing
        Just (n * scale)

renderNs :: Rational -> String
renderNs ns
  | ns >= 1000000000 = fmt (ns / 1000000000) ++ " s"
  | ns >= 1000000 = fmt (ns / 1000000) ++ " ms"
  | ns >= 1000 = fmt (ns / 1000) ++ " µs"
  | otherwise = fmt ns ++ " ns"
  where
    fmt r =
      let scaled = round (r * 100) :: Integer
          (w, f) = scaled `divMod` 100
       in if f == 0 then show w else show w ++ "." ++ (if f < 10 then "0" else "") ++ show (stripZero f)
    stripZero f = if f `mod` 10 == 0 then f `div` 10 else f

_unused :: Rational -> (Integer, Integer)
_unused r = (numerator r, denominator r)

_unused2 :: String -> Bool
_unused2 = isPrefixOf ""
