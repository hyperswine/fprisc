{-# LANGUAGE LambdaCase #-}

-- Sol/AsmX64.hs -- the x86-64 (SysV) assembler for the kernel IR.
--
-- Register plan (fixed, so every IR op is a fixed byte pattern):
--   rbp   frame pointer          rsp   operand stack
--   rbx   fuel cell pointer (callee-saved; the extern prologue parks
--         param 0 there for the whole call tree)
--   rax   scratch / operand a / result      r11  operand b
--   rdx   third operand (StoreIx value)     xmm0/xmm1  f64 operands
-- Every jump and call is rel32, so sizes are known in one pass and
-- labels patch in a second.  Nothing external is ever called: sqrt,
-- floor and rint are SSE2/SSE4.1 instructions, so stack alignment at
-- call sites is irrelevant and the frame is just slots.
module Sol.AsmX64 (assembleX64) where

import Data.Bits (shiftR, (.&.))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Word (Word8)
import Sol.KIR

type B = [Word8]

imm32 :: Int -> B
imm32 v = [fromIntegral (v `shiftR` s .&. 0xFF) | s <- [0, 8, 16, 24]]

imm64 :: Int64 -> B
imm64 v = [fromIntegral (fromIntegral v `shiftR` s .&. (0xFF :: Integer)) | s <- [0, 8, 16, 24, 32, 40, 48, 56]]

-- ---- fixed fragments ----------------------------------------------------
pushRax, popRax, popR11, popRdx :: B
pushRax = [0x50]
popRax = [0x58]
popR11 = [0x41, 0x5B]
popRdx = [0x5A]

movqXmm0Rax, movqXmm1R11, movqRaxXmm0 :: B
movqXmm0Rax = [0x66, 0x48, 0x0F, 0x6E, 0xC0]
movqXmm1R11 = [0x66, 0x49, 0x0F, 0x6E, 0xCB]
movqRaxXmm0 = [0x66, 0x48, 0x0F, 0x7E, 0xC0]

movzxRaxAl :: B
movzxRaxAl = [0x48, 0x0F, 0xB6, 0xC0]

-- mov rax, [rbp+disp32] / mov [rbp+disp32], rax
loadRbp, storeRbp :: Int -> B
loadRbp d = [0x48, 0x8B, 0x85] ++ imm32 d
storeRbp d = [0x48, 0x89, 0x85] ++ imm32 d

-- mov [rbp+disp32], <arg reg>  (extern prologue spills)
spillArg :: Int -> Int -> B
spillArg i d = case i of
  0 -> [0x48, 0x89, 0xBD] ++ imm32 d -- rdi
  1 -> [0x48, 0x89, 0xB5] ++ imm32 d -- rsi
  2 -> [0x48, 0x89, 0x95] ++ imm32 d -- rdx
  3 -> [0x48, 0x89, 0x8D] ++ imm32 d -- rcx
  4 -> [0x4C, 0x89, 0x85] ++ imm32 d -- r8
  _ -> error "asm x64: more than 5 extern params"

-- slot address relative to rbp
slotDisp :: Fn -> Int -> Int
slotDisp f i
  | fnExtern f = negate (8 * (i + 2)) -- below the saved rbx
  | i < fnParams f = 16 + 8 * (fnParams f - 1 - i) -- caller-pushed args
  | otherwise = negate (8 * (i - fnParams f + 1))

setcc :: Word8 -> B
setcc cc = [0x0F, cc, 0xC0] -- setcc al

-- ordered f64 compares on ucomisd flags; == is false and != true on NaN
-- (the interpreter's Haskell (==)/(/=) on Double)
cmpD :: CC -> B
cmpD cc = case cc of
  CLt -> ucom 1 0 ++ setcc 0x97 ++ movzxRaxAl -- b > a  (seta)
  CLe -> ucom 1 0 ++ setcc 0x93 ++ movzxRaxAl -- b >= a (setae)
  CGt -> ucom 0 1 ++ setcc 0x97 ++ movzxRaxAl
  CGe -> ucom 0 1 ++ setcc 0x93 ++ movzxRaxAl
  CEq -> ucom 0 1 ++ setcc 0x94 ++ [0x0F, 0x9B, 0xC1, 0x20, 0xC8] ++ movzxRaxAl -- sete al; setnp cl; and al,cl
  CNe -> ucom 0 1 ++ setcc 0x95 ++ [0x0F, 0x9A, 0xC1, 0x08, 0xC8] ++ movzxRaxAl -- setne al; setp cl; or al,cl
  where
    ucom :: Int -> Int -> B -- ucomisd xmm<a>, xmm<b>
    ucom a b = [0x66, 0x0F, 0x2E, 0xC0 + fromIntegral (a * 8 + b)]

cmpI :: CC -> B
cmpI cc = [0x4C, 0x39, 0xD8] ++ setcc c ++ movzxRaxAl -- cmp rax, r11
  where
    c = case cc of CLt -> 0x9C; CLe -> 0x9E; CGt -> 0x9F; CGe -> 0x9D; CEq -> 0x94; CNe -> 0x95

-- ---- one op -> bytes with label fixups ------------------------------------
-- a fixup is (offset of the rel32 field, target label); rel32 is relative
-- to the end of that field
data Frag = Frag B [(Int, Label)]

bytes :: B -> Frag
bytes b = Frag b []

rel :: B -> Label -> Frag -- opcode bytes then a rel32 field
rel op l = Frag (op ++ [0, 0, 0, 0]) [(length op, l)]

opFrag :: Fn -> Op -> Frag
opFrag f = \case
  PushImm v
    | v >= -2147483648 && v <= 2147483647 -> bytes ([0x68] ++ imm32 (fromIntegral v)) -- push imm32 (sign-extended)
    | otherwise -> bytes ([0x48, 0xB8] ++ imm64 v ++ pushRax)
  Local i -> bytes (loadRbp (slotDisp f i) ++ pushRax)
  SetLocal i -> bytes (popRax ++ storeRbp (slotDisp f i))
  LoadIx -> bytes (popR11 ++ popRax ++ [0x4A, 0x8B, 0x04, 0xD8] ++ pushRax) -- mov rax,[rax+r11*8]
  StoreIx -> bytes (popR11 ++ popRax ++ popRdx ++ [0x4A, 0x89, 0x14, 0xD8]) -- mov [rax+r11*8],rdx
  Bin o -> bytes (popR11 ++ popRax ++ binOp o ++ pushRax)
  Cmp TI cc -> bytes (popR11 ++ popRax ++ cmpI cc ++ pushRax)
  Cmp TD cc -> bytes (popR11 ++ popRax ++ movqXmm0Rax ++ movqXmm1R11 ++ cmpD cc ++ pushRax)
  IToD -> bytes (popRax ++ [0xF2, 0x48, 0x0F, 0x2A, 0xC0] ++ movqRaxXmm0 ++ pushRax) -- cvtsi2sd xmm0,rax
  DToI -> bytes (popRax ++ movqXmm0Rax ++ [0xF2, 0x48, 0x0F, 0x2C, 0xC0] ++ pushRax) -- cvttsd2si rax,xmm0
  SqrtD -> unD [0xF2, 0x0F, 0x51, 0xC0]
  FloorD -> unD [0x66, 0x0F, 0x3A, 0x0B, 0xC0, 0x09] -- roundsd xmm0,xmm0,9 (floor)
  RintD -> unD [0x66, 0x0F, 0x3A, 0x0B, 0xC0, 0x08] -- roundsd xmm0,xmm0,8 (MXCSR RN = nearest-even)
  Jz l -> rel (popRax ++ [0x48, 0x85, 0xC0, 0x0F, 0x84]) l -- test rax,rax; jz rel32
  Jmp l -> rel [0xE9] l
  Lbl _ -> bytes []
  Call l n -> Frag ([0xE8, 0, 0, 0, 0] ++ [0x48, 0x81, 0xC4] ++ imm32 (8 * n) ++ pushRax) [(1, l)]
  Ret -> bytes (popRax ++ epilogue)
  FuelTick -> bytes [0x48, 0x83, 0x2B, 0x01] -- sub qword [rbx], 1
  Trap -> bytes ([0x48, 0xB8] ++ imm64 fuelTrap ++ [0x48, 0x89, 0x03, 0x6A, 0x00]) -- mov rax,imm64; mov [rbx],rax; push 0
  where
    unD b = bytes (popRax ++ movqXmm0Rax ++ b ++ movqRaxXmm0 ++ pushRax)
    binOp o = case o of
      AddI -> [0x4C, 0x01, 0xD8]
      SubI -> [0x4C, 0x29, 0xD8]
      MulI -> [0x49, 0x0F, 0xAF, 0xC3]
      DivI -> -- test r11,r11; jnz ok; poison the fuel cell, rax = 0; jmp done; ok: cqo; idiv r11 (quot)
        [0x4D, 0x85, 0xDB, 0x75, 0x11]
          ++ [0x48, 0xB8] ++ imm64 fuelPoison ++ [0x48, 0x89, 0x03] -- mov rax,imm64; mov [rbx],rax
          ++ [0x31, 0xC0, 0xEB, 0x05] -- xor eax,eax; jmp +5
          ++ [0x48, 0x99, 0x49, 0xF7, 0xFB]
      AddD -> fop 0x58
      SubD -> fop 0x5C
      MulD -> fop 0x59
      DivD -> fop 0x5E
    fop k = movqXmm0Rax ++ movqXmm1R11 ++ [0xF2, 0x0F, k, 0xC1] ++ movqRaxXmm0 -- opsd xmm0,xmm1
    epilogue
      | fnExtern f = [0x48, 0x8D, 0x65, 0xF8] ++ [0x5B] ++ [0x5D, 0xC3] -- lea rsp,[rbp-8]; pop rbx; pop rbp; ret
      | otherwise = [0x48, 0x89, 0xEC, 0x5D, 0xC3] -- mov rsp,rbp; pop rbp; ret

prologue :: Fn -> B
prologue f
  | fnExtern f =
      [0x55, 0x48, 0x89, 0xE5, 0x53] -- push rbp; mov rbp,rsp; push rbx
        ++ [0x48, 0x81, 0xEC] ++ imm32 (8 * fnSlots f) -- sub rsp, 8*slots
        ++ concat [spillArg i (slotDisp f i) | i <- [0 .. fnParams f - 1]]
        ++ [0x48, 0x89, 0xFB] -- mov rbx, rdi   (fuel cell)
  | otherwise =
      [0x55, 0x48, 0x89, 0xE5]
        ++ [0x48, 0x81, 0xEC] ++ imm32 (8 * max 0 (fnSlots f - fnParams f))

-- ---- whole unit --------------------------------------------------------------
assembleX64 :: Unit -> [Word8]
assembleX64 (Unit fns) = patch
  where
    -- lay out: per fn, prologue then ops; local labels are qualified by fn
    laid = concatMap layFn fns
    layFn f = (Frag (prologue f) [], Just (fnLabel f)) : [(qual f (opFrag f o), lblOf f o) | o <- fnBody f]
    qual f (Frag b fx) = Frag b [(o, qualify f l) | (o, l) <- fx]
    lblOf f (Lbl l) = Just (qualify f l)
    lblOf _ _ = Nothing
    qualify f l = if l `elem` map fnLabel fns then l else fnLabel f ++ "." ++ l
    -- pass 1: offsets
    offs = scanl (\acc (Frag b _, _) -> acc + length b) 0 laid
    labels = M.fromList [(l, o) | ((_, Just l), o) <- zip laid offs]
    -- pass 2: patch rel32 fields
    patch = concat [fix o fr | (fr, o) <- zip (map fst laid) offs]
    fix base (Frag b fx) = foldl (patchOne base) b fx
    patchOne base acc (fo, l) =
      let t = M.findWithDefault (error ("asm x64: unknown label " ++ l)) l labels
          r = t - (base + fo + 4)
       in take fo acc ++ imm32 r ++ drop (fo + 4) acc
