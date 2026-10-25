{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- The selected x64 vocabulary has one operand/control contract. Check it
-- before allocation and again after physical placement, before rendering.
module Codegen.Target.X64.Forms (checkForms) where
import qualified Codegen.Calling as Calling
import Codegen.Target.Forms (callMetadata,CallForm(..))
import Codegen.Selected
import Codegen.Protocol (checkProtocols)
import qualified Codegen.Protocol as Protocol
import Codegen.Annotation
import qualified Codegen.Opcode as O
import Control.Monad (unless,forM_)

checkForms :: String -> [Item] -> Either String ()
checkForms owner items=do
  checkAnnotations AlwaysRestores owner items
  Calling.checkTransfers Calling.X86_64 owner items
  checkProtocols Calling.X86_64 owner items
  forM_ [i | I i<-items] $ \i->do
    let bad why=Left ("selected x64 "++owner++" "++siOp i++": "++why)
        require why yes=unless yes (bad why)
        ds=siDefs i;us=siUses i
        shape=case siOpcode i of
          O.TargetText _->False
          O.A64 _->False
          O.RV _->False
          O.Common op->case op of
            O.EntryCheckTick->entry ds us
            O.EntryCheck->entry ds us
            O.EntryTick->entry ds us
            O.SavesHere->False
            O.EntryStatic->False -- x64 has no such expansion
            O.TickN->null ds && matches [immediate] us
            O.TailJump->null ds && transfer us
            O.JumpLoop->null ds && matches [label] us
            O.LoadCell->matches [word] ds && matches [argumentCell] us
            O.StoreCell->null ds && matches [word,argumentCell] us
            O.LoadSpill->matches [word] ds && matches [immediate] us
            O.StoreSpill->null ds && matches [word,immediate] us
            O.Params->length ds<=6 && all word ds && null us
          O.X64 op->case op of
            O.Move->one [word]
            O.Literal->one [immediate]
            O.Address->one [symbol]
            O.LoadSigned32->one [word,immediate]
            O.Compare->none [word,word]
            O.CompareImmediate->none [word,immediate]
            O.Set _->one []
            O.Select _->one [word,word]
            O.Branch _->none [label]
            O.BranchZero->none [word,label]
            O.BranchNonzero->none [word,label]
            O.Jump->none [label]
            O.Add->binary;O.Subtract->binary;O.Multiply->binary
            O.And->binary;O.Or->binary;O.Xor->binary
            O.ShiftLeftImmediate->one [word,immediate]
            O.ShiftRightArithmeticImmediate->one [word,immediate]
            O.OrImmediate->one [word,immediate]
            O.AndImmediate->one [word,immediate]
            O.XorImmediate->one [word,immediate]
            O.SignExtend63->one [word,immediate]
            O.ShiftLeft->binary;O.ShiftRight->binary;O.Divide->binary
            O.FrameLoad->one [frame]
            O.FrameStore->none [word,frame]
            O.LoadByte->one [word,immediate]
            O.LoadField->one [word,immediate]
            O.StoreField->none [word,word,immediate]
            O.StoreHeader->none [word,word,immediate]
            O.Call->length ds<=1 && all word ds && transfer us
            O.Ret->none [word]
            O.Push->none [word]
            O.ApplyN->one [immediate]
            O.Panic->none [symbol]
            O.Enter->none []
            O.Save->none []
            O.FloatBinary _ _->binary
            O.FloatCompare _ _->binary
            O.TreeLeaf _->none [word,index 0 7]
            O.TreeNode _ _->none [index 0 6]
            O.TreeOutput _->one [index 0 7]
            O.TreeCompare _ _->one []
            O.PairLoad->none [word,index 8 8]
            O.PairStore->none [word,index 8 15]
            O.PairDuplicate->none [word,index 9 15]
            O.PairBinary _->none [index 9 15,index 8 15,index 8 15]
        one ps=matches [word] ds && matches ps us
        none ps=null ds && matches ps us
        binary=one [word,word]
    require "opcode/operand form mismatch" shape
    require "opcode/control effect mismatch" (siControl i==control (siOpcode i) us)
    require "opcode/flag effect mismatch" (siFlags i==flags (siOpcode i))
    require "opcode/call metadata mismatch" (calls (siOpcode i) us (siCalls i))
    require "opcode/register constraint mismatch" (registers (siOpcode i) ds us
      && (siOpcode i/=O.X64 O.Divide || Phys "rdx" `elem` siImplicitDefs i))
  where
    matches ps xs=length ps==length xs && and (zipWith ($) ps xs)
    word (OV _ (Any FPR))=False
    word (OV _ _)=True
    word (OP (Phys p))=p `elem` ["rax","rbx","rcx","rdx","rsi","rdi","rsp","rbp"]++["r"++show n | n<-[8::Int ..15]]
    word _=False
    immediate (OI _)=True;immediate _=False
    index lo hi (OI n)=n>=lo && n<=hi;index _ _ _=False
    argumentCell (OC _)=True;argumentCell _=False
    symbol (OAddr a)=not (null (addressName a));symbol _=False
    label (OL _)=True;label _=False
    frame (OF _ 0)=True;frame _=False
    transfer (OCode _:args)=length args<=6 && all word args
    transfer _=False
    entry ds us=length ds<=6 && all word ds && ds==us
    fixed name (OV _ (Fix (Phys p)))=p==name
    fixed name (OP (Phys p))=p==name
    fixed _ _=False
    arguments args=and (zipWith fixed ["rdi","rsi","rdx","rcx","r8","r9"] args)
    tied [OV _ (Tied 0)] (OV _ _:_) = True
    tied [d@(OP _)] (u:_) = d==u
    tied _ _ = False
    registers op ds us=case op of
      O.X64 O.Divide->all (fixed "rax") ds && case us of a:_->fixed "rax" a;_->False
      O.X64 O.ShiftLeft->tied ds us && fixed "rcx" (last us)
      O.X64 O.ShiftRight->tied ds us && fixed "rcx" (last us)
      O.X64 (O.Select _)->tied ds us
      O.X64 O.Call->all (fixed "rax") ds && arguments (drop 1 us)
      O.Common O.TailJump->arguments (drop 1 us)
      O.X64 O.Ret->all (fixed "rax") us
      O.X64 x | x `elem` [O.Add,O.Subtract,O.Multiply,O.And,O.Or,O.Xor,O.ShiftLeftImmediate,
          O.ShiftRightArithmeticImmediate,O.OrImmediate,O.AndImmediate,O.XorImmediate,O.SignExtend63]->tied ds us
      _->True
    calls op us cs=callMetadata op (case op of O.X64 O.Call->DirectCall;_->NoCall) us cs
    control op us=case Protocol.embedded op of
      Just protocol->Protocol.protocolControl protocol
      Nothing->ordinaryControl op us
    ordinaryControl op us=case (op,us) of
      (O.Common O.TailJump,_)->Return
      (O.Common O.JumpLoop,[OL l])->JumpTo l
      (O.X64 O.Ret,_)->Return
      (O.X64 O.Jump,[OL l])->JumpTo l
      (O.X64 (O.Branch _),[OL l])->CondTo [l]
      (O.X64 O.BranchZero,[_,OL l])->CondTo [l]
      (O.X64 O.BranchNonzero,[_,OL l])->CondTo [l]
      _->Next
    flags op=case Protocol.embedded op of
      Just protocol->Protocol.protocolFlags Calling.X86_64 protocol
      Nothing->ordinaryFlags op
    ordinaryFlags op=case op of
      O.X64 x->case x of
        O.Set _->FlagsUse;O.Select _->FlagsUse;O.Branch _->FlagsUse
        O.FloatCompare _ _->FlagsDef;O.TreeCompare _ _->FlagsDef
        _ | x `elem` [O.Add,O.Subtract,O.Multiply,O.And,O.Or,O.Xor,O.ShiftLeftImmediate,
              O.ShiftRightArithmeticImmediate,O.OrImmediate,O.AndImmediate,O.XorImmediate,
              O.SignExtend63,O.ShiftLeft,O.ShiftRight,O.Divide,O.Compare,O.CompareImmediate,
              O.BranchZero,O.BranchNonzero,O.Call]->FlagsDef
        _->FlagsNone
      _->FlagsNone
