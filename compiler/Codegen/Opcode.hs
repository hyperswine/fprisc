{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- One tagged vocabulary through target-independent allocation. Each native
-- selector and renderer checks its own ISA; text is only a synthetic test API.
module Codegen.Opcode
  (Opcode(..),CommonOp(..),X64Op(..),Condition(..),Width(..),FloatBank(..),SimdOp(..),
   opcodeName,textOpcode,conditionName,floatName,comparisonName,simdMnemonic) where
import Codegen.Opcode.Types
import Codegen.Opcode.X64
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
