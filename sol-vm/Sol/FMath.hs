-- Sol.FMath: the native runtime's freestanding transcendentals
-- (runtime/runtime.c, "transcendentals: freestanding, double path"), ported
-- operation for operation so Sol answers bit for bit what native does
-- (core spec Q6). The runtime compiles with FP contraction off, and GHC
-- never fuses, so the same sequence of IEEE operations gives the same bits.
-- Keep the two in step: a change to one kernel changes the other.
module Sol.FMath (flog, flog2, fexp, fpow, fsin, fcos, ftan, fatan, fatan2, fasin, facos, dtoa) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Int (Int64)
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)

ln2hi, ln2lo, invln2 :: Double
ln2hi = 6.93147180369123816490e-01
ln2lo = 1.90821492927058770002e-10
invln2 = 1.44269504088896338700e+00

nan, inf :: Double
nan = 0 / 0
inf = 1 / 0

-- (long long)x and (int)x: truncation toward zero
truncL :: Double -> Int64
truncL = truncate

-- inf or nan
fspec :: Double -> Bool
fspec x = (castDoubleToWord64 x `shiftR` 52) .&. 0x7ff == 0x7ff

signBit :: Double -> Bool
signBit x = castDoubleToWord64 x `shiftR` 63 /= 0

pow2 :: Int64 -> Double
pow2 k = castWord64ToDouble (fromIntegral k `shiftL` 52 :: Word64)

logcore :: Double -> (Double, Int)
logcore x0 =
  let u0 = castDoubleToWord64 x0
      (x1, e0) = if u0 < (1 `shiftL` 52) then (x0 * 9007199254740992.0, -53) else (x0, 0)
      u = castDoubleToWord64 x1
      e1 = e0 + fromIntegral ((u `shiftR` 52) .&. 0x7ff) - 1023
      m0 = castWord64ToDouble ((u .&. 0xfffffffffffff) .|. (1023 `shiftL` 52))
      (m, e) = if m0 > 1.4142135623730951 then (m0 * 0.5, e1 + 1) else (m0, e1)
      t = (m - 1.0) / (m + 1.0)
      t2 = t * t
   in ( t * (1.0 + t2 * (1.0 / 3 + t2 * (1.0 / 5 + t2 * (1.0 / 7 + t2 * (1.0 / 9
          + t2 * (1.0 / 11 + t2 * (1.0 / 13 + t2 * (1.0 / 15 + t2 * (1.0 / 17
          + t2 * (1.0 / 19 + t2 * (1.0 / 21 + t2 * (1.0 / 23))))))))))))
      , e )

flog :: Double -> Double
flog x
  | isNaN x || fspec x = if isNaN x || x > 0 then x else nan
  | x < 0 = nan
  | x == 0 = -inf
  | otherwise = let (s, e) = logcore x in 2.0 * s + fromIntegral e * ln2hi + fromIntegral e * ln2lo

flog2 :: Double -> Double
flog2 x
  | isNaN x || fspec x = if isNaN x || x > 0 then x else nan
  | x < 0 = nan
  | x == 0 = -inf
  | otherwise = let (s, e) = logcore x in fromIntegral e + 2.0 * s * invln2

fexp :: Double -> Double
fexp x
  | isNaN x = x
  | x > 709.782712893384 = inf
  | x < -745.133219101941 = 0
  | otherwise =
      let kd = x * invln2
          k = truncL (kd + (if kd >= 0 then 0.5 else -0.5))
          kf = fromIntegral k :: Double
          r = (x - kf * ln2hi) - kf * ln2lo
          s = 1.0 + r * (1.0 + r * (1.0 / 2 + r * (1.0 / 6 + r * (1.0 / 24
            + r * (1.0 / 120 + r * (1.0 / 720 + r * (1.0 / 5040 + r * (1.0 / 40320
            + r * (1.0 / 362880 + r * (1.0 / 3628800 + r * (1.0 / 39916800
            + r * (1.0 / 479001600 + r * (1.0 / 6227020800.0)))))))))))))
       in if k >= -1021 then s * pow2 (k + 1023) else s * pow2 (k + 1023 + 64) * pow2 (1023 - 64)

-- pow in double-double (runtime.c fpow_ and its helpers, op for op): error-free
-- sums, Dekker products (no FMA), binary powering for an integral exponent
-- below 2^40, and exp/log carried as hi+lo pairs otherwise.
twoSum :: Double -> Double -> (Double, Double)
twoSum a b = let x = a + b; bv = x - a; av = x - bv in (x, (a - av) + (b - bv))

fastTwoSum :: Double -> Double -> (Double, Double)
fastTwoSum a b = let x = a + b in (x, b - (x - a))

-- operands below 2^996 in magnitude
twoProd :: Double -> Double -> (Double, Double)
twoProd a b =
  let x = a * b
      ca = 134217729.0 * a; ah = ca - (ca - a); al = a - ah
      cb = 134217729.0 * b; bh = cb - (cb - b); bl = b - bh
   in (x, ((ah * bh - x) + ah * bl + al * bh) + al * bl)

ddMul :: (Double, Double) -> (Double, Double) -> (Double, Double)
ddMul (ah, al) (bh, bl) = let (p, e) = twoProd ah bh in fastTwoSum p (e + (ah * bl + al * bh))

lowBound, highBound :: Double
lowBound = encodeFloat 1 (-969)
highBound = encodeFloat 1 996

-- x^n for 0 < n < 2^40; Nothing when an intermediate leaves [2^-969, 2^996]
powIntDD :: Double -> Word64 -> Maybe (Double, Double)
powIntDD x = go (1.0, 0.0) (x, 0.0)
  where
    inRange a = a >= lowBound && a < highBound
    go r b n =
      let r' = if n .&. 1 /= 0 then ddMul r b else r
          okR = n .&. 1 == 0 || inRange (abs (fst r'))
          n' = n `shiftR` 1
       in if not okR then Nothing
          else if n' == 0 then Just r'
          else let b' = ddMul b b in if inRange (fst b') then go r' b' n' else Nothing

-- ln x as (hi, lo), x positive and finite
logDD :: Double -> (Double, Double)
logDD x0 =
  let u0 = castDoubleToWord64 x0
      (x1, e0) = if u0 < (1 `shiftL` 52) then (x0 * 9007199254740992.0, -53) else (x0, 0)
      u = castDoubleToWord64 x1
      e1 = e0 + fromIntegral ((u `shiftR` 52) .&. 0x7ff) - 1023 :: Int
      m0 = castWord64ToDouble ((u .&. 0xfffffffffffff) .|. (1023 `shiftL` 52))
      (m, e) = if m0 > 1.4142135623730951 then (m0 * 0.5, e1 + 1) else (m0, e1)
      f = m - 1.0
      (d, dl) = twoSum m 1.0
      t = f / d
      (p, pe) = twoProd t d
      tl = (((f - p) - pe) - t * dl) / d
      t2 = t * t
      r = 2.0 * (t * t2 * (1.0 / 3 + t2 * (1.0 / 5 + t2 * (1.0 / 7 + t2 * (1.0 / 9
            + t2 * (1.0 / 11 + t2 * (1.0 / 13 + t2 * (1.0 / 15 + t2 * (1.0 / 17
            + t2 * (1.0 / 19 + t2 * (1.0 / 21 + t2 * (1.0 / 23))))))))))))
      ed = fromIntegral e :: Double
      (s, se) = twoSum (ed * ln2hi) (2.0 * t)
   in fastTwoSum s (se + (ed * ln2lo + (2.0 * tl + r)))

-- exp (hi + lo), lo below an ulp of hi
expDD :: Double -> Double -> Double
expDD x lo
  | x > 709.782712893384 = inf
  | x < -745.133219101941 = 0
  | otherwise =
      let kd = x * invln2
          k = truncL (kd + (if kd >= 0 then 0.5 else -0.5))
          kf = fromIntegral k :: Double
          r = ((x - kf * ln2hi) + lo) - kf * ln2lo
          s = 1.0 + r * (1.0 + r * (1.0 / 2 + r * (1.0 / 6 + r * (1.0 / 24
            + r * (1.0 / 120 + r * (1.0 / 720 + r * (1.0 / 5040 + r * (1.0 / 40320
            + r * (1.0 / 362880 + r * (1.0 / 3628800 + r * (1.0 / 39916800
            + r * (1.0 / 479001600 + r * (1.0 / 6227020800.0)))))))))))))
       in if k >= -1021 then s * pow2 (k + 1023) else s * pow2 (k + 1023 + 64) * pow2 (1023 - 64)

-- |x|^y for positive finite x /= 1 and finite y
powPos :: Double -> Double -> Double
powPos x y =
  let (hi, lo) = logDD x
      ph = y * hi
   in if not (ph < 800.0 && ph > -800.0) then fexp ph
      else let (p, pe) = twoProd y hi in expDD p (pe + y * lo)

fpow :: Double -> Double -> Double
fpow x y
  | y == 0 = 1
  | isNaN x || isNaN y = nan
  | x == 1 = 1
  | x == 0 = if y > 0 then 0 else inf
  | fspec x || fspec y = fexp (y * flog (abs x))
  | otherwise =
      let ay = abs y
          big = ay >= 9007199254740992.0
          integral = big || fromIntegral (truncL y) == y
          odd' = not big && integral && odd (truncL y)
          viaInt =
            if integral && ay < encodeFloat 1 40
              then case powIntDD x (fromIntegral (truncL ay)) of
                Just (h, l)
                  | y > 0 -> Just (h + l)
                  | otherwise ->
                      let q = 1.0 / h
                          (p, pe) = twoProd h q
                          rm = ((1.0 - p) - pe) - l * q
                       in Just (q + rm * q)
                Nothing -> Nothing
              else Nothing
       in case viaInt of
            Just v -> v
            Nothing
              | x < 0 -> if not integral then nan else let r = powPos (negate x) y in if odd' then negate r else r
              | otherwise -> powPos x y

-- two-word Cody-Waite pi/2 reduction: (quadrant, r), or Nothing past the v1 range
rempio2 :: Double -> Maybe (Int64, Double)
rempio2 x0
  | x0 > 1.0e15 || x0 < -1.0e15 = Nothing
  | otherwise =
      let x = if x0 > 1.073741824e9 || x0 < -1.073741824e9
                then x0 - fromIntegral (truncL (x0 * 1.59154943091895345608e-01)) * 6.28318530717958647693e+00
                else x0
          nd = x * 6.36619772367581382433e-01
          nl = truncL (nd + (if nd >= 0 then 0.5 else -0.5))
          n = fromIntegral nl :: Double
          r = (x - n * 1.57079632673412561417e+00) - n * 6.07710050650619224932e-11
       in Just (nl .&. 3, r)

ksin :: Double -> Double
ksin r =
  let r2 = r * r
   in r * (1.0 + r2 * ((-1.0) / 6 + r2 * (1.0 / 120 + r2 * ((-1.0) / 5040
        + r2 * (1.0 / 362880 + r2 * ((-1.0) / 39916800 + r2 * (1.0 / 6227020800.0
        + r2 * ((-1.0) / 1307674368000.0 + r2 * (1.0 / 355687428096000.0)))))))))

kcos :: Double -> Double
kcos r =
  let r2 = r * r
   in 1.0 + r2 * ((-1.0) / 2 + r2 * (1.0 / 24 + r2 * ((-1.0) / 720
        + r2 * (1.0 / 40320 + r2 * ((-1.0) / 3628800 + r2 * (1.0 / 479001600.0
        + r2 * ((-1.0) / 87178291200.0 + r2 * (1.0 / 20922789888000.0))))))))

reduced :: (Int64 -> Double -> Double) -> Double -> Double
reduced k x
  | isNaN x || fspec x = nan
  | otherwise = maybe nan (uncurry k) (rempio2 x)

fsin, fcos, ftan :: Double -> Double
fsin = reduced $ \q r -> case q of 0 -> ksin r; 1 -> kcos r; 2 -> negate (ksin r); _ -> negate (kcos r)
fcos = reduced $ \q r -> case q of 0 -> kcos r; 1 -> negate (ksin r); 2 -> negate (kcos r); _ -> ksin r
ftan = reduced $ \q r -> if odd q then negate (kcos r) / ksin r else ksin r / kcos r

fatan :: Double -> Double
fatan x0
  | isNaN x0 = x0
  | x0 == 0 = x0
  | otherwise =
      let neg = x0 < 0
          x1 = if neg then negate x0 else x0
          pio2 = 1.57079632679489661923
          pio4 = 7.85398163397448309616e-01
          morebits = 6.123233995736765886130e-17
       in if x1 == inf then (if neg then negate pio2 else pio2) else
            let (y, flag, x)
                  | x1 > 2.41421356237309504880 = (pio2, 1 :: Int, (-1.0) / x1)
                  | x1 <= 0.66 = (0, 0, x1)
                  | otherwise = (pio4, 2, (x1 - 1.0) / (x1 + 1.0))
                z0 = x * x
                z1 = z0 * ((((-8.750608600031904122785e-01 * z0 + (-1.615753718733365076637e+01)) * z0
                       + (-7.500855792314704667340e+01)) * z0 + (-1.228866684490136173410e+02)) * z0
                       + (-6.485021904942025371773e+01))
                       / (((((z0 + 2.485846490142306297962e+01) * z0 + 1.650270098316988542046e+02) * z0
                       + 4.328810604912902668951e+02) * z0 + 4.853903996359136964868e+02) * z0
                       + 1.945506571482613964425e+02)
                z2 = x * z1 + x
                z3 = case flag of 2 -> z2 + 0.5 * morebits; 1 -> z2 + morebits; _ -> z2
                r = y + z3
             in if neg then negate r else r

fatan2 :: Double -> Double -> Double
fatan2 y x
  | isNaN x || isNaN y = nan
  | x == 0 =
      if y == 0 then (if signBit x then (if signBit y then negate pi' else pi') else y)
        else if y > 0 then pio2 else negate pio2
  | otherwise =
      let a = fatan (y / x)
       in if x > 0 then a else if signBit y then a - pi' else a + pi'
  where
    pi' = 3.14159265358979323846
    pio2 = 1.57079632679489661923

fasin, facos :: Double -> Double
fasin x
  | isNaN x || x > 1 || x < -1 = nan
  | otherwise = fatan2 x (sqrt ((1.0 - x) * (1.0 + x)))
facos x
  | isNaN x || x > 1 || x < -1 = nan
  | otherwise = fatan2 (sqrt ((1.0 - x) * (1.0 + x))) x

-- runtime.c's dtoa, step for step (F64.str with 15 significant digits, F32.str
-- with 7): sign, NaN and Inf, zero; fixed point for 1e-4 <= |x| < 9.2e18,
-- exponent form outside; trailing zeros trimmed. Not shortest round trip.
dtoa :: Double -> Int -> String
dtoa x0 sig0
  | isNaN x0 = "NaN"
  | otherwise =
      let neg = x0 < 0 || (x0 == 0 && isNegativeZero x0)
          x1 = if neg then negate x0 else x0
          sign = if neg then "-" else ""
       in if x1 > 1.7e308 then sign ++ "Inf"
          else if x1 == 0 then sign ++ "0"
          else
            let (x, e10) = if x1 >= 9.2e18 || x1 < 1e-4 then norm x1 0 else (x1, 0 :: Int)
                ip = truncate x :: Integer
                fr0 = x - fromIntegral ip
                intDigits = show ip
                digs = if ip == 0 then 0 else length intDigits
                sig = sig0 - min digs sig0
                fracDigits = if fr0 > 0 && sig > 0 then frac fr0 sig else ""
                trimmed = reverse (dropWhile (== '0') (reverse fracDigits))
                body = intDigits ++ (if null trimmed then "" else '.' : trimmed)
             in sign ++ body ++ (if e10 /= 0 then 'e' : show e10 else "")
  where
    norm v e
      | v >= 10.0 = norm (v / 10.0) (e + 1)
      | v < 1.0 = norm (v * 10.0) (e - 1)
      | otherwise = (v, e)
    frac :: Double -> Int -> String
    frac fr k
      | k <= 0 = ""
      | otherwise =
          let f = fr * 10.0
              d = min 9 (truncate f :: Int)
              rest = f - fromIntegral d
           in toEnum (fromEnum '0' + d) : (if rest <= 0 then "" else frac rest (k - 1))
