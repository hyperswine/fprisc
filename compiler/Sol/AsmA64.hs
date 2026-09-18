{-# LANGUAGE LambdaCase #-}

-- Sol/AsmA64.hs -- the AArch64 (AAPCS64) assembler for the kernel IR.
--
-- Register plan:
--   x29 frame pointer   x30 link   sp operand stack (16-byte slots: the
--   SP must stay 16-aligned, so every push is `str x0, [sp, #-16]!`)
--   x19 fuel cell pointer (callee-saved; parked by the extern prologue)
--   x0  operand a / result   x1 operand b   x2 third operand   x9 address
--   d0/d1 f64 operands
-- Slot addresses are formed with `add/sub x9, x29, #imm12`, so a frame
-- may hold up to 255 slots; a kernel never comes near that.
-- All branches are PC-relative words (cbz imm19, b/bl imm26).
module Sol.AsmA64 (assembleA64) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Word (Word32, Word8)
import Sol.KIR

type I = Word32

w :: I -> [Word8]
w x = [fromIntegral (x `shiftR` s .&. 0xFF) | s <- [0, 8, 16, 24]]

-- ---- instruction encoders ----------------------------------------------------
push, pop :: Int -> I -- str xN,[sp,#-16]!  /  ldr xN,[sp],#16
push r = 0xF81F0FE0 .|. fromIntegral r
pop r = 0xF84107E0 .|. fromIntegral r -- post-index: ldr xN,[sp],#16

ldrX, strX :: Int -> Int -> I -- ldr/str xT, [xN]
ldrX t n = 0xF9400000 .|. fromIntegral (n `shiftL` 5) .|. fromIntegral t
strX t n = 0xF9000000 .|. fromIntegral (n `shiftL` 5) .|. fromIntegral t

addImm, subImm :: Int -> Int -> Int -> I -- add/sub xD, xN, #imm12
addImm d n imm = 0x91000000 .|. fromIntegral (imm `shiftL` 10) .|. fromIntegral (n `shiftL` 5) .|. fromIntegral d
subImm d n imm = 0xD1000000 .|. fromIntegral (imm `shiftL` 10) .|. fromIntegral (n `shiftL` 5) .|. fromIntegral d

-- x9 = address of slot i
slotAddr :: Fn -> Int -> I
slotAddr f i
  | fnExtern f = subImm 9 29 (16 * (i + 2)) -- below the saved x19/x20 pair
  | i < fnParams f = addImm 9 29 (16 + 16 * (fnParams f - 1 - i))
  | otherwise = subImm 9 29 (16 * (i - fnParams f + 1))

movImm64 :: Int -> Int64 -> [I] -- movz + movk halves into xR
movImm64 r v =
  let u = fromIntegral v :: Integer
      hs = [(fromIntegral ((u `shiftR` (16 * k)) .&. 0xFFFF) :: I, k) | k <- [0 .. 3]]
      movz (h, k) = 0xD2800000 .|. (fromIntegral k `shiftL` 21) .|. (h `shiftL` 5) .|. fromIntegral r
      movk (h, k) = 0xF2800000 .|. (fromIntegral k `shiftL` 21) .|. (h `shiftL` 5) .|. fromIntegral r
   in movz (head hs) : [movk hk | hk@(h, _) <- tail hs, h /= 0]

fmovDX, fmovXD :: Int -> Int -> I -- fmov dD, xN  /  fmov xD, dN
fmovDX d n = 0x9E670000 .|. fromIntegral (n `shiftL` 5) .|. fromIntegral d
fmovXD d n = 0x9E660000 .|. fromIntegral (n `shiftL` 5) .|. fromIntegral d

cset :: Int -> I -> I -- cset x0, cond  (csinc x0, xzr, xzr, !cond)
cset r cond = 0x9A9F07E0 .|. ((cond .|. 1) - (cond .&. 1)) `shiftL` 12 .|. fromIntegral r

condEQ, condNE, condMI, condLS, condGE, condLT, condGT, condLE :: I
condEQ = 0; condNE = 1; condMI = 4; condLS = 9; condGE = 10; condLT = 11; condGT = 12; condLE = 13

-- ---- one op -> words with fixups ---------------------------------------------
data Frag = Frag [I] [(Int, Label, Bool)] -- (word index, label, isCbz)

ws :: [I] -> Frag
ws is = Frag is []

opFrag :: Fn -> Op -> Frag
opFrag f = \case
  PushImm v -> ws (movImm64 0 v ++ [push 0])
  Local i -> ws [slotAddr f i, ldrX 0 9, push 0]
  SetLocal i -> ws [pop 0, slotAddr f i, strX 0 9]
  LoadIx -> ws [pop 1, pop 0, 0xF8617800, push 0] -- ldr x0,[x0,x1,lsl #3]
  StoreIx -> ws [pop 1, pop 0, pop 2, 0xF8217802] -- str x2,[x0,x1,lsl #3]
  Bin o -> ws ([pop 1, pop 0] ++ bin o ++ [push 0])
  Cmp TI cc -> ws [pop 1, pop 0, 0xEB01001F, cset 0 (icc cc), push 0] -- cmp x0,x1
  Cmp TD cc -> ws [pop 1, pop 0, fmovDX 0 0, fmovDX 1 1, 0x1E612000, cset 0 (fcc cc), push 0] -- fcmp d0,d1
  IToD -> ws [pop 0, 0x9E620000, fmovXD 0 0, push 0] -- scvtf d0,x0
  DToI -> ws [pop 0, fmovDX 0 0, 0x9E780000, push 0] -- fcvtzs x0,d0
  SqrtD -> unD 0x1E61C000
  FloorD -> unD 0x1E654000 -- frintm
  RintD -> unD 0x1E644000 -- frintn (ties to even)
  Jz l -> Frag [pop 0, 0xB4000000] [(1, l, True)] -- cbz x0, l
  Jmp l -> Frag [0x14000000] [(0, l, False)]
  Lbl _ -> ws []
  Call l n -> Frag ([0x94000000] ++ addSp (16 * n) ++ [push 0]) [(0, l, False)]
  Ret -> ws (pop 0 : epilogue)
  FuelTick -> ws [ldrX 0 19, subImm 0 0 1, strX 0 19]
  Trap -> ws (movImm64 0 fuelTrap ++ [strX 0 19, 0xD2800000, push 0]) -- poison; x0 = 0; push
  where
    unD i = ws [pop 0, fmovDX 0 0, i, fmovXD 0 0, push 0]
    bin o = case o of
      AddI -> [0x8B010000] -- add x0,x0,x1
      SubI -> [0xCB010000]
      MulI -> [0x9B017C00] -- madd x0,x0,x1,xzr
      DivI -> -- cbnz x1, ok; poison the fuel cell, x0 = 0; b done; ok: sdiv x0,x0,x1
        let poison = movImm64 0 fuelPoison
            skip = fromIntegral (length poison + 4) -- words from the cbnz to the sdiv
         in [0xB5000001 .|. (skip `shiftL` 5)] ++ poison ++ [strX 0 19, 0xD2800000, 0x14000002, 0x9AC10C00]
      AddD -> fop 0x1E612800
      SubD -> fop 0x1E613800
      MulD -> fop 0x1E610800
      DivD -> fop 0x1E611800
    fop i = [fmovDX 0 0, fmovDX 1 1, i, fmovXD 0 0]
    icc cc = case cc of CLt -> condLT; CLe -> condLE; CGt -> condGT; CGe -> condGE; CEq -> condEQ; CNe -> condNE
    -- fcmp on NaN sets N=0 Z=0 C=1 V=1: mi/ls/gt/ge/eq all read false,
    -- ne reads true -- Haskell's (==)/(/=)/(<)... on Double exactly
    fcc cc = case cc of CLt -> condMI; CLe -> condLS; CGt -> condGT; CGe -> condGE; CEq -> condEQ; CNe -> condNE
    addSp k = [addImm 31 31 k | k > 0]
    epilogue
      | fnExtern f = [subImm 31 29 16, 0xA8C153F3, 0xA8C17BFD, 0xD65F03C0] -- sp=x29-16; ldp x19,x20; ldp x29,x30; ret
      | otherwise = [addImm 31 29 0, 0xA8C17BFD, 0xD65F03C0] -- mov sp,x29; ldp x29,x30; ret

prologue :: Fn -> [I]
prologue f
  | fnExtern f =
      [0xA9BF7BFD, addImm 29 31 0, 0xA9BF53F3] -- stp x29,x30,[sp,#-16]!; mov x29,sp; stp x19,x20,[sp,#-16]!
        ++ subSp (16 * fnSlots f)
        ++ concat [[slotAddr f i, strX i 9] | i <- [0 .. fnParams f - 1]] -- x0..x4 -> slots
        ++ [0xAA0003F3] -- mov x19, x0 (fuel cell)
  | otherwise =
      [0xA9BF7BFD, addImm 29 31 0] ++ subSp (16 * max 0 (fnSlots f - fnParams f))
  where
    subSp k = [subImm 31 31 k | k > 0]

-- ---- whole unit --------------------------------------------------------------
assembleA64 :: Unit -> [Word8]
assembleA64 (Unit fns) = concatMap w patched
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
    fix base (Frag is fx) = foldl (\acc (wo, l, isCbz) ->
        let t = M.findWithDefault (error ("asm a64: unknown label " ++ l)) l labels
            d = t - (base + wo) -- word delta from the branch itself
            enc = if isCbz then (fromIntegral (d .&. 0x7FFFF) `shiftL` 5) else fromIntegral (d .&. 0x3FFFFFF)
         in take wo acc ++ [acc !! wo .|. enc] ++ drop (wo + 1) acc) is fx
