{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- One tagged vocabulary through target-independent allocation. Each native
-- selector and renderer checks its own ISA; text is only a synthetic test API.
module Codegen.Opcode
  (Opcode(..),CommonOp(..),X64Op(..),Condition(..),Width(..),FloatBank(..),SimdOp(..),
   opcodeName,textOpcode,conditionName,floatName,comparisonName,simdMnemonic) where
import Codegen.Opcode.Types
import Codegen.IR (FloatOp(..),CmpOp(..))
import qualified Codegen.Opcode.A64 as A64
import qualified Codegen.Opcode.RV as RV

data Opcode=Common CommonOp | X64 X64Op | A64 A64.Opcode | RV RV.Opcode | TargetText String
  deriving (Eq,Ord,Show)
opcodeName opcode=case opcode of
  Common op->commonName op
  X64 op->x64Name op
  A64 op->A64.name op
  RV op->RV.name op
  TargetText name->name

-- Synthetic allocator/constraint fixtures may name invented instructions.
-- Production selectors construct typed operations; their form checkers reject
-- this text vocabulary and instructions from every other ISA.
textOpcode name=case [op | op<-[minBound..maxBound],commonName op==name] of
  [op]->Common op
  _->TargetText name


data X64Op
  = Move | Literal | Address | LoadSigned32 | Compare | CompareImmediate | TestImmediate
  | Set Condition | Select Condition | Branch Condition | BranchZero | BranchNonzero | Jump
  | Add | Subtract | Multiply | And | Or | Xor
  | ShiftLeftImmediate | ShiftRightArithmeticImmediate | OrImmediate | AndImmediate | XorImmediate
  | AddImmediate | TagWord | LoadByteIndexed
  | SignExtend63 | ShiftLeft | ShiftRight | Divide
  | FrameLoad | FrameStore | LoadByte | LoadField | StoreField | StoreHeader
  | Call | Ret | Push | ApplyN | Panic | Enter | Save
  | IntToFloat FloatBank | FloatBinary FloatBank Width FloatOp | FloatCompare FloatBank Width CmpOp
  | FloatMove | FloatLiteral | FloatTest FloatBank Width
  | TreeLeaf FloatBank Width | TreeNode Width FloatOp | TreeOutput FloatBank Width | TreeCompare Width CmpOp | TreeTest Width CmpOp
  | PairLoad | PairStore | PairDuplicate | PairBinary SimdOp
  deriving (Eq,Ord,Show)
x64Name op=case op of
  Move->"movq";Literal->"li";Address->"la";LoadSigned32->"movslq";Compare->"cmpq";CompareImmediate->"cmpi";TestImmediate->"testi"
  Set c->"set."++conditionName c;Select c->"cmov."++conditionName c;Branch c->"j."++conditionName c
  BranchZero->"jzero";BranchNonzero->"jnonzero";Jump->"jmp"
  Add->"add";Subtract->"sub";Multiply->"mul";And->"and";Or->"or";Xor->"xor"
  ShiftLeftImmediate->"lsl";ShiftRightArithmeticImmediate->"asr";OrImmediate->"orri";AndImmediate->"andi";XorImmediate->"eori"
  AddImmediate->"addi";TagWord->"tag";LoadByteIndexed->"load.byte.indexed"
  SignExtend63->"sext63";ShiftLeft->"shlq";ShiftRight->"shrq";Divide->"divide"
  FrameLoad->"load";FrameStore->"store";LoadByte->"load.byte";LoadField->"load.field";StoreField->"store.field";StoreHeader->"store.header"
  Call->"call";Ret->"ret";Push->"push";ApplyN->"applyn";Panic->"panic";Enter->"enter";Save->"save"
  IntToFloat b->bankPrefix b++"cvtsi2sd"
  FloatBinary b w f->bankPrefix b++widthPrefix "fbin" w++floatName f
  FloatCompare b w c->bankPrefix b++widthPrefix "fcmp" w++comparisonName c
  FloatMove->"fmov";FloatLiteral->"fli"
  FloatTest b w->bankPrefix b++widthPrefix "ftest" w
  TreeLeaf b w->bankPrefix b++widthPrefix "ftree" w++"leaf"
  TreeNode w f->widthPrefix "ftree" w++floatName f
  TreeOutput b w->bankPrefix b++widthPrefix "ftree" w++"out"
  TreeCompare w c->widthPrefix "ftree" w++"cmp."++comparisonName c
  TreeTest w c->widthPrefix "ftree" w++"test."++comparisonName c
  PairLoad->"simd.ld";PairStore->"simd.st";PairDuplicate->"simd.dup";PairBinary f->simdName f
  where bankPrefix WordBits="";bankPrefix FloatRegisters="pool."
