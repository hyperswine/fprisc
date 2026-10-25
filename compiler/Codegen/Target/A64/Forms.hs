{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- AArch64 operand banks and effects, before allocation and after placement.
module Codegen.Target.A64.Forms (checkForms) where
import Codegen.Selected
import Codegen.Target.Forms
import qualified Codegen.Opcode as O
import qualified Codegen.Opcode.A64 as A
import Control.Monad (unless,forM_)

checkForms rf owner items=forM_ [i | I i<-items] $ \i->do
  let bad why=Left ("selected a64 "++owner++" "++siOp i++": "++why)
      require why yes=unless yes (bad why)
      ds=siDefs i;us=siUses i
      word=register rf GPR;fp=register rf FPR
      one ps=matches [word] ds && matches ps us
      none ps=null ds && matches ps us
      binary=one [word,word]
      bank O.WordBits=word;bank O.FloatRegisters=fp
      opcode=siOpcode i
      shape=case opcode of
        O.Common op->commonShape rf args False op ds us
        O.X64 _->False;O.RV _->False;O.TargetText _->False
        O.A64 op->case op of
          A.Move->one [word]
          A.FloatMove->case (ds,us) of ([d],[s])->(fp d && (word s || fp s)) || (word d && fp s);_->False
          A.Literal->one [immediate];A.Address->one [symbol]
          A.FrameLoad->case ds of [d]->(word d || fp d) && matches [frame] us;_->False
          A.FrameStore->case us of [s,f]->null ds && (word s || fp s) && frame f;_->False
          A.LoadSigned32->one [word,immediate]
          A.ShiftLeftImmediate->one [word,immediate];A.ShiftRightArithmeticImmediate->one [word,immediate]
          A.OrImmediate->one [word,immediate];A.AndImmediate->one [word,immediate];A.XorImmediate->one [word,immediate]
          A.SignExtend63->one [word,immediate];A.SignExtend31->one [word,immediate]
          A.Add->binary;A.Subtract->binary;A.Multiply->binary;A.Divide->binary;A.And->binary;A.Xor->binary;A.Or->binary
          A.ShiftLeft->binary;A.ShiftRight->binary;A.SubtractShifted1->binary
          A.Compare->none [word,word];A.CompareImmediate->none [word,immediate]
          A.Set _->one [];A.Select _->binary;A.Branch _->none [label]
          A.BranchZero->none [word,label];A.BranchNonzero->none [word,label];A.Jump->none [label]
          A.Call->length ds<=1 && all (fixed (Phys "x0")) ds && case us of OS _:vs->arguments args vs;_->False
          A.Push->none [word];A.ApplyN->matches [fixed (Phys "x0")] ds && matches [immediate] us
          A.Panic->none [symbol];A.Ret->none [fixed (Phys "x0")]
          A.Enter->none [];A.Save->none []
          A.LoadByte->one [word,immediate];A.LoadField->one [word,immediate]
          A.StoreField->none [word,word,immediate];A.StoreHeader->none [word,word,immediate]
          A.FloatBinary b _ _->matches [bank b] ds && matches [bank b,bank b] us
          A.FloatCompare b _ _->one [bank b,bank b]
          A.TreeLeaf b _->none [bank b,index 0 7]
          A.TreeOutput b _->matches [bank b] ds && matches [index 0 7] us
          A.TreeNode _ _->none [index 0 6];A.TreeCompare _ _->one []
          A.PairLoad->none [word,index 16 16];A.PairStore->none [word,index 16 31]
          A.PairDuplicate->none [word,index 17 31];A.PairBinary _->none [index 17 31,index 16 31,index 16 31]
  require "opcode/operand form or register bank mismatch" shape
  require "opcode/control effect mismatch" (siControl i==control opcode us)
  require "opcode/flag effect mismatch" (siFlags i==flags opcode)
  let form=case opcode of
        O.A64 A.Call->DirectCall
        O.A64 A.ApplyN->ApplyCall
        O.A64 A.Panic->PanicCall
        _->NoCall
  require "opcode/call metadata mismatch" (callMetadata opcode form us (siCalls i))
  where
    args=map (Phys . ("x"++) . show) [0::Int ..7]
    control op us=case (op,us) of
      (O.Common O.TailJump,_)->Return
      (O.Common O.JumpLoop,[OL l])->JumpTo l
      (O.A64 A.Ret,_)->Return;(O.A64 A.Panic,_)->Return
      (O.A64 A.Jump,[OL l])->JumpTo l
      (O.A64 (A.Branch _),[OL l])->CondTo [l]
      (O.A64 A.BranchZero,[_,OL l])->CondTo [l]
      (O.A64 A.BranchNonzero,[_,OL l])->CondTo [l]
      _->Next
    flags op=case op of
      O.Common c | c `elem` [O.EntryCheckTick,O.EntryCheck,O.EntryTick,O.TickN]->FlagsDef
      O.A64 x->case x of
        A.Set _->FlagsUse;A.Select _->FlagsUse;A.Branch _->FlagsUse
        A.FloatCompare _ _ _->FlagsDef;A.TreeCompare _ _->FlagsDef
        _ | x `elem` [A.Compare,A.CompareImmediate,A.Call,A.ApplyN]->FlagsDef
        _->FlagsNone
      _->FlagsNone
