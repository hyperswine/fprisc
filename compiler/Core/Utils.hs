module Core.Utils (spineOf, floatLitBits) where
import Core.Syntax

spineOf :: Core -> (Core, [Core])
spineOf = go []
  where
    go acc (CApp f a) = go (a : acc) f
    go acc f = (f, acc)

-- a float LITERAL inside an unboxable body: the desugarer emits
-- f64frombits hi lo (or f32frombits bits) with constant arguments, so
-- it folds to one `li` of the bit pattern.  Without this, any body
-- mentioning 2.0 would fail admission and lose its specialized loop.
floatLitBits :: Core -> Maybe Integer
floatLitBits e = case spineOf e of
  (CVar "f64frombits", [CInt hi, CInt lo]) -> Just ((hi * 4294967296) + (lo `mod` 4294967296))
  (CVar "f32frombits", [CInt b]) -> Just b
  _ -> Nothing

