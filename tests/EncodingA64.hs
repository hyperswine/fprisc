module Main (main) where

-- Byte-identity gate for the shared A64 vocabulary (Compiler.Encoding.A64):
-- every constructor's encoding is checked against the word GNU as emits for
-- the matching spelling (these literals were produced by `as` from the
-- probe file, and equal the pre-conversion hand encoder's output byte for
-- byte), plus range-check and render spot checks. `render`'s spellings are
-- the dialect the AOT .s path speaks, for its per-family adoption.

import Compiler.Encoding.A64
import Data.Word (Word32)
import System.Exit (exitFailure)

forms :: [(String, Word32, Insn)]
forms =
  [ ("mov x0, x2", 0xAA0203E0, OrrXReg 0 31 2),
    ("mov x19, x0", 0xAA0003F3, OrrXReg 19 31 0),
    ("orr x9, x0, x1", 0xCA010009, EorXReg 9 0 1),
    ("cmn x1, #1", 0xB100043F, CmnXImm 1 1),
    ("adds x0, x0, x1", 0xAB010000, AddSXRegX 0 0 1),
    ("subs x0, x0, x1", 0xEB010000, SubSXRegX 0 0 1),
    ("cmp x0, x1", 0xEB01001F, CmpXReg 0 1),
    ("sbfm x10, x2, #63, #63 (asr)", 0x937FFC4A, SBfmX 10 2 63 63),
    ("madd x2, x0, x1, xzr (mul)", 0x9B017C02, MulX 2 0 1),
    ("msub x0, x2, x1, x0", 0x9B018040, MSubX 0 2 1 0),
    ("smulh x9, x0, x1", 0x9B417C09, SMulHX 9 0 1),
    ("sdiv x2, x0, x1", 0x9AC10C02, SDivX 2 0 1),
    ("ldp x19, x20, [sp], #16", 0xA8C153F3, LdpPostXSp 19 20 16),
    ("ldp x29, x30, [sp], #16", 0xA8C17BFD, LdpPostXSp 29 30 16),
    ("stp x29, x30, [sp, #-16]!", 0xA9BF7BFD, StpPreXSp 29 30 (-16)),
    ("stp x19, x20, [sp, #-16]!", 0xA9BF53F3, StpPreXSp 19 20 (-16)),
    ("ret", 0xD65F03C0, RetX),
    ("scvtf d0, x0", 0x9E620000, ScvtfXD 0 0),
    ("fcvtzs x0, d0", 0x9E780000, FcvtzsXD 0 0),
    ("fsqrt d0, d0", 0x1E61C000, FSqrtD 0 0),
    ("frintn d0, d0", 0x1E644000, FRintND 0 0),
    ("frintm d0, d0", 0x1E654000, FRintMD 0 0),
    ("fcmp d0, d1", 0x1E612000, FCmpD 0 1),
    ("fadd d0, d0, d1", 0x1E612800, FAddD 0 0 1),
    ("fsub d0, d0, d1", 0x1E613800, FSubD 0 0 1),
    ("fmul d0, d0, d1", 0x1E610800, FMulD 0 0 1),
    ("fdiv d0, d0, d1", 0x1E611800, FDivD 0 0 1),
    ("fmov d0, x0", 0x9E670000, FmovDX 0 0),
    ("fmov x0, d0", 0x9E660000, FmovXD 0 0),
    ("ldr x0, [x0, x1, lsl #3]", 0xF8617800, LdrXScale3 0 0 1),
    ("str x2, [x0, x1, lsl #3]", 0xF8217802, StrXRegScale3 2 0 1),
    ("ldr x0, [x19]", 0xF9400260, LdrXImm12 0 19 0),
    ("str x10, [x19]", 0xF900026A, StrXImm12 10 19 0),
    ("add x9, x29, #16", 0x910043A9, AddXImm12 9 29 16),
    ("sub sp, sp, #16", 0xD10043FF, SubXImm12 31 31 16),
    ("str x0, [sp, #-16]! (push)", 0xF81F0FE0, StrPreX 0 31 (-16)),
    ("str x3, [sp, #-16]! (push)", 0xF81F0FE3, StrPreX 3 31 (-16)),
    ("ldr x0, [sp], #16 (pop)", 0xF84107E0, LdrPostX 0 31 16),
    ("movz x0, #42", 0xD2800540, MovZ 0 42 0),
    ("movk x0, #1, lsl #16", 0xF2A00020, MovK 0 1 1),
    ("b", 0x14000000, BX 0),
    ("bl", 0x94000000, BL 0),
    ("b.eq +4 (1 word)", 0x54000020, BCndX Eq 1),
    ("b.vc +4 (1 word)", 0x54000027, BCndX Vc 1),
    ("cbz x0, +4", 0xB4000080, CbzX 0 4),
    ("cbnz x1, +0", 0xB5000001, CbnzX 1 0),
    ("tbz x9, #63, +8", 0xB6F80049, TbzX 9 63 2),
    ("cset x0, ne (on !eq)", 0x9A9F17E0, CSetX 0 Eq),
    ("cset x0, pl (on !mi)", 0x9A9F57E0, CSetX 0 Mi)
  ]

ranges :: [(String, Insn)]
ranges =
  [ ("b.cond delta over imm19", BCndX Eq 65536),
    ("b.cond delta under imm19", BCndX Eq (-65537)),
    ("b delta over imm26", BX 33554432),
    ("cbz delta over imm19", CbzX 0 65536),
    ("tbz delta over imm14", TbzX 0 63 8192),
    ("add imm12 over 4095", AddXImm12 0 0 4096),
    ("sbfm immr over 63", SBfmX 0 0 64 0),
    ("movz half over 65535", MovZ 0 65536 0),
    ("movk hw over 3", MovK 0 0 4)
  ]

renders :: [(String, Insn)]
renders =
  [ ("str x0, [sp, #-16]!", StrPreX 0 31 (-16)),
    ("ldr x0, [x0, x1, lsl #3]", LdrXScale3 0 0 1),
    ("scvtf d0, x0", ScvtfXD 0 0),
    ("ret", RetX),
    ("msub x0, x2, x1, x0", MSubX 0 2 1 0),
    ("cmp x0, x1", CmpXReg 0 1),
    ("cset x0, eq", CSetX 0 Eq)
  ]

main :: IO ()
main = do
  let encFails =
        [ (what, want, got)
        | (what, want, i) <- forms
        , let got = either (const 0) id (encode i)
        , got /= want
        ]
      rangeFails =
        [ (what, encode i)
        | (what, i) <- ranges
        , either (const False) (const True) (encode i) -- expected Left, got Right
        ]
      renderFails =
        [ (want, render i)
        | (want, i) <- renders
        , render i /= want
        ]
  if null encFails && null rangeFails && null renderFails
    then
      putStrLn
        ( "encoding a64: " ++ show (length forms) ++ " byte-identity checks (GNU-as words), "
            ++ show (length ranges) ++ " range checks, "
            ++ show (length renders) ++ " render checks passed"
        )
    else do
      mapM_ print encFails
      print rangeFails
      print renderFails
      exitFailure
