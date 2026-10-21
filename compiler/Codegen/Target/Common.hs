{-# LANGUAGE LambdaCase #-}
-- Shared native output and symbol identity, independent of instruction set.
module Codegen.Target.Common
  ( ObjectFormat (..), NativeFn (..), mangleName, functionSymbol,
    stringLabel, stringObject, stringObjectWidth, rodataDirective, shallowEntry,
    forwardEntry, entrySlot, utf8Bytes ) where
import Codegen.Bounds (Report)
import Codegen.IR (Name)
import qualified Codegen.IR as IR
import Codegen.Frame
import Codegen.Policy (StackPolicy (..))
import Codegen.Selected
import Data.Bits (shiftR, xor, (.&.))
import Data.Char (isAlphaNum, isAscii, ord)
import Data.List (intercalate)
import Data.Word (Word64)
import Numeric (showHex)

-- A forwarding wrapper has no computation between its entry and tail
-- transfer. Re-declare each parameter at the selected entry pseudo: its
-- expansion preserves these registers around slow calls using private
-- frame objects. Allocation can then keep parameters in argument registers
-- on the common path. This is deliberately limited to register arities and
-- excludes self recursion, TLS argument cells, and arbitrary function bodies.
forwardEntry :: Bool -> [Phys] -> IR.Fn -> SFn -> (SFn, [FrameObj])
forwardEntry enabled regs fn sf
  | enabled, [b] <- IR.fnBlocks fn,
    IR.TTailCall callee _ <- IR.bTerm b,
    IR.calleeName callee /= IR.fnName fn,
    all (\(IR.Instr _ op) -> op `elem` [IR.OStackCheck, IR.OSafepoint]) (IR.bInstrs b),
    not (null (sfParams sf)), length (sfParams sf) <= length regs =
      let ps = zip (sfParams sf) regs
          operands = [OV v (Fix p) | (v, p) <- ps]
          preserve (I i) | siOp i == "entry.check.tick" = I i
            {siDefs = operands, siUses = operands,
             siClobbers = filter (`notElem` map snd ps) (siClobbers i)}
          preserve it = it
          slots = [frameObj (entrySlot n) 8 8 Temporary (ty == IR.TVal)
                  | (n, (_, ty)) <- zip [0..] (IR.bParams b)]
       in (sf {sfBody = map preserve (sfBody sf)}, slots)
  | otherwise = (sf, [])

-- Separate from allocation's nonnegative spill IDs and saved-register IDs.
entrySlot :: Int -> Int
entrySlot n = -2000 - n

-- The hosted runtime reserves headroom for one small entry. A small frame
-- which cannot deepen the generated call chain may use that reserve.
-- Decide after allocation/layout (and self-loop formation), never from an
-- estimated frame or assembly text. Tail exits discard this frame first.
-- Unknown/generic calls are safepoints too and conservatively keep checks.
-- Keep clobbers unchanged: this pass does not change allocation assumptions.
shallowEntry :: StackPolicy -> Int -> [Item] -> (Bool, [Item])
shallowEntry policy bytes items
  | policy == StackCheckLegacyShallow, bytes <= 1024,
    not (any deepens items) = (True, concatMap strip items)
  | otherwise = (False, items)
  where
    entry i = siOp i `elem` ["entry.check", "entry.check.tick", "entry.tick"]
    deepens (I i) = not (entry i) && siControl i /= Return
      && any (\c -> callSafepoint c || callTarget c == "fpr_applyN") (siCalls i)
    deepens _ = False
    strip (I i) | siOp i == "entry.check" = []
    strip (I i) | siOp i == "entry.check.tick" =
      [I i {siOp = "entry.tick", siCalls = filter ((/= "fpr_stack_grow") . callTarget) (siCalls i)}]
    strip i = [i]

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
stringObject = stringObjectWidth IR.W64

stringObjectWidth :: IR.Width -> ObjectFormat -> String -> [String]
stringObjectWidth width fmt s =
  let bs = utf8Bytes s
      label = case fmt of MachO -> drop 1 (stringLabel s); ELF -> stringLabel s
   in ["    .balign 8", label ++ ":", "    .long 9000", "    .long 0", (if width == IR.W64 then "    .quad " else "    .long ") ++ show (length bs)]
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

