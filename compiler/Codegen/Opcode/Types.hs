{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Shared selected protocols and typed scalar/SIMD operation payloads.
module Codegen.Opcode.Types where
import Codegen.IR (FloatOp(..),CmpOp(..))

data CommonOp=EntryCheckTick | EntryCheck | EntryTick | EntryStatic | TickN
  | TailJump | JumpLoop | SavesHere | LoadCell | StoreCell | LoadSpill | StoreSpill | Params
  deriving (Eq,Ord,Show,Enum,Bounded)
data Condition=Equal | NotEqual | Less | Greater | LessEqual | GreaterEqual
  | Overflow | UnsignedAboveEqual | UnsignedBelow
  deriving (Eq,Ord,Show,Enum,Bounded)
data Width=Float64 | Float32 deriving (Eq,Ord,Show,Enum,Bounded)
data SimdOp=PairAdd | PairSub | PairFloatAdd | PairFloatSub | PairFloatMul
  deriving (Eq,Ord,Show,Enum,Bounded)
data FloatBank=WordBits | FloatRegisters deriving (Eq,Ord,Show)

commonName op=case op of
  EntryCheckTick->"entry.check.tick";EntryCheck->"entry.check";EntryTick->"entry.tick"
  EntryStatic->"entry.static";TickN->"tick.n";TailJump->"tailjump";JumpLoop->"jump.loop";SavesHere->"saves.here"
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

widthPrefix stem Float64=stem++"."
widthPrefix stem Float32=stem++"32."
