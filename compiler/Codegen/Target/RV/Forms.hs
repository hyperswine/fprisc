{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- RV32/RV64 selected operands. This ISA has no condition-flag dependency.
module Codegen.Target.RV.Forms (checkForms) where
import qualified Codegen.Calling as Calling
import Codegen.Selected
import Codegen.Annotation
import Codegen.Target.Forms
import qualified Codegen.Opcode as O
import qualified Codegen.Opcode.RV as R
import Control.Monad (unless,forM_)

checkForms rf owner items=do
  checkAnnotations AlwaysRestores owner items
  Calling.checkTransfers Calling.RiscV owner items
  forM_ [i | I i<-items] $ \i->do
    let bad why=Left ("selected RISC-V "++owner++" "++siOp i++": "++why)
        require why yes=unless yes (bad why)
        ds=siDefs i;us=siUses i;opcode=siOpcode i
        word=register rf GPR
        one ps=matches [word] ds && matches ps us
        none ps=null ds && matches ps us
        binary=one [word,word]
        load=one [word,immediate];store=none [word,word,immediate]
        shape=case opcode of
          O.Common op->commonShape rf args True op ds us
          O.X64 _->False;O.A64 _->False;O.TargetText _->False
          O.RV op->case op of
            R.Literal->one [immediate];R.Address->one [symbol];R.Move->one [word]
            R.ShiftLeftImmediate->load;R.ShiftRightArithmeticImmediate->load
            R.AndImmediate->load;R.OrImmediate->load;R.XorImmediate->load
            R.Add->binary;R.Subtract->binary;R.Multiply->binary;R.MultiplyHigh->binary;R.Divide->binary
            R.And->binary;R.Or->binary;R.Xor->binary;R.LessUnsigned->binary;R.ShiftLeft->binary;R.ShiftRight->binary
            R.Compare _->binary
            R.Load64->load;R.Load32->load;R.LoadByte->load;R.LoadHalf->load;R.LoadUnsigned32->load
            R.Store64->store;R.Store32->store;R.StoreHalf->store;R.StoreByte->store
            R.FrameLoad->one [frame];R.FrameStore->none [word,frame];R.Fence->none []
            R.BranchNonzero->none [word,label];R.Jump->none [label]
            R.Call->length ds<=1 && all (fixed (Phys "a0")) ds && case us of OS _:vs->arguments args vs;_->False
            R.Ret->none [fixed (Phys "a0")];R.Push->none [word]
            R.ApplyN->matches [fixed (Phys "a0")] ds && matches [immediate] us
            R.Panic->none [symbol]
            R.FloatBinary _ _->binary;R.FloatCompare _ _->binary
            R.TreeLeaf _->none [word,index 0 7];R.TreeOutput _->one [index 0 7]
            R.TreeNode _ _->none [index 0 6];R.TreeCompare _ _->one []
            R.VectorMax->one [];R.VectorLanes->one [word,word,immediate];R.VectorSum->one [word]
    require "opcode/operand form or register bank mismatch" shape
    require "opcode/control effect mismatch" (siControl i==control opcode us)
    require "RISC-V operation declares condition flags" (siFlags i==FlagsNone)
    let form=case opcode of
          O.RV R.Call->DirectCall
          O.RV R.ApplyN->ApplyCall
          O.RV R.Panic->PanicCall
          _->NoCall
    require "opcode/call metadata mismatch" (callMetadata opcode form us (siCalls i))
  where
    args=map (Phys . ("a"++) . show) [0::Int ..7]
    control op us=case (op,us) of
      (O.Common O.TailJump,_)->Return;(O.Common O.JumpLoop,[OL l])->JumpTo l
      (O.RV R.Ret,_)->Return;(O.RV R.Panic,_)->Return
      (O.RV R.Jump,[OL l])->JumpTo l
      (O.RV R.BranchNonzero,[_,OL l])->CondTo [l]
      _->Next
