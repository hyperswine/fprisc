{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- AArch64 selected operations, including the FP pool's register/word boundary.
module Codegen.Opcode.A64 (Opcode(..),name) where
import Codegen.IR (FloatOp,CmpOp)
import Codegen.Opcode.Types
data Opcode
  = Move | FloatMove | Literal | Address | FrameLoad | FrameStore | LoadSigned32
  | ShiftLeftImmediate | ShiftRightArithmeticImmediate | OrImmediate | AndImmediate | XorImmediate
  | SignExtend63 | SignExtend31 | Add | Subtract | Multiply | Divide | And | Xor | Or
  | ShiftLeft | ShiftRight | Compare | CompareImmediate | SubtractShifted1
  | Set Condition | Select Condition | Branch Condition | BranchZero | BranchNonzero | Jump
  | Call | Push | ApplyN | Panic | Ret | Enter | Save
  | LoadByte | LoadField | StoreField | StoreHeader
  | FloatBinary FloatBank Width FloatOp | FloatCompare FloatBank Width CmpOp
  | TreeLeaf FloatBank Width | TreeOutput FloatBank Width | TreeNode Width FloatOp | TreeCompare Width CmpOp
  | PairLoad | PairStore | PairDuplicate | PairBinary SimdOp
  deriving (Eq,Ord,Show)
name op=case op of
  Move->"mov";FloatMove->"fmov";Literal->"li";Address->"la";FrameLoad->"ldr";FrameStore->"str";LoadSigned32->"ldrsw"
  ShiftLeftImmediate->"lsl";ShiftRightArithmeticImmediate->"asr";OrImmediate->"orri";AndImmediate->"andi";XorImmediate->"eori"
  SignExtend63->"sbfx63";SignExtend31->"sbfx31";Add->"add";Subtract->"sub";Multiply->"mul";Divide->"sdiv";And->"and";Xor->"eor";Or->"orr"
  ShiftLeft->"lslr";ShiftRight->"lsrr";Compare->"cmp";CompareImmediate->"cmpi";SubtractShifted1->"sub.asr1"
  Set c->"cset."++conditionName c;Select c->"csel."++conditionName c;Branch c->"b."++conditionName c
  BranchZero->"cbz";BranchNonzero->"cbnz";Jump->"b"
  Call->"bl";Push->"push";ApplyN->"applyn";Panic->"panic";Ret->"ret";Enter->"enter";Save->"save"
  LoadByte->"load.byte";LoadField->"load.field";StoreField->"store.field";StoreHeader->"store.header"
  FloatBinary WordBits w f->widthPrefix "fbin" w++floatName f
  FloatBinary FloatRegisters w f->poolPrefix "bin" w++floatName f
  FloatCompare WordBits w c->widthPrefix "fcmp" w++comparisonName c
  FloatCompare FloatRegisters w c->poolPrefix "cmp" w++comparisonName c
  TreeLeaf b w->bankPrefix b++widthPrefix "ftree" w++"leaf"
  TreeOutput b w->bankPrefix b++widthPrefix "ftree" w++"out"
  TreeNode w f->widthPrefix "ftree" w++floatName f
  TreeCompare w c->widthPrefix "ftree" w++"cmp."++comparisonName c
  PairLoad->"simd.ld";PairStore->"simd.st";PairDuplicate->"simd.dup";PairBinary f->simdName f
  where
    poolPrefix stem Float64="pool."++stem++"64."
    poolPrefix stem Float32="pool."++stem++"32."
    bankPrefix WordBits="";bankPrefix FloatRegisters="pool."
