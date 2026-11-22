-- Compiler/Encoding/A64.hs -- the shared AArch64 instruction vocabulary.
--
-- ONE description of each instruction form, two interpreters:
--
--   encode :: Insn -> Either String Word32   byte assembly (the Sol JIT tier)
--   render :: Insn -> String                 GNU-as text (the AOT .s path)
--
-- adopted JIT-first (Sol/AsmA64.hs consumes `encode`); the AOT A64 emitter
-- adopts the shared forms per instruction family as its slice proceeds.
-- Every constructor's encoding is pinned against GNU-as output by
-- `test:EncodingA64` -- the words were generated from this file's spellings
-- and compared to the pre-conversion hand encoder byte for byte.
--
-- Registers are integers in the assembler's convention: 0..30 general, 31
-- meaning sp or xzr according to the form (each constructor documents
-- which). Branches carry WORD deltas (already label-resolved); `encode`
-- range-checks every field and answers Left instead of ever masking --
-- the pre-conversion assembler silently truncated branch deltas to their
-- field widths.
module Compiler.Encoding.A64
  ( Cond (..),
    condCode,
    condSuffix,
    Insn (..),
    encode,
    render,
    insnBytes,
    movImm64,
  )
where

import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.Int (Int64)
import Data.List (intercalate)
import Data.Word (Word32, Word8)

type Reg = Int

-- condition codes: the 4-bit field, named by their standard suffixes
data Cond = Eq | Ne | Cs | Cc | Mi | Pl | Vs | Vc | Hi | Ls | Ge | Lt | Gt | Le
  deriving (Eq, Show)

condCode :: Cond -> Int
condCode c = case c of
  Eq -> 0; Ne -> 1; Cs -> 2; Cc -> 3; Mi -> 4; Pl -> 5; Vs -> 6; Vc -> 7
  Hi -> 8; Ls -> 9; Ge -> 10; Lt -> 11; Gt -> 12; Le -> 13

condSuffix :: Int -> String
condSuffix n = ["eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"] !! n

-- The instruction vocabulary: every form either tier emits today.
data Insn
  = -- | movz\/movk: 16-bit half at hw*16 (hw 0..3)
    MovZ Reg Int Int
  | MovK Reg Int Int
  | -- | add\/sub xD, xN, #imm12 (0..4095); Rd=Rn=31 is the sp-adjust form
    AddXImm12 Reg Reg Int
  | SubXImm12 Reg Reg Int
  | -- | adds\/subs xD, xN, xM (flag-setting, unshifted)
    AddSXRegX Reg Reg Reg
  | SubSXRegX Reg Reg Reg
  | -- | cmp xN, xM (subs xzr, xN, xM)
    CmpXReg Reg Reg
  | -- | cmn xN, #imm12 (adds xzr, xN, #imm)
    CmnXImm Reg Int
  | -- | orr xD, xN, xM (mov via xN=xzr)
    OrrXReg Reg Reg Reg
  | -- | eor xD, xN, xM
    EorXReg Reg Reg Reg
  | -- | mul xD, xN, xM (madd xD, xN, xM, xzr)
    MulX Reg Reg Reg
  | -- | msub xD, xN, xM, xA
    MSubX Reg Reg Reg Reg
  | -- | smulh xD, xN, xM
    SMulHX Reg Reg Reg
  | -- | sdiv xD, xN, xM
    SDivX Reg Reg Reg
  | -- | asr\/lsl\/extract forms via bitfield move: sbfm xD, xN, #immr, #imms
    SBfmX Reg Reg Int Int
  | -- | csinc xD, xzr, xzr, !cond: sets 1 iff the named condition HOLDS
    -- (the inverted field is the encoding mechanism). The render spells the
    -- inverted condition -- the alias that assembles to this same word.
    CSetX Reg Cond
  | -- | b\/bl \/b.cond \/cbz\/cbnz: WORD deltas, range-checked in encode
    BX Int
  | BL Int
  | BCndX Cond Int
  | CbzX Reg Int
  | CbnzX Reg Int
  | -- | tbz xR, #bit, delta (bit 0..62; b5 folded from bit >= 32)
    TbzX Reg Int Int
  | -- | ldr\/str xT, [xN, #imm12*8] (unscaled-by-8 unsigned offset)
    LdrXImm12 Reg Reg Int
  | StrXImm12 Reg Reg Int
  | -- | ldr\/str xT, [xN, xM, lsl #3]
    LdrXScale3 Reg Reg Reg
  | StrXRegScale3 Reg Reg Reg
  | -- | str\/ldr pre\/post-index writeback, 64-bit: imm9 -256..255
    -- (the operand-stack push is StrPreX r 31 (-16), pop LdrPostX r 31 16)
    StrPreX Reg Reg Int
  | LdrPostX Reg Reg Int
  | -- | fmov between general and SIMD registers
    FmovDX Reg Reg -- fmov dD, xN
  | FmovXD Reg Reg -- fmov xD, dN
  | -- | conversions and f64 unary: Dd from\/to Xn \/ Dn
    ScvtfXD Reg Reg
  | FcvtzsXD Reg Reg
  | FSqrtD Reg Reg
  | FRintND Reg Reg
  | FRintMD Reg Reg
  | -- | fcmp dN, dM (sets NZCV; NaN reads per the f64 contract)
    FCmpD Reg Reg
  | FAddD Reg Reg Reg
  | FSubD Reg Reg Reg
  | FMulD Reg Reg Reg
  | FDivD Reg Reg Reg
  | -- | ldp\/stp pairs on sp: post-index load \/ pre-index store, imm in
    -- bytes (multiple of 8, -512..504)
    LdpPostXSp Reg Reg Int
  | StpPreXSp Reg Reg Int
  | RetX
  deriving (Eq, Show)

-- one instruction, one word -- an A64 invariant the layout pass relies on
encode :: Insn -> Either String Word32
encode insn = case insn of
  MovZ r h hw
    | bad16 h || badHw hw -> range insn
    | otherwise -> Right (0xD2800000 .|. shift (fromIntegral hw) 21 .|. sh16 h .|. reg r)
  MovK r h hw
    | bad16 h || badHw hw -> range insn
    | otherwise -> Right (0xF2800000 .|. shift (fromIntegral hw) 21 .|. sh16 h .|. reg r)
  AddXImm12 d n imm
    | bad12 imm -> range insn
    | otherwise -> Right (0x91000000 .|. imm12F imm .|. reg (n * 32) .|. reg d)
  SubXImm12 d n imm
    | bad12 imm -> range insn
    | otherwise -> Right (0xD1000000 .|. imm12F imm .|. reg (n * 32) .|. reg d)
  AddSXRegX d n m -> Right (0xAB000000 .|. reg (m * 65536) .|. reg (n * 32) .|. reg d)
  SubSXRegX d n m -> Right (0xEB000000 .|. reg (m * 65536) .|. reg (n * 32) .|. reg d)
  CmpXReg n m -> Right (0xEB000000 .|. reg (m * 65536) .|. reg (n * 32) .|. 31)
  CmnXImm n imm
    | bad12 imm -> range insn
    | otherwise -> Right (0xB1000000 .|. imm12F imm .|. reg (n * 32) .|. 31)
  OrrXReg d n m -> Right (0xAA000000 .|. reg (m * 65536) .|. reg (n * 32) .|. reg d)
  EorXReg d n m -> Right (0xCA000000 .|. reg (m * 65536) .|. reg (n * 32) .|. reg d)
  MulX d n m -> maddLike d n m 31 -- Ra = xzr
  MSubX d n m a -> Right (0x9B000000 .|. 0x8000 .|. reg (m * 65536) .|. reg (a * 1024) .|. reg (n * 32) .|. reg d)
  SMulHX d n m -> Right (0x9B400000 .|. reg (m * 65536) .|. (31 `shiftL` 10) .|. reg (n * 32) .|. reg d)
  SDivX d n m -> Right (0x9AC00C00 .|. reg (m * 65536) .|. reg (n * 32) .|. reg d)
  SBfmX d n immr imms
    | bad6 immr || bad6 imms -> range insn
    | otherwise -> Right (0x93000000 .|. 0x400000 .|. reg (immr * 65536) .|. reg (imms * 1024) .|. reg (n * 32) .|. reg d)
  CSetX r c -> Right (0x9A9F07E0 .|. reg ((condCode c `xor` 1) * 4096) .|. reg r)
  BX d
    | bad26 d -> range insn
    | otherwise -> Right (0x14000000 .|. word26 d)
  BL d
    | bad26 d -> range insn
    | otherwise -> Right (0x94000000 .|. word26 d)
  BCndX c d
    | bad19 d -> range insn
    | otherwise -> Right (0x54000000 .|. word19 d .|. fromIntegral (condCode c))
  CbzX r d
    | bad19 d -> range insn
    | otherwise -> Right (0xB4000000 .|. word19 d .|. reg r)
  CbnzX r d
    | bad19 d -> range insn
    | otherwise -> Right (0xB5000000 .|. word19 d .|. reg r)
  TbzX r bit d
    | bit < 0 || bit > 63 || bad14 d -> range insn
    | otherwise ->
        let b5 = if bit >= 32 then 0x80000000 else 0
            b40 = fromIntegral (bit .&. 31) `shiftL` 19
         in Right (0x36000000 .|. b5 .|. b40 .|. word14 d .|. reg r)
  LdrXImm12 t n imm
    | bad12 imm -> range insn
    | otherwise -> Right (0xF9400000 .|. imm12F imm .|. reg (n * 32) .|. reg t)
  StrXImm12 t n imm
    | bad12 imm -> range insn
    | otherwise -> Right (0xF9000000 .|. imm12F imm .|. reg (n * 32) .|. reg t)
  LdrXScale3 t n m -> Right (0xF8607800 .|. reg (m * 65536) .|. reg (n * 32) .|. reg t)
  StrXRegScale3 t n m -> Right (0xF8207800 .|. reg (m * 65536) .|. reg (n * 32) .|. reg t)
  StrPreX t rn imm9
    | bad9 imm9 -> range insn
    | otherwise -> Right (0xF8000C00 .|. imm9F imm9 .|. reg (rn * 32) .|. reg t)
  LdrPostX t rn imm9
    | bad9 imm9 -> range insn
    | otherwise -> Right (0xF8400400 .|. imm9F imm9 .|. reg (rn * 32) .|. reg t)
  FmovDX d n -> Right (0x9E670000 .|. reg (n * 32) .|. reg d)
  FmovXD d n -> Right (0x9E660000 .|. reg (n * 32) .|. reg d)
  ScvtfXD d n -> Right (0x9E620000 .|. reg (n * 32) .|. reg d)
  FcvtzsXD d n -> Right (0x9E780000 .|. reg (n * 32) .|. reg d)
  FSqrtD d n -> Right (0x1E61C000 .|. reg (n * 32) .|. reg d)
  FRintND d n -> Right (0x1E644000 .|. reg (n * 32) .|. reg d)
  FRintMD d n -> Right (0x1E654000 .|. reg (n * 32) .|. reg d)
  FCmpD n m -> Right (0x1E602000 .|. reg (m * 65536) .|. reg (n * 32))
  FAddD d n m -> fpOp 0x1E602800 d n m
  FSubD d n m -> fpOp 0x1E603800 d n m
  FMulD d n m -> fpOp 0x1E600800 d n m
  FDivD d n m -> fpOp 0x1E601800 d n m
  LdpPostXSp r1 r2 imm
    | bad7 imm -> range insn
    | otherwise -> Right (0xA8C00000 .|. imm7F imm .|. reg (r2 * 1024) .|. reg (31 * 32) .|. reg r1)
  StpPreXSp r1 r2 imm
    | bad7 imm -> range insn
    | otherwise -> Right (0xA9800000 .|. imm7F imm .|. reg (r2 * 1024) .|. reg (31 * 32) .|. reg r1)
  RetX -> Right 0xD65F03C0
  where
    reg = fromIntegral
    shift v s = fromIntegral v `shiftL` s
    sh16 h = fromIntegral h `shiftL` 5
    imm12F imm = fromIntegral imm `shiftL` 10
    imm9F imm9 = fromIntegral (imm9 .&. 0x1FF) `shiftL` 12
    imm7F imm = fromIntegral ((imm `div` 8) .&. 0x7F) `shiftL` 15
    word19 d = fromIntegral (d .&. 0x7FFFF) `shiftL` 5
    word26 d = fromIntegral (d .&. 0x3FFFFFF)
    word14 d = fromIntegral (d .&. 0x3FFF) `shiftL` 5
    fpOp base d n m = Right (base .|. reg (m * 65536) .|. reg (n * 32) .|. reg d)
    maddLike d n m ra = Right (0x9B000000 .|. reg (m * 65536) .|. reg (ra * 1024) .|. reg (n * 32) .|. reg d)
    bad6 v = v < 0 || v > 63
    bad7 imm = imm < -512 || imm > 504 || imm `mod` 8 /= 0
    bad9 v = v < -256 || v > 255
    bad12 v = v < 0 || v > 4095
    bad14 v = v < -8192 || v > 8191
    bad16 v = v < 0 || v > 65535
    bad19 v = v < -65536 || v > 65535
    bad26 v = v < -33554432 || v > 33554431
    badHw hw = hw < 0 || hw > 3
    range i = Left ("a64 encode: field out of range in " ++ render i)

-- GNU-as text spelling: the dialect the AOT .s path speaks
render :: Insn -> String
render insn = case insn of
  MovZ r h hw -> imm3 "movz" r h hw
  MovK r h hw -> imm3 "movk" r h hw
  AddXImm12 d n imm -> rrd "add" d n (immStr imm)
  SubXImm12 d n imm -> rrd "sub" d n (immStr imm)
  AddSXRegX d n m -> rrr "adds" d n m
  SubSXRegX d n m -> rrr "subs" d n m
  CmpXReg n m -> "cmp " ++ regStr n ++ ", " ++ regStr m
  CmnXImm n imm -> "cmn " ++ regStr n ++ ", " ++ immStr imm
  OrrXReg d n m | n == 31 -> "mov " ++ regStr d ++ ", " ++ regStr m
                | otherwise -> rrr "orr" d n m
  EorXReg d n m -> rrr "eor" d n m
  MulX d n m -> rrr "mul" d n m
  MSubX d n m a -> "msub " ++ intercalate ", " [regStr r | r <- [d, n, m, a]]
  SMulHX d n m -> rrr "smulh" d n m
  SDivX d n m -> rrr "sdiv" d n m
  SBfmX d n immr imms -> "sbfm " ++ regStr d ++ ", " ++ regStr n ++ ", #" ++ show immr ++ ", #" ++ show imms
  CSetX r c -> "cset " ++ regStr r ++ ", " ++ condSuffix (condCode c)
  BX d -> rel "b" d
  BL d -> rel "bl" d
  BCndX c d -> rel (condSuffix (condCode c)) d
  CbzX r d -> relr "cbz" r d
  CbnzX r d -> relr "cbnz" r d
  TbzX r bit d -> "tbz " ++ regStr r ++ ", #" ++ show bit ++ ", ." ++ sgn (4 * d)
  LdrXImm12 t n imm -> ldst "ldr" t n (immStr (imm * 8) ++ "]")
  StrXImm12 t n imm -> ldst "str" t n (immStr (imm * 8) ++ "]")
  LdrXScale3 t n m -> "ldr " ++ regStr t ++ ", [" ++ regStr n ++ ", " ++ regStr m ++ ", lsl #3]"
  StrXRegScale3 t n m -> "str " ++ regStr t ++ ", [" ++ regStr n ++ ", " ++ regStr m ++ ", lsl #3]"
  StrPreX t rn imm9 -> ldst "str" t rn (", " ++ immStr imm9 ++ "]!")
  LdrPostX t rn imm9 -> ldst "ldr" t rn ("], #" ++ immStr imm9)
  FmovDX d n -> "fmov " ++ dstr d ++ ", " ++ regStr n
  FmovXD d n -> "fmov " ++ regStr d ++ ", " ++ dstr n
  ScvtfXD d n -> "scvtf " ++ dstr d ++ ", " ++ regStr n
  FcvtzsXD d n -> "fcvtzs " ++ regStr d ++ ", " ++ dstr n
  FSqrtD d n -> "fsqrt " ++ dstr d ++ ", " ++ dstr n
  FRintND d n -> "frintn " ++ dstr d ++ ", " ++ dstr n
  FRintMD d n -> "frintm " ++ dstr d ++ ", " ++ dstr n
  FCmpD n m -> "fcmp " ++ dstr n ++ ", " ++ dstr m
  FAddD d n m -> rrrF "fadd" d n m
  FSubD d n m -> rrrF "fsub" d n m
  FMulD d n m -> rrrF "fmul" d n m
  FDivD d n m -> rrrF "fdiv" d n m
  LdpPostXSp r1 r2 imm -> "ldp " ++ regStr r1 ++ ", " ++ regStr r2 ++ ", [sp], #" ++ immStr imm
  StpPreXSp r1 r2 imm -> "stp " ++ regStr r1 ++ ", " ++ regStr r2 ++ ", [sp, " ++ immStr imm ++ "]!"
  RetX -> "ret"
  where
    regStr r = if r == 31 then "sp" else "x" ++ show r
    dstr d = "d" ++ show d
    immStr imm = "#" ++ (if imm < 0 then "-" else "") ++ show (abs imm)
    sgn v = (if v < 0 then "-" else "+") ++ show (abs v)
    rrd op d n y = op ++ " " ++ regStr d ++ ", " ++ regStr n ++ ", " ++ y
    rrr op d n m = op ++ " " ++ regStr d ++ ", " ++ regStr n ++ ", " ++ regStr m
    rrrF op d n m = op ++ " " ++ dstr d ++ ", " ++ dstr n ++ ", " ++ dstr m
    rel op d = op ++ " ." ++ sgn (4 * d)
    relr op r d = op ++ " " ++ regStr r ++ ", ." ++ sgn (4 * d)
    imm3 op r h hw = op ++ " " ++ regStr r ++ ", " ++ immStr h ++ (if hw == 0 then "" else ", lsl #" ++ show (16 * hw))
    ldst op t n off = op ++ " " ++ regStr t ++ ", [" ++ regStr n ++ off

-- little-endian instruction word, as the JIT writes it into executable memory
insnBytes :: Word32 -> [Word8]
insnBytes x = [fromIntegral (x `shiftR` s .&. 0xFF) | s <- [0, 8, 16, 24]]

-- movz + movk halves: one movz for the least-significant nonzero half, then
-- a movk per remaining nonzero half (the idiom every wide constant uses)
movImm64 :: Reg -> Int64 -> [Insn]
movImm64 r v =
  let u = fromIntegral v :: Integer
      halves = [(fromIntegral ((u `div` (2 ^ (16 * k))) `mod` 65536), k) | k <- [0 .. 3]]
   in case halves of
        [] -> []
        ((h0, _) : rest) ->
          MovZ r h0 0 : [MovK r h k | (h, k) <- rest, h /= 0]
