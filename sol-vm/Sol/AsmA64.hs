{-# LANGUAGE LambdaCase #-}

-- Sol/AsmA64.hs -- the AArch64 (AAPCS64) assembler for the kernel IR.
--
-- Every instruction is built through the shared vocabulary
-- (Compiler.Encoding.A64) and range-checked by `encode`: a field that
-- does not fit is an error naming the instruction, never a masked word.
-- The register plan and label/fixup machinery live HERE; the instruction
-- definitions do not.
--
-- Register plan:
--   x29 frame pointer   x30 link   sp operand stack (16-byte slots: the
--   SP must stay 16-aligned, so every push is `str x0, [sp, #-16]!`)
--   x19 fuel cell pointer (callee-saved; parked by the extern prologue)
--   x0  operand a / result   x1 operand b   x2 third operand   x9 address
--   d0/d1 f64 operands
-- Slot addresses are formed with `add/sub x9, x29, #imm12`, so a frame
-- may hold up to 255 slots; a kernel never comes near that.
module Sol.AsmA64 (assembleA64) where

import qualified Compiler.Encoding.A64 as E
import Data.Int (Int64)
import Data.Word (Word8)
import qualified Data.Map.Strict as M
import Sol.JitIR

-- ---- instruction fragments ----------------------------------------------------
-- A fragment is a list of instructions plus label fixups: (index, label,
-- branch form). The branch instructions in the list are PLACEHOLDERS; the
-- patch pass replaces them with the resolved branch before encoding.
data Branch = FkB | FkBl | FkBCnd E.Cond | FkCbz Int

data Frag = Frag [E.Insn] [(Int, Label, Branch)]

ws :: [E.Insn] -> Frag
ws is = Frag is []

push, pop :: Int -> E.Insn -- str xN,[sp,#-16]!  /  ldr xN,[sp],#16
push r = E.StrPreX r 31 (-16)
pop r = E.LdrPostX r 31 16

-- x9 = address of slot i
slotAddr :: Fn -> Int -> E.Insn
slotAddr f i
  | fnExtern f = E.SubXImm12 9 29 (16 * (i + 2)) -- below the saved x19/x20 pair
  | i < fnParams f = E.AddXImm12 9 29 (16 + 16 * (fnParams f - 1 - i))
  | otherwise = E.SubXImm12 9 29 (16 * (i - fnParams f + 1))

-- Store pval into [x19] only if [x19] > fuelOverflow (first poison wins).
-- Clobbers x9, x10.
poisonIfClear :: Int64 -> [E.Insn]
poisonIfClear pval =
  let loadLim = E.movImm64 10 fuelOverflow
      loadVal = E.movImm64 10 pval
      skip = length loadVal + 2
   in [E.LdrXImm12 9 19 0]
        ++ loadLim
        ++ [E.CmpXReg 9 10, E.BCndX E.Le skip]
        ++ loadVal
        ++ [E.StrXImm12 10 19 0]

-- ---- one op -> instruction fragment -------------------------------------------
opFrag :: Fn -> Op -> Frag
opFrag f = \case
  PushImm v -> ws (E.movImm64 0 v ++ [push 0])
  Local i -> ws [slotAddr f i, E.LdrXImm12 0 9 0, push 0]
  SetLocal i -> ws [pop 0, slotAddr f i, E.StrXImm12 0 9 0]
  LoadIx -> ws [pop 1, pop 0, E.LdrXScale3 0 0 1, push 0]
  StoreIx -> ws [pop 1, pop 0, pop 2, E.StrXRegScale3 2 0 1]
  Bin o -> ws ([pop 1, pop 0] ++ bin o ++ [push 0])
  Cmp TI cc -> ws [pop 1, pop 0, E.CmpXReg 0 1, E.CSetX 0 (icc cc), push 0]
  Cmp TD cc -> ws [pop 1, pop 0, E.FmovDX 0 0, E.FmovDX 1 1, E.FCmpD 0 1, E.CSetX 0 (fcc cc), push 0]
  IToD -> ws [pop 0, E.ScvtfXD 0 0, E.FmovXD 0 0, push 0]
  DToI -> ws [pop 0, E.FmovDX 0 0, E.FcvtzsXD 0 0, push 0]
  SqrtD -> unD (E.FSqrtD 0 0)
  FloorD -> unD (E.FRintMD 0 0) -- frintm
  RintD -> unD (E.FRintND 0 0) -- frintn (ties to even)
  Jz l -> Frag [pop 0, E.BX 0] [(1, l, FkCbz 0)]
  Jmp l -> Frag [E.BX 0] [(0, l, FkB)]
  Lbl _ -> ws []
  Call l n -> Frag ([E.BL 0] ++ addSp (16 * n) ++ [push 0]) [(0, l, FkBl)]
  Ret -> ws (pop 0 : epilogue)
  FuelTick -> ws [E.LdrXImm12 0 19 0, E.SubXImm12 0 0 1, E.StrXImm12 0 19 0]
  Trap -> ws (poisonIfClear fuelTrap ++ [E.MovZ 0 0 0, push 0]) -- poison; x0 = 0; push
  where
    unD i = ws [pop 0, E.FmovDX 0 0, i, E.FmovXD 0 0, push 0]
    ovf = poisonIfClear fuelOverflow
    bin o = case o of
      AddI -> [E.AddSXRegX 0 0 1, E.BCndX E.Vc (length ovf + 1)] ++ ovf -- adds x0,x0,x1; b.vc ok
      SubI -> [E.SubSXRegX 0 0 1, E.BCndX E.Vc (length ovf + 1)] ++ ovf -- subs x0,x0,x1; b.vc ok
      MulI ->
        [ E.MulX 2 0 1, -- mul x2, x0, x1
          E.SMulHX 9 0 1, -- smulh x9, x0, x1
          E.OrrXReg 0 31 2, -- mov x0, x2
          E.SBfmX 10 2 63 63, -- asr x10, x2, #63
          E.CmpXReg 9 10, -- cmp x9, x10
          E.BCndX E.Eq (length ovf + 1)
        ]
          ++ ovf
      DivI -> -- check b==0 (fuelPoison), then b==-1 && a==INT64_MIN (fuelOverflow), else floored div
        let pZero = poisonIfClear fuelPoison
            divBody =
              [ E.SDivX 2 0 1,
                E.MSubX 0 2 1 0, -- msub x0, x2, x1, x0
                E.CbzX 0 4, -- remainder 0: quotient stands
                E.EorXReg 9 0 1, -- signs differ iff xor's high bit set
                E.TbzX 9 63 2, -- same sign: skip the floor adjustment
                E.SubXImm12 2 2 1,
                E.OrrXReg 0 31 2
              ]
            nDiv = length divBody
            nOvf = length ovf
            neg1Block =
              [ E.CmnXImm 1 1, -- cmn x1, #1
                E.BCndX E.Ne (4 + nOvf),
                E.SubSXRegX 0 31 0, -- negs x0, x0
                E.BCndX E.Vc (2 + nOvf + nDiv)
              ]
                ++ ovf
                ++ [E.BX (1 + nDiv)]
            skipZero = length pZero + 3
         in [E.CbnzX 1 skipZero]
              ++ pZero
              ++ [E.MovZ 0 0 0, E.BX (1 + length neg1Block + nDiv)]
              ++ neg1Block
              ++ divBody
      AddD -> fop (E.FAddD 0 0 1)
      SubD -> fop (E.FSubD 0 0 1)
      MulD -> fop (E.FMulD 0 0 1)
      DivD -> fop (E.FDivD 0 0 1)
    fop i = [E.FmovDX 0 0, E.FmovDX 1 1, i, E.FmovXD 0 0]
    icc cc = case cc of CLt -> E.Lt; CLe -> E.Le; CGt -> E.Gt; CGe -> E.Ge; CEq -> E.Eq; CNe -> E.Ne
    -- fcmp on NaN sets N=0 Z=0 C=1 V=1: mi/ls/gt/ge/eq all read false,
    -- ne reads true -- Haskell's (==)/(/=)/(<)... on Double exactly
    fcc cc = case cc of CLt -> E.Mi; CLe -> E.Ls; CGt -> E.Gt; CGe -> E.Ge; CEq -> E.Eq; CNe -> E.Ne
    addSp k = [E.AddXImm12 31 31 k | k > 0]
    epilogue
      | fnExtern f = [E.SubXImm12 31 29 16, E.LdpPostXSp 19 20 16, E.LdpPostXSp 29 30 16, E.RetX] -- sp=x29-16; ldp x19,x20; ldp x29,x30; ret
      | otherwise = [E.AddXImm12 31 29 0, E.LdpPostXSp 29 30 16, E.RetX] -- mov sp,x29; ldp x29,x30; ret

prologue :: Fn -> [E.Insn]
prologue f
  | fnExtern f =
      [ E.StpPreXSp 29 30 (-16), -- stp x29,x30,[sp,#-16]!
        E.AddXImm12 29 31 0, -- mov x29, sp
        E.StpPreXSp 19 20 (-16) -- stp x19,x20,[sp,#-16]!
      ]
        ++ subSp (16 * fnSlots f)
        ++ concat [[slotAddr f i, E.StrXImm12 i 9 0] | i <- [0 .. fnParams f - 1]] -- x0..x4 -> slots
        ++ [E.OrrXReg 19 31 0] -- mov x19, x0 (fuel cell)
  | otherwise =
      [E.StpPreXSp 29 30 (-16), E.AddXImm12 29 31 0] ++ subSp (16 * max 0 (fnSlots f - fnParams f))
  where
    subSp k = [E.SubXImm12 31 31 k | k > 0]

-- ---- whole unit --------------------------------------------------------------
assembleA64 :: Unit -> [Word8]
assembleA64 (Unit fns) = concatMap E.insnBytes patched
  where
    laid = concatMap layFn fns
    layFn f = (Frag (prologue f) [], Just (fnLabel f)) : [(qual f (opFrag f o), lblOf f o) | o <- fnBody f]
    qual f (Frag is fx) = Frag is [(o, qualify f l, c) | (o, l, c) <- fx]
    lblOf f (Lbl l) = Just (qualify f l)
    lblOf _ _ = Nothing
    qualify f l = if l `elem` map fnLabel fns then l else fnLabel f ++ "." ++ l
    offs = scanl (\acc (Frag is _, _) -> acc + length is) 0 laid -- in words
    labels = M.fromList [(l, o) | ((_, Just l), o) <- zip laid offs]
    patched = concat [fix o fr | (fr, o) <- zip (map fst laid) offs]
    fix base (Frag is fx) =
      [ case M.lookup wo fxm of
          Nothing -> enc i
          Just (l, kind) ->
            let t = M.findWithDefault (error ("asm a64: unknown label " ++ l)) l labels
                d = t - (base + wo) -- word delta from the branch itself
             in encBranch kind d
      | (wo, i) <- zip [0 ..] is
      ]
      where
        fxm = M.fromList [(wo, (l, kind)) | (wo, l, kind) <- fx]
        enc i = either (error . ("asm a64: " ++)) id (E.encode i)
        encBranch kind d = either (error . ("asm a64: " ++)) id (E.encode (branch kind d))
    branch kind d = case kind of
      FkB -> E.BX d
      FkBl -> E.BL d
      FkBCnd c -> E.BCndX c d
      FkCbz r -> E.CbzX r d
