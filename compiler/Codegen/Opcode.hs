{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Selected operations are data. Shared entry/transfer protocols retain their
-- identity through allocation; x64 selection and rendering use constructors.
-- Other ISA vocabularies remain explicit migration inputs, not x64 opcodes.
module Codegen.Opcode
  (Opcode(..),CommonOp(..),X64Op(..),Condition(..),Width(..),SimdOp(..),
   opcodeName,textOpcode,conditionName,floatName,comparisonName,simdMnemonic) where
import Codegen.IR (FloatOp(..),CmpOp(..))

data CommonOp=EntryCheckTick | EntryCheck | EntryTick | EntryStatic | TickN
  | TailJump | JumpLoop | LoadCell | StoreCell | LoadSpill | StoreSpill | Params
  deriving (Eq,Ord,Show,Enum,Bounded)
data Condition=Equal | NotEqual | Less | Greater | LessEqual | GreaterEqual
  | Overflow | UnsignedAboveEqual | UnsignedBelow
  deriving (Eq,Ord,Show,Enum,Bounded)
data Width=Float64 | Float32 deriving (Eq,Ord,Show,Enum,Bounded)
data SimdOp=PairAdd | PairSub | PairFloatAdd | PairFloatSub | PairFloatMul
  deriving (Eq,Ord,Show,Enum,Bounded)
data X64Op
  = Move | Literal | Address | LoadSigned32 | Compare | CompareImmediate
  | Set Condition | Select Condition | Branch Condition | BranchZero | BranchNonzero | Jump
  | Add | Subtract | Multiply | And | Or | Xor
  | ShiftLeftImmediate | ShiftRightArithmeticImmediate | OrImmediate | AndImmediate | XorImmediate
  | SignExtend63 | ShiftLeft | ShiftRight | Divide
  | FrameLoad | FrameStore | LoadByte | LoadField | StoreField | StoreHeader
  | Call | Ret | Push | ApplyN | Panic | Enter | Save
  | FloatBinary Width FloatOp | FloatCompare Width CmpOp
  | TreeLeaf Width | TreeNode Width FloatOp | TreeOutput Width | TreeCompare Width CmpOp
  | PairLoad | PairStore | PairDuplicate | PairBinary SimdOp
  deriving (Eq,Ord,Show)
data Opcode=Common CommonOp | X64 X64Op | TargetText String deriving (Eq,Ord,Show)

commonName op=case op of
  EntryCheckTick->"entry.check.tick";EntryCheck->"entry.check";EntryTick->"entry.tick"
  EntryStatic->"entry.static";TickN->"tick.n";TailJump->"tailjump";JumpLoop->"jump.loop"
  LoadCell->"load.cell";StoreCell->"store.cell";LoadSpill->"load.spill";StoreSpill->"store.spill";Params->"params"
conditionName c=case c of
  Equal->"eq";NotEqual->"ne";Less->"lt";Greater->"gt";LessEqual->"le";GreaterEqual->"ge"
  Overflow->"o";UnsignedAboveEqual->"hs";UnsignedBelow->"lo"
floatName op=case op of FAdd->"add";FSub->"sub";FMul->"mul";FDiv->"div"
comparisonName op=case op of Lt->"lt";Gt->"gt";Le->"le";Ge->"ge";Eq->"eq";Ne->"ne"
simdName op=case op of
  PairAdd->"simd.add";PairSub->"simd.sub";PairFloatAdd->"simd.fadd";PairFloatSub->"simd.fsub";PairFloatMul->"simd.fmul"
simdMnemonic op=case op of
  PairAdd->"paddq";PairSub->"psubq";PairFloatAdd->"addpd";PairFloatSub->"subpd";PairFloatMul->"mulpd"
opcodeName opcode=case opcode of
  Common op->commonName op
  TargetText name->name
  X64 op->case op of
    Move->"movq";Literal->"li";Address->"la";LoadSigned32->"movslq";Compare->"cmpq";CompareImmediate->"cmpi"
    Set c->"set."++conditionName c;Select c->"cmov."++conditionName c;Branch c->"j."++conditionName c
    BranchZero->"jzero";BranchNonzero->"jnonzero";Jump->"jmp"
    Add->"add";Subtract->"sub";Multiply->"mul";And->"and";Or->"or";Xor->"xor"
    ShiftLeftImmediate->"lsl";ShiftRightArithmeticImmediate->"asr";OrImmediate->"orri";AndImmediate->"andi";XorImmediate->"eori"
    SignExtend63->"sext63";ShiftLeft->"shlq";ShiftRight->"shrq";Divide->"divide"
    FrameLoad->"load";FrameStore->"store";LoadByte->"load.byte";LoadField->"load.field";StoreField->"store.field";StoreHeader->"store.header"
    Call->"call";Ret->"ret";Push->"push";ApplyN->"applyn";Panic->"panic";Enter->"enter";Save->"save"
    FloatBinary w f->widthPrefix "fbin" w++floatName f
    FloatCompare w c->widthPrefix "fcmp" w++comparisonName c
    TreeLeaf w->widthPrefix "ftree" w++"leaf"
    TreeNode w f->widthPrefix "ftree" w++floatName f
    TreeOutput w->widthPrefix "ftree" w++"out"
    TreeCompare w c->widthPrefix "ftree" w++"cmp."++comparisonName c
    PairLoad->"simd.ld";PairStore->"simd.st";PairDuplicate->"simd.dup";PairBinary f->simdName f
  where widthPrefix stem Float64=stem++"."
        widthPrefix stem Float32=stem++"32."

-- Transitional constructors for ISA selectors not migrated yet and synthetic
-- allocator tests. The x64 selector never calls this function.
textOpcode name=case [op | op<-[minBound..maxBound],commonName op==name] of
  [op]->Common op
  _->TargetText name
