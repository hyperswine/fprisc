{-# LANGUAGE LambdaCase #-}
-- Shared native output and symbol identity, independent of instruction set.
module Codegen.Target.Common
  ( ObjectFormat (..), NativeFn (..), mangleName, functionSymbol,
    stringLabel, stringObject, rodataDirective ) where
import Codegen.Bounds (Report)
import Codegen.IR (Name)
import Data.Bits (shiftR, xor, (.&.))
import Data.Char (isAlphaNum, isAscii, ord)
import Data.List (intercalate)
import Data.Word (Word64)
import Numeric (showHex)

data ObjectFormat = MachO | ELF deriving (Eq, Ord, Show)

data NativeFn = NativeFn
  { nfName :: String,
    nfLines :: [String], -- the assembly, header comment through the bound line
    nfReport :: Report,
    nfNullaries :: [(Int, Int)], -- the unit-local nullary objects referenced
    nfStrings :: [String] -- the string literals referenced (an unreachable arm's reason); the unit emits one object per distinct text, `stringLabel`
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

-- the unit-local label of a string literal the native text names: by the
-- text's FNV-1a hash, so two functions naming one text share one object
-- (Codegen dedupes by label); `.L` becomes the Mach-O private prefix in the
-- target's gsym
stringLabel :: String -> String
stringLabel s = ".Ltirstr_" ++ showHex (foldl step 14695981039346656037 (utf8Bytes s)) ""
  where
    step :: Word64 -> Int -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211

-- a String object as Codegen.strFor emits it: {tid 9000, var 0, byte length,
-- bytes}, UTF-8 for codepoints from 0x100, raw bytes below (wire data); the
-- label in the format's spelling (Mach-O's private prefix is `L`)
stringObject :: ObjectFormat -> String -> [String]
stringObject fmt s =
  let bs = utf8Bytes s
      label = case fmt of MachO -> drop 1 (stringLabel s); ELF -> stringLabel s
   in ["    .balign 8", label ++ ":", "    .long 9000", "    .long 0", "    .quad " ++ show (length bs)]
        ++ byteLines bs ++ [""]
  where
    byteLines [] = []
    byteLines xs = let (a, b) = splitAt 16 xs in ("    .byte " ++ intercalate ", " (map show a)) : byteLines b

utf8Bytes :: String -> [Int]
utf8Bytes = concatMap enc
  where
    enc c
      | v < 0x100 = [v]
      | v < 0x800 = [0xC0 + shiftR v 6, 0x80 + (v .&. 0x3F)]
      | v < 0x10000 = [0xE0 + shiftR v 12, 0x80 + (shiftR v 6 .&. 0x3F), 0x80 + (v .&. 0x3F)]
      | otherwise = [0xF0 + shiftR v 18, 0x80 + (shiftR v 12 .&. 0x3F), 0x80 + (shiftR v 6 .&. 0x3F), 0x80 + (v .&. 0x3F)]
      where v = ord c

-- the read-only data section in the target's own syntax (the native text
-- is appended after the legacy lowering and is not translated): Mach-O
-- takes __DATA,__const as the legacy translator does, since the section
-- may hold relocations to code symbols
rodataDirective :: ObjectFormat -> String
rodataDirective = \case
  MachO -> "    .section __DATA,__const"
  ELF -> "    .section .rodata"

