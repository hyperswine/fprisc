-- Shared native output and symbol identity, independent of instruction set.
module Codegen.Target.Common
  ( ObjectFormat (..), NativeFn (..), mangleName, functionSymbol ) where
import Codegen.Bounds (Report)
import Codegen.IR (Name)
import Data.Char (isAlphaNum, isAscii, ord)
import Numeric (showHex)

data ObjectFormat = MachO | ELF deriving (Eq, Ord, Show)

data NativeFn = NativeFn
  { nfName :: String,
    nfLines :: [String], -- the assembly, header comment through the bound line
    nfReport :: Report,
    nfNullaries :: [(Int, Int)] -- the unit-local nullary objects referenced
  }

-- the symbol encoding of Codegen.mangle (ASCII alphanumerics stay, every
-- other character is `_xHH`); repeated here so this module needs nothing
-- from the legacy generator
mangleName :: String -> String
mangleName = concatMap enc
  where
    enc c
      | isAscii c && isAlphaNum c = [c]
      | otherwise = "_x" ++ pad (showHex (ord c) "")
    pad s = if length s < 2 then '0' : s else s

functionSymbol :: Name -> String
functionSymbol n = "fpr_fn_" ++ mangleName n

