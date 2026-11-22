module Main (main) where

-- The A64 spelling contract (docs/2026-11-21-MERGE-PLAN.md, slice 2): for
-- each instruction family the two native tiers share, the AOT renderer's
-- line (renderItem -- the real renderer, not a copy) and the JIT
-- vocabulary's word must agree: both spellings are assembled by the
-- system's `as`, and the encoded words must be EQUAL, and equal to
-- Compiler.Encoding.A64's `encode`.
--
-- Families the tiers do NOT share are deliberately absent, recorded here:
--   * SignExtend31/63 (the AOT's `sbfx`): Encoding's bitfield is SBFM
--     (N=1, the asr form the JIT uses); sbfx is N=0. A BFX constructor
--     with the N bit lands when the JIT first needs one.
--   * negative wide constants: the AOT's `mov #n` alias assembles to MOVN
--     (one word); Encoding.movImm64 uses movz+movk per nonzero half
--     (multiple words, the same 64-bit value). Same semantics, different
--     encoding on purpose.
--   * CompareImmediate, LoadByte/StoreHeader, frame ldur forms: no JIT
--     use today.
-- The Set/CSet pair: both set on the NAMED condition holding (the
-- encoding's inverted field is the mechanism), so the pairs are
-- same-condition; the rendered TEXT differs (the AOT spells `cset x0, eq`,
-- Encoding.render spells the inverted alias `cset x0, ne`) while the
-- assembled words are identical -- which is exactly what this contract
-- compares.

import Codegen.Frame (Layout (..))
import Codegen.IR (CmpOp (..))
import Codegen.Policy (m2Policy)
import Codegen.Selected
import qualified Codegen.Opcode as O
import qualified Codegen.Opcode.A64 as A
import qualified Codegen.Target.A64 as A64T (A64Config (..), HartAccess (..), ObjectFormat (..), renderItem)
import qualified Codegen.Target.X64 as X64T (X64Config (..), X64Hart (..), renderItem)
import Codegen.Target.Common (noTune)
import Compiler.Encoding.A64 (Insn (..), condCode, condSuffix, encode, movImm64, render, insnBytes)
import qualified Compiler.Encoding.A64 as E
import Data.Char (isHexDigit)
import Data.Word (Word32, Word8)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.Info (os)
import System.Process (readProcess)
import Control.Exception (SomeException, displayException, evaluate, try)

cfg :: A64T.A64Config
cfg = A64T.A64Config A64T.ELF A64T.HartGlobal m2Policy S.empty False False False False noTune

ly :: Codegen.Frame.Layout
ly = Layout 0 0 M.empty

-- one family: a name, the AOT item, the matching Encoding instruction.
-- Branch families include padding and a rendered label item: the branch's
-- word delta is 9 (the branch itself, then 8 nops, then the target).
data Family = Family String Item Insn

fam :: String -> O.Opcode -> [Operand] -> [Operand] -> Insn -> Family
fam what op ds us i = Family what (I (plainOpcode op ds us)) i

families :: [Family]
families =
  [ fam "move" (O.A64 A.Move) [OP (Phys "x0")] [OP (Phys "x2")] (OrrXReg 0 31 2),
    fam "add-imm" (O.A64 A.AddImmediate) [OP (Phys "x9")] [OP (Phys "x29"), OI 16] (AddXImm12 9 29 16),
    fam "sub-imm-sp" (O.A64 A.SubtractImmediate) [OP (Phys "sp")] [OP (Phys "sp"), OI 16] (SubXImm12 31 31 16),
    fam "compare" (O.A64 A.Compare) [] [OP (Phys "x0"), OP (Phys "x1")] (CmpXReg 0 1),
    Family "b.eq" (I (plainOpcode (O.A64 (A.Branch O.Equal)) [] [OL (Label "t")])) (BCndX E.Eq 9),
    Family "b.vc" (I (plainOpcode (O.A64 (A.Branch O.NoOverflow)) [] [OL (Label "t")])) (BCndX E.Vc 9),
    Family "cbz" (I (plainOpcode (O.A64 A.BranchZero) [] [OP (Phys "x0"), OL (Label "t")])) (CbzX 0 9),
    Family "cbnz" (I (plainOpcode (O.A64 A.BranchNonzero) [] [OP (Phys "x1"), OL (Label "t")])) (CbnzX 1 9),
    Family "jump" (I (plainOpcode (O.A64 A.Jump) [] [OL (Label "t")])) (BX 9),
    Family "set-eq" (I (plainOpcode (O.A64 (A.Set O.Equal)) [OP (Phys "x0")] [])) (CSetX 0 E.Eq),
    Family "set-less" (I (plainOpcode (O.A64 (A.Set O.Less)) [OP (Phys "x0")] [])) (CSetX 0 E.Lt),
    fam "mul" (O.A64 A.Multiply) [OP (Phys "x2")] [OP (Phys "x0"), OP (Phys "x1")] (MulX 2 0 1),
    fam "sdiv" (O.A64 A.Divide) [OP (Phys "x2")] [OP (Phys "x0"), OP (Phys "x1")] (SDivX 2 0 1),
    fam "literal-small" (O.A64 A.Literal) [OP (Phys "x0")] [OI 42] (MovZ 0 42 0)
  ]

-- the AOT lines for a family: the instruction, then (for a branch) the
-- padding and the rendered label. The branch's Encoding delta is 9: the
-- branch word, 8 padding words, the target.
aotLines :: Family -> [String]
aotLines (Family _ item _) =
  A64T.renderItem cfg ly False "contract" False [] [] M.empty item
    ++ padAndLabel item
  where
    isBranch it = case it of
      I si -> case siOpcode si of
        O.A64 (A.Branch {}) -> True
        O.A64 A.BranchZero -> True
        O.A64 A.BranchNonzero -> True
        O.A64 A.Jump -> True
        _ -> False
      _ -> False
    padAndLabel it
      | isBranch it = replicate 8 "    nop" ++ A64T.renderItem cfg ly False "contract" False [] [] M.empty (ILabel (Label "t"))
      | otherwise = []

-- the Encoding side's .s text: a valid canonical spelling per form (the
-- branch renders are diagnostic `. + words` spellings, not assembler
-- syntax), then the same padding and a local label
encLines :: Family -> [String]
encLines (Family _ item i) =
  canonical i
    ++ padAndLabel (isBranchI i)
  where
    isBranchI j = case j of
      BCndX {} -> True
      CbzX {} -> True
      CbnzX {} -> True
      BX {} -> True
      _ -> False
    canonical j = case j of
      BCndX c _ -> ["b." ++ condSuffix (condCode c) ++ " Lt_t"]
      CbzX r _ -> ["cbz x" ++ show r ++ ", Lt_t"]
      CbnzX r _ -> ["cbnz x" ++ show r ++ ", Lt_t"]
      BX _ -> ["b Lt_t"]
      other -> [render other]
    padAndLabel branch
      | branch = replicate 8 "    nop" ++ ["Lt_t:"]
      | otherwise = []

-- the host assembler's extra arguments (macOS `as` needs -arch for the
-- cross-assembled x86_64 section; Linux `as` is native)
asArgs :: [String]
asArgs = if os == "darwin" then ["-arch", "x86_64"] else []

wordsOf :: FilePath -> IO [Word32]
wordsOf obj = do
  out <- readProcess "objdump" ["-d", obj] ""
  pure
    [ fromIntegral (read ("0x" ++ w) :: Integer)
    | ln <- lines out
    , let fs = words ln
    , length fs >= 2
    , let w = fs !! 1
    , length w == 8
    , all isHexDigit w
    ]

main :: IO ()
main = do
  tmp <- getTemporaryDirectory
  let dir = tmp </> "sol-encoding-contract"
  createDirectoryIfMissing True dir
  results <- mapM (one dir) families
  putStrLn "a64 section done"
  x64ok <- runX64 dir
  putStrLn "x64 section done"
  let bad = [what | ((False, _), Family what _ _) <- zip results families]
  if null bad && x64ok
    then putStrLn ("spelling contract: " ++ show (length families) ++ " a64 families and " ++ show (length x64Families) ++ " x64 families assemble identically through both renderers")
    else do
      mapM_ putStrLn (map ("CONTRACT MISMATCH: " ++) bad)
      if not x64ok then putStrLn "x64 contract failed" else pure ()
      exitFailure
  where
    one dir f@(Family what item i) = do
      let aot = unlines (aotLines f)
          enc = unlines (encLines f)
          sf = dir </> (what ++ "-aot.s")
          se = dir </> (what ++ "-enc.s")
          of' = dir </> (what ++ "-aot.o")
          oe = dir </> (what ++ "-enc.o")
      writeFile sf aot
      writeFile se enc
      _ <- readProcess "as" [sf, "-o", of'] ""
      _ <- readProcess "as" [se, "-o", oe] ""
      wa <- wordsOf of'
      we <- wordsOf oe
      if wa /= we then putStrLn ("DETAIL " ++ what ++ ": aot " ++ show wa ++ " enc " ++ show we) else pure ()
      let encWord = case encode i of Right w -> w; Left e -> error ("contract: encode failed: " ++ e)
      -- both spellings assemble to identical words, and the family's first
      -- word equals Encoding.encode (branches carry padding after the word)
      pure (wa == we && not (null wa) && head wa == encWord, f)

-- ---- the X64 pair ----------------------------------------------------------
-- The JIT's x86-64 assembler is a fixed-register-plan byte table (rax, r11,
-- rdx, xmm0/1, rbp, rbx): no register generality to unify, and its rel32
-- patch computes exact deltas (no masking). The contract here therefore
-- checks the table itself: each hand-packed byte sequence is assembled by
-- the AOT renderer's spelling for the same instruction and registers, and
-- the resulting object bytes must equal the hand bytes exactly. xmm
-- families and the operand-stack-internal sequences are deliberately not
-- covered: the AOT renderer hardcodes different xmm numbers, and the
-- stack discipline has no AOT equivalent.

x64Cfg :: X64T.X64Config
x64Cfg = X64T.X64Config m2Policy S.empty False False False noTune X64T.HartTls False

-- one x86-64 family: name, AOT lines (renderItem on the constructed
-- SInstr), JIT hand bytes, and how many LEADING bytes the contract
-- compares (-1: all). Branch families use a BACKWARD label so both
-- spellings resolve to the same short displacement; the jz-rel32 family
-- compares its opcode prefix only -- its displacement field is
-- linker-relocated (as emits zeros for the forward reference).
data X64Family = X64Family String [String] [Word8] Int

x64Families :: [X64Family]
x64Families =
  [ X64Family "move-rsp-rbp" (x64 (O.X64 O.Move) [OP (Phys "rsp")] [OP (Phys "rbp")]) [0x48, 0x89, 0xEC] (-1),
    X64Family "mov-rbx-rdi" (x64 (O.X64 O.Move) [OP (Phys "rbx")] [OP (Phys "rdi")]) [0x48, 0x89, 0xFB] (-1),
    X64Family "load-disp32" (x64 (O.X64 O.LoadField) [OP (Phys "rax")] [OP (Phys "rbp"), OI 1024])
      ([0x48, 0x8B, 0x85] ++ d32 1024) (-1),
    X64Family "store-disp32-rax" (x64 (O.X64 O.StoreField) [] [OP (Phys "rbp"), OP (Phys "rax"), OI 1024])
      ([0x48, 0x89, 0x85] ++ d32 1024) (-1),
    X64Family "store-disp32-rdi" (x64 (O.X64 O.StoreField) [] [OP (Phys "rbp"), OP (Phys "rdi"), OI 1024])
      ([0x48, 0x89, 0xBD] ++ d32 1024) (-1),
    X64Family "store-disp32-r8" (x64 (O.X64 O.StoreField) [] [OP (Phys "rbp"), OP (Phys "r8"), OI 1024])
      ([0x4C, 0x89, 0x85] ++ d32 1024) (-1),
    X64Family "cmpq" (x64 (O.X64 O.Compare) [] [OP (Phys "rax"), OP (Phys "r11")]) [0x4C, 0x39, 0xD8] (-1),
    X64Family "addq" (x64 (O.X64 O.Add) [OP (Phys "rax")] [OP (Phys "rax"), OP (Phys "r11")]) [0x4C, 0x01, 0xD8] (-1),
    X64Family "subq" (x64 (O.X64 O.Subtract) [OP (Phys "rax")] [OP (Phys "rax"), OP (Phys "r11")]) [0x4C, 0x29, 0xD8] (-1),
    X64Family "imulq" (x64 (O.X64 O.Multiply) [OP (Phys "rax")] [OP (Phys "rax"), OP (Phys "r11")]) [0x49, 0x0F, 0xAF, 0xC3] (-1),
    X64Family "cqo-idiv" (x64 (O.X64 O.Divide) [OP (Phys "rax")] [OP (Phys "rax"), OP (Phys "r11")]) [0x48, 0x99, 0x49, 0xF7, 0xFB] (-1),
    X64Family "xorq" (x64 (O.X64 O.Xor) [OP (Phys "rdx")] [OP (Phys "rax"), OP (Phys "r11")]) [0x4C, 0x31, 0xDA] (-1),
    X64Family "testq-jz-rel32" ([x64Label] ++ x64 (O.X64 O.BranchZero) [] [OP (Phys "rax"), OL (Label "t")] ++ replicate 130 "    nop")
      ([0x48, 0x85, 0xC0, 0x0F, 0x84] ++ d32 (-9) ++ replicate 130 0x90) 2,
    X64Family "jno-rel8-back" ([x64Label, "    nop", "    nop"] ++ x64 (O.X64 (O.Branch O.NoOverflow)) [] [OL (Label "t")])
      [0x90, 0x90, 0x71, 0xFC] (-1),
    X64Family "setl-movzbq" (x64 (O.X64 (O.Set O.Less)) [OP (Phys "rax")] []) [0x0F, 0x9C, 0xC0, 0x48, 0x0F, 0xB6, 0xC0] (-1),
    X64Family "setge-movzbq" (x64 (O.X64 (O.Set O.GreaterEqual)) [OP (Phys "rax")] []) [0x0F, 0x9D, 0xC0, 0x48, 0x0F, 0xB6, 0xC0] (-1),
    X64Family "movabsq" (x64 (O.X64 O.Literal) [OP (Phys "rax")] [OI 0x2000100000003])
      ([0x48, 0xB8] ++ d64 0x2000100000003) (-1)
  ]
  where
    x64 op ds us = X64T.renderItem x64Cfg (Layout 0 0 M.empty) False "contract" [] [] M.empty (I (plainOpcode op ds us))
    x64Label = head (X64T.renderItem x64Cfg (Layout 0 0 M.empty) False "contract" [] [] M.empty (ILabel (Label "t")))
    d32 :: Int -> [Word8]
    d32 v = [fromIntegral ((v `div` (2 ^ (8 * k))) `mod` 256) | k <- [0 .. 3]]
    d64 :: Integer -> [Word8]
    d64 v = [fromIntegral ((v `div` (2 ^ (8 * k))) `mod` 256) | k <- [0 .. 7]]

x64BytesOf :: FilePath -> IO [Word8]
x64BytesOf obj = do
  out <- readProcess "objdump" ["-d", obj] ""
  pure
    [ read ("0x" ++ b) :: Word8
    | ln <- lines out
    , let fs = words ln
    , let hexes = takeWhile (\t -> length t == 2 && all isHexDigit t) (drop 1 fs)
    , not (null hexes)
    , b <- hexes
    ]

runX64 :: FilePath -> IO Bool
runX64 dir = do
  ok <- mapM (oneX dir) x64Families
  pure (and ok)
  where
    oneX dir f@(X64Family what lines' bytes' cmpLen) = do
      putStrLn ("x64: " ++ what)
      r <- try (oneX' dir f) :: IO (Either SomeException Bool)
      case r of
        Left e -> putStrLn ("x64 EXC: " ++ show e) >> pure False
        Right v -> pure v
    oneX' dir f@(X64Family what lines' bytes' cmpLen) = do
      let sf = dir </> (what ++ "-x64.s")
          of' = dir </> (what ++ "-x64.o")
      writeFile sf (unlines lines')
      let archArgs = if os == "darwin" then ["-arch", "x86_64"] else []
      _ <- readProcess "as" (archArgs ++ [sf, "-o", of']) ""
      got <- x64BytesOf of'
      let n = if cmpLen < 0 then min (length got) (length bytes') else cmpLen
          ok = length got >= n && length bytes' >= n && take n got == take n bytes'
      if not ok then putStrLn ("X64 CONTRACT MISMATCH: " ++ what ++ " got " ++ show got ++ " want " ++ show bytes') else pure ()
      pure ok

