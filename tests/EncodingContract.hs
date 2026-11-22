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
import Codegen.Target.A64 (A64Config (..), HartAccess (..), ObjectFormat (..), renderItem)
import Codegen.Target.Common (noTune)
import Compiler.Encoding.A64 (Insn (..), condCode, condSuffix, encode, movImm64, render, insnBytes)
import qualified Compiler.Encoding.A64 as E
import Data.Char (isHexDigit)
import Data.Word (Word32)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.Process (readProcess)

cfg :: A64Config
cfg = A64Config ELF HartGlobal m2Policy S.empty False False False False noTune

ly :: Layout
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
  renderItem cfg ly False "contract" False [] [] M.empty item
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
      | isBranch it = replicate 8 "    nop" ++ renderItem cfg ly False "contract" False [] [] M.empty (ILabel (Label "t"))
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
  let bad = [what | ((False, _), Family what _ _) <- zip results families]
  if null bad
    then putStrLn ("a64 spelling contract: " ++ show (length families) ++ " families assemble identically through both renderers")
    else do
      mapM_ putStrLn (map ("CONTRACT MISMATCH: " ++) bad)
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
      let encWord = case encode i of Right w -> w; Left e -> error ("contract: encode failed: " ++ e)
      -- both spellings assemble to identical words, and the family's first
      -- word equals Encoding.encode (branches carry padding after the word)
      pure (wa == we && not (null wa) && head wa == encWord, f)
