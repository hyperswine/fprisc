{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- RISC-V selected operations shared by the RV32 and RV64 word policies.
module Codegen.Opcode.RV (Opcode(..),name) where
import Codegen.IR (FloatOp,CmpOp)
import Codegen.Opcode.Types
data Opcode
  = Literal | Address | Move | ShiftLeftImmediate | ShiftRightArithmeticImmediate | AndImmediate | OrImmediate | XorImmediate
  | Add | Subtract | Multiply | MultiplyHigh | Divide | And | Or | Xor | LessUnsigned | ShiftLeft | ShiftRight
  | Compare CmpOp | Load64 | Load32 | LoadByte | LoadHalf | LoadUnsigned32
  | Store64 | Store32 | StoreHalf | StoreByte | FrameLoad | FrameStore | Fence
  | BranchNonzero | Jump | Call | Ret | Push | ApplyN | Panic
  | FloatBinary Width FloatOp | FloatCompare Width CmpOp
  | TreeLeaf Width | TreeOutput Width | TreeNode Width FloatOp | TreeCompare Width CmpOp
  | VectorMax | VectorLanes | VectorSum
  deriving (Eq,Ord,Show)
name op=case op of
  Literal->"li";Address->"la";Move->"mv";ShiftLeftImmediate->"slli";ShiftRightArithmeticImmediate->"srai"
  AndImmediate->"andi";OrImmediate->"ori";XorImmediate->"xori"
  Add->"add";Subtract->"sub";Multiply->"mul";MultiplyHigh->"mulh";Divide->"div";And->"and";Or->"or";Xor->"xor"
  LessUnsigned->"sltu";ShiftLeft->"sll";ShiftRight->"srl";Compare c->"cmp."++comparisonName c
  Load64->"ld";Load32->"lw";LoadByte->"lbu";LoadHalf->"lhu";LoadUnsigned32->"lwu"
  Store64->"sd";Store32->"sw";StoreHalf->"sh";StoreByte->"sb";FrameLoad->"load.slot";FrameStore->"store.slot";Fence->"fence"
  BranchNonzero->"bnez";Jump->"j";Call->"call";Ret->"ret";Push->"push";ApplyN->"applyn";Panic->"panic"
  FloatBinary w f->widthPrefix "fbin" w++floatName f
  FloatCompare w c->widthPrefix "fcmp" w++comparisonName c
  TreeLeaf w->widthPrefix "ftree" w++"leaf";TreeOutput w->widthPrefix "ftree" w++"out"
  TreeNode w f->widthPrefix "ftree" w++floatName f;TreeCompare w c->widthPrefix "ftree" w++"cmp."++comparisonName c
  VectorMax->"rvv.vlmax";VectorLanes->"rvv.lanes";VectorSum->"rvv.sum"
