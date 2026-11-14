-- Benchmarks Game n-body, single-threaded.
-- Bodies live in one unboxed mutable array, 7 doubles a body:
-- x y z vx vy vz mass.
{-# LANGUAGE BangPatterns #-}
import Control.Monad (forM_, replicateM_)
import Data.Array.IO (IOUArray, newListArray, readArray, writeArray)
import System.Environment (getArgs)

solarMass, daysPerYear :: Double
solarMass = 4 * pi' * pi' where pi' = 3.141592653589793
daysPerYear = 365.24

initial :: [[Double]]
initial =
  [ [0, 0, 0, 0, 0, 0, 1]
  , [ 4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01
    , 1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05
    , 9.54791938424326609e-04 ]
  , [ 8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01
    , -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05
    , 2.85885980666130812e-04 ]
  , [ 1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01
    , 2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05
    , 4.36624404335156298e-05 ]
  , [ 1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01
    , 2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05
    , 5.15138902046611451e-05 ] ]

scale :: [Double] -> [Double]
scale [x, y, z, vx, vy, vz, m] =
  [x, y, z, vx * daysPerYear, vy * daysPerYear, vz * daysPerYear, m * solarMass]
scale _ = error "body"

nb :: Int
nb = 5

type Bodies = IOUArray Int Double

get :: Bodies -> Int -> Int -> IO Double
get a i f = readArray a (7 * i + f)

set :: Bodies -> Int -> Int -> Double -> IO ()
set a i f = writeArray a (7 * i + f)

offsetMomentum :: Bodies -> IO ()
offsetMomentum a = forM_ [3, 4, 5] $ \f -> do
  let go !i !p | i == nb = return p
               | otherwise = do v <- get a i f; m <- get a i 6; go (i + 1) (p + v * m)
  p <- go 0 0
  set a 0 f (-p / solarMass)

energy :: Bodies -> IO Double
energy a = outer 0 0
  where
    outer !i !e
      | i == nb = return e
      | otherwise = do
          [x, y, z, vx, vy, vz, m] <- mapM (get a i) [0 .. 6]
          let e1 = e + 0.5 * m * (vx * vx + vy * vy + vz * vz)
              inner !j !acc
                | j == nb = return acc
                | otherwise = do
                    x2 <- get a j 0; y2 <- get a j 1; z2 <- get a j 2; m2 <- get a j 6
                    let dx = x - x2; dy = y - y2; dz = z - z2
                    inner (j + 1) (acc - m * m2 / sqrt (dx * dx + dy * dy + dz * dz))
          e2 <- inner (i + 1) e1
          outer (i + 1) e2

advance :: Bodies -> Double -> IO ()
advance a dt = do
  forM_ [0 .. nb - 1] $ \i -> forM_ [i + 1 .. nb - 1] $ \j -> do
    x <- get a i 0; y <- get a i 1; z <- get a i 2; m <- get a i 6
    x2 <- get a j 0; y2 <- get a j 1; z2 <- get a j 2; m2 <- get a j 6
    let dx = x - x2; dy = y - y2; dz = z - z2
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt d2)
    vx <- get a i 3; vy <- get a i 4; vz <- get a i 5
    set a i 3 (vx - dx * m2 * mag)
    set a i 4 (vy - dy * m2 * mag)
    set a i 5 (vz - dz * m2 * mag)
    vx2 <- get a j 3; vy2 <- get a j 4; vz2 <- get a j 5
    set a j 3 (vx2 + dx * m * mag)
    set a j 4 (vy2 + dy * m * mag)
    set a j 5 (vz2 + dz * m * mag)
  forM_ [0 .. nb - 1] $ \i -> forM_ [0, 1, 2] $ \f -> do
    p <- get a i f
    v <- get a i (f + 3)
    set a i f (p + dt * v)

main :: IO ()
main = do
  args <- getArgs
  let n = case args of (s:_) -> read s; [] -> 5000000 :: Int
  a <- newListArray (0, 7 * nb - 1) (concatMap scale initial)
  offsetMomentum a
  energy a >>= putStrLn . showFixed 9
  replicateM_ n (advance a 0.01)
  energy a >>= putStrLn . showFixed 9

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
