{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Shared operand and protocol checks. ISA form checkers retain responsibility
-- for their own operation/flag vocabulary and register-file authority.
module Codegen.Target.Forms
  (matches,register,immediate,index,symbol,label,frame,fixed,arguments,
   commonShape,CallForm(..),callMetadata) where
import Codegen.Selected
import qualified Codegen.Opcode as O

matches ps xs=length ps==length xs && and (zipWith ($) ps xs)
register rf cls operand=case operand of
  OV _ (Any k)->k==cls
  OV _ (Fix p)->rfClassOf rf p==Just cls
  OP p->rfClassOf rf p==Just cls
  _->False
immediate (OI _)=True;immediate _=False
index lo hi (OI n)=n>=lo && n<=hi;index _ _ _=False
symbol (OS _)=True;symbol _=False
label (OL _)=True;label _=False
frame (OF _ 0)=True;frame _=False
fixed wanted (OV _ (Fix actual))=wanted==actual
fixed wanted (OP actual)=wanted==actual
fixed _ _=False
arguments bank args=length args<=length bank && and (zipWith fixed bank args)

commonShape rf bank static op ds us=case op of
  O.EntryCheckTick->entry
  O.EntryCheck->entry
  O.EntryTick->entry
  O.EntryStatic->static && null ds && null us
  O.TickN->null ds && matches [immediate] us
  O.TailJump->null ds && case us of OS _:args->arguments bank args;_->False
  O.JumpLoop->null ds && matches [label] us
  O.LoadSpill->matches [register rf GPR] ds && matches [immediate] us
  O.StoreSpill->null ds && matches [register rf GPR,immediate] us
  O.Params->arguments bank ds && null us
  O.LoadCell->False
  O.StoreCell->False
  O.SavesHere->False -- an internal shrink-wrap marker, removed before emission
  where entry=ds==us && arguments bank ds

data CallForm=DirectCall | ApplyCall | PanicCall | NoCall deriving (Eq,Show)

-- Ordinary ISA call/return constructors are interpreted by the caller. Shared
-- protocol metadata is checked here, including the order of runtime events.
callMetadata opcode form us cs=case opcode of
  O.Common O.TailJump->target
  O.Common O.EntryCheckTick->cs==[Call "fpr_stack_grow" False True,Call "fpr_fuel_exhausted" True False]
  O.Common O.EntryCheck->cs==[Call "fpr_stack_grow" False True]
  O.Common O.EntryTick->cs==[Call "fpr_fuel_exhausted" True False]
  O.Common O.TickN->cs==[Call "fpr_fuel_exhausted" True False]
  _ ->case form of
    DirectCall->target
    ApplyCall->cs==[Call "fpr_applyN" False True]
    PanicCall->cs==[Call "fpr_panic" False True]
    NoCall->null cs
  where target=case (us,cs) of (OS name:_,[c])->callTarget c==name;_->False
