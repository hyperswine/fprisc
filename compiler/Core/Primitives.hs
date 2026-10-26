module Core.Primitives (corePrims, primArities, scalarPrimitives, uPrims, fPrimsOf, fPrims, FloatWidth(..), floatWidthName,entryTickName) where

-- Compatibility spelling at the erasure boundary; typed Core uses EntryTick.
entryTickName :: String
entryTickName = "$fuel"

data FloatWidth = Float32 | Float64 deriving (Eq, Show)
floatWidthName :: FloatWidth -> String
floatWidthName Float32 = "32"
floatWidthName Float64 = "64"

scalarPrimitives :: [(String,Int)]
scalarPrimitives = [("$scalar."++op,2) | op <- uPrims] ++
                   [("$scalar.unbox",1),("$scalar.box",1),("$scalar.isInt",1)]

corePrims :: [String]
corePrims = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">=", "strcat", "str", "error", "print", "String.len", "!"]


primArities :: [(String, Int)]
primArities = scalarPrimitives ++
  [ ("+", 2), ("-", 2), ("*", 2), ("/", 2),
    ("==", 2), ("!=", 2), ("<", 2), (">", 2), ("<=", 2), (">=", 2),
    ("strcat", 2), ("str", 1), ("error", 1),
    ("print", 1), ("String.len", 1), ("!", 2),
    -- floats: raw-bits payloads; every op is a C prim the type-directed
    -- site resolution routes to (Infer.hs).  f64frombits is the
    -- literal encoding (a tagged V cannot carry 64 raw bits).
    ("f64frombits", 2), ("f32frombits", 1)
  ]
  ++ [ ("F" ++ w ++ "." ++ op, 2)
       | w <- ["64", "32"], op <- ["+", "-", "*", "/", "<", ">", "<=", ">=", "==", "!="] ]
  ++ [ ("F" ++ w ++ "." ++ f, 1)
       | w <- ["64", "32"],
         f <- ["str", "sqrt", "ofInt", "toInt",
               "log", "log2", "exp", "sin", "cos"] ]
  ++ [ ("F" ++ w ++ ".pow", 2) | w <- ["64", "32"] ]
  ++ [("F64.ofF32", 1), ("F32.ofF64", 1)]
  ++ [("$mem." ++ op ++ width ++ "at", if op == "read" then 2 else 3)
       | op <- ["read", "write"], width <- ["8", "16", "32", "Word"]]

uPrims :: [String]
uPrims = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">="]

-- the same op set at each float width.  An unboxed clone over a FLOAT
-- column gets raw IEEE bits in its integer registers exactly as an Int
-- clone gets raw ints -- identical calling convention, different
-- instructions -- so the whole specialized-loop machinery carries over
-- with only the arithmetic and the rep guard changed.
fPrimsOf :: FloatWidth -> [String]
fPrimsOf w = [ "F" ++ floatWidthName w ++ "." ++ o | o <- uPrims ]

fPrims :: [String]
fPrims = fPrimsOf Float64 ++ fPrimsOf Float32

