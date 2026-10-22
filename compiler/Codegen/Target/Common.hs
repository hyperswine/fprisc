{-# LANGUAGE LambdaCase #-}
-- Shared native output and symbol identity, independent of instruction set.
module Codegen.Target.Common
  ( ObjectFormat (..), NativeFn (..), mangleName, functionSymbol,
    stringLabel, stringObject, stringObjectWidth, rodataDirective, shallowEntry,
    forwardEntry, entrySlot, utf8Bytes, shrinkWrap, Tune (..), noTune, dataSyntax ) where
import Codegen.Bounds (Report)
import Codegen.IR (Name)
import qualified Codegen.IR as IR
import Codegen.Frame
import Codegen.Policy (StackPolicy (..))
import Codegen.Selected
import Data.Bits (shiftR, xor, (.&.))
import Data.Char (isAlphaNum, isAscii, isDigit, ord)
import Data.List (intercalate, isPrefixOf, stripPrefix)
import Data.Word (Word64)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Numeric (showHex)

-- A forwarding wrapper has no computation between its entry and tail
-- transfer. Re-declare each parameter at the selected entry pseudo: its
-- expansion preserves these registers around slow calls using private
-- frame objects. Allocation can then keep parameters in argument registers
-- on the common path. This is deliberately limited to register arities and
-- excludes self recursion, TLS argument cells, and arbitrary function bodies.
--
-- `general` (FPR_TYPED_IR_ENTRY_ARGS, docs/2026-10-22-TYPED-IR-FIB.md)
-- applies the same preservation to every function whose parameters all
-- arrive in registers: on the common path the entry's runtime calls do not
-- happen, so nothing forces a parameter into a callee-saved register just
-- to survive them; only the slow paths park and reload.
forwardEntry :: Bool -> Bool -> [Phys] -> IR.Fn -> SFn -> (SFn, [FrameObj])
forwardEntry enabled general regs fn sf
  | wrapper || general,
    not (null (sfParams sf)), length (sfParams sf) <= length regs,
    (b : _) <- [blk | blk <- IR.fnBlocks fn, IR.bId blk == IR.fnEntry fn] =
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
  where
    wrapper = enabled && case IR.fnBlocks fn of
      [b] | IR.TTailCall callee _ <- IR.bTerm b ->
        IR.calleeName callee /= IR.fnName fn
          && all (\(IR.Instr _ op) -> op `elem` [IR.OStackCheck, IR.OSafepoint]) (IR.bInstrs b)
      _ -> False

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
functionSymbol n | Just sym <- stripPrefix "$vkernel:" n = sym
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

-- A unit's data (function-value objects, the module table, strings,
-- floats, nullary objects, the constructor table) in the object format's
-- spelling, for a unit with no legacy code to translate
-- (docs/2026-10-22-TYPED-IR-RETIREMENT.md).  ELF data needs no change on
-- AArch64 or x86-64.  Mach-O needs exactly the legacy A64 translator's
-- data rules (A64.macLine and its post pass): a leading underscore on a
-- C-visible symbol in `.globl`, `.quad` and a label definition, `L` for a
-- `.L` local label, and `__DATA,__const` for `.rodata` (the section holds
-- relocations to code, which ld64 refuses in __TEXT).
dataSyntax :: ObjectFormat -> [String] -> [String]
dataSyntax ELF = id
dataSyntax MachO = map (locals . line)
  where
    line l
      | Just rest <- stripPrefix "    .globl " l = "    .globl " ++ intercalate ", " (map (sym . trim) (splitC rest))
      | Just rest <- stripPrefix "    .quad " l, (c : _) <- dropWhile (== ' ') rest, not (isDigit c), c /= '-' = "    .quad " ++ sym (trim rest)
      | "    .section .rodata" `isPrefixOf` l = "    .section __DATA,__const"
      | (name, ':' : rest) <- break (== ':') l, not (null name), all (/= ' ') name,
        not ("." `isPrefixOf` name) || ".L" `isPrefixOf` name = sym name ++ ":" ++ rest
      | otherwise = l
    sym s = if ".L" `isPrefixOf` s then s else '_' : s
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse
    splitC t = case break (== ',') t of
      (x, []) -> [x]
      (x, _ : r) -> x : splitC r
    -- the post pass: every ".L" becomes "L" (labels and references alike)
    locals [] = []
    locals ('.' : 'L' : r) = 'L' : locals r
    locals (c : r) = c : locals r

-- Shrink-wrapping (FPR_TYPED_IR_SHRINK_WRAP, docs/2026-10-22-TYPED-IR-FIB.md):
-- the callee-saved registers the allocation uses are saved at the start of
-- the deepest block that dominates every instruction naming one of them,
-- instead of in the prologue, and restored only by the returns that block
-- dominates.  Taken only when that is sound and gains something:
--
--   * the block is not the entry block (nothing would move);
--   * it is on no cycle (a loop back to it would save the function's own
--     values over the caller's);
--   * every return reachable from it is dominated by it (no path leaves
--     the function with a saved register changed but not restored).
--
-- Returns that the block does not dominate never see a saved register
-- changed, so their epilogue skips the restores (`norestore`).  The result
-- marks the save point with a `saves.here` pseudo for the target to expand;
-- Nothing means: keep the prologue saves.
shrinkWrap :: [Phys] -> [Item] -> Maybe [Item]
shrinkWrap saved items
  | null saved = Nothing
  | otherwise = do
      let uses = [bk | (bk, its) <- zip [0 ..] blocks, namesSaved its]
      case uses of
        [] -> Nothing
        _ -> do
          let common = foldr1 S.intersection [doms M.! u | u <- uses]
              point = snd (maximum [(S.size (doms M.! c), c) | c <- S.toList common])
          if point == 0 || S.member point (reach (succs point)) then Nothing else do
            let reachable = S.insert point (reach (succs point))
                exits = [bk | bk <- S.toList reachable, returns (blocks !! bk)]
                mark bk its =
                  let its' = if S.member point (doms M.! bk) then its else map noRestore its
                   in if bk /= point then its' else case its' of
                        (ILabel l : rest) -> ILabel l : I savesHere : rest
                        rest -> I savesHere : rest
            if any (\bk -> not (S.member point (doms M.! bk))) exits then Nothing else
              Just (concat [mark bk its | (bk, its) <- zip [0 ..] blocks])
  where
    savesHere = plain "saves.here" [] []
    savedSet = S.fromList saved
    namesSaved = any (\case I i -> any isSaved (siDefs i ++ siUses i); _ -> False)
    isSaved = \case OP r -> S.member r savedSet; _ -> False
    returns = any (\case I i -> siControl i == Return; _ -> False)
    noRestore = \case
      I i | siControl i == Return -> I i {siNote = "norestore"}
      it -> it
    -- basic blocks: a label starts one, an instruction that transfers ends one
    blocks = split items
    split [] = []
    split xs = let (b, rest) = takeBlock xs in b : split rest
    takeBlock (x : xs) = go [x] xs (ends x)
      where
        go acc rest True = (reverse acc, rest)
        go acc [] _ = (reverse acc, [])
        go acc (y@(ILabel _) : ys) _ = (reverse acc, y : ys)
        go acc (y : ys) _ = go (y : acc) ys (ends y)
    takeBlock [] = ([], [])
    ends = \case I i -> siControl i /= Next; _ -> False
    nblocks = length blocks
    labelBlock = M.fromList [(l, bk) | (bk, ILabel l : _) <- zip [0 ..] blocks]
    succsOf bk its = case reverse its of
      (I i : _) -> case siControl i of
        Next -> [bk + 1 | bk + 1 < nblocks]
        CondTo ls -> [bk + 1 | bk + 1 < nblocks] ++ [t | l <- ls, Just t <- [M.lookup l labelBlock]]
        JumpTo l -> [t | Just t <- [M.lookup l labelBlock]]
        Return -> []
      _ -> [bk + 1 | bk + 1 < nblocks]
    succMap = M.fromList [(bk, succsOf bk its) | (bk, its) <- zip [0 ..] blocks]
    succs bk = M.findWithDefault [] bk succMap
    reach start = goR S.empty start
      where
        goR seen [] = seen
        goR seen (y : ys)
          | S.member y seen = goR seen ys
          | otherwise = goR (S.insert y seen) (succs y ++ ys)
    preds = M.fromListWith (++) [(t, [bk]) | (bk, ts) <- M.toList succMap, t <- ts]
    allBlocks = S.fromList [0 .. nblocks - 1]
    doms = fixDom (M.fromList [(bk, if bk == 0 then S.singleton 0 else allBlocks) | bk <- [0 .. nblocks - 1]])
    fixDom dm =
      let dm' = M.mapWithKey (\bk d -> if bk == 0 then d else case M.findWithDefault [] bk preds of
                  [] -> S.singleton bk
                  ps -> S.insert bk (foldr1 S.intersection [dm M.! q | q <- ps])) dm
       in if dm' == dm then dm else fixDom dm'

-- The fib experiments' switches (docs/2026-10-22-TYPED-IR-FIB.md), each its
-- own cache identity; the link pairs are on unless 0, the rest off.
-- `noTune` is everything off (the tests' explicit baseline).
data Tune = Tune
  { tuneEntryArgs :: Bool, -- FPR_TYPED_IR_ENTRY_ARGS: parameters stay in their registers through the entry
    tuneShrinkWrap :: Bool, -- FPR_TYPED_IR_SHRINK_WRAP: callee saves at a dominating, acyclic block
    tuneLinkPairs :: Bool -- FPR_TYPED_IR_LINK_PAIRS (on unless 0): the frame link as one stp/ldp
  }
  deriving (Eq, Show)

noTune :: Tune
noTune = Tune False False False
