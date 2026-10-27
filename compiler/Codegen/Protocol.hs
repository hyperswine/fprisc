{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Existing embedded runtime protocols. One owner supplies and checks their
-- effects; target renderers retain the actual instruction sequences.
module Codegen.Protocol (Embedded(..),EntryChecks(..),entryChecks,entryOpcode,embedded,protocolCalls,protocolFlags,protocolControl,selectProtocol,checkProtocols) where
import Codegen.Selected
import Codegen.Call
import Codegen.Calling (ABI(..),argumentRegisters,resultRegister,callerClobbers)
import qualified Codegen.Opcode as O
import qualified Codegen.Opcode.A64 as A
import qualified Codegen.Opcode.RV as R
import Control.Monad (unless,forM_,when)
import Data.List (sort)

data EntryChecks = StackAndFuel | StackOnly | FuelOnly deriving (Eq,Ord,Show)
entryChecks :: Bool -> Bool -> Maybe EntryChecks
entryChecks stack fuel=case (stack,fuel) of
  (True,True)->Just StackAndFuel
  (True,False)->Just StackOnly
  (False,True)->Just FuelOnly
  (False,False)->Nothing
entryOpcode :: EntryChecks -> O.CommonOp
entryOpcode checks=case checks of StackAndFuel->O.EntryCheckTick;StackOnly->O.EntryCheck;FuelOnly->O.EntryTick

data Embedded = CheckAndTick | CheckStack | Tick | CountedTick | StaticEntry | Apply | Panic | PushArgument deriving (Eq,Ord,Show)
embedded :: O.Opcode -> Maybe Embedded
embedded opcode=case opcode of
  O.Common op->case op of
    O.EntryCheckTick->Just CheckAndTick
    O.EntryCheck->Just CheckStack
    O.EntryTick->Just Tick
    O.TickN->Just CountedTick
    O.EntryStatic->Just StaticEntry
    _->Nothing
  O.X64 O.ApplyN->Just Apply;O.X64 O.Panic->Just Panic;O.X64 O.Push->Just PushArgument
  O.A64 A.ApplyN->Just Apply;O.A64 A.Panic->Just Panic;O.A64 A.Push->Just PushArgument
  O.RV R.ApplyN->Just Apply;O.RV R.Panic->Just Panic;O.RV R.Push->Just PushArgument
  _->Nothing
protocolCalls :: Embedded -> [Call]
protocolCalls protocol=map runtimeEvent $ case protocol of
  CheckAndTick->[GrowStackEntry,FuelEntry]
  CheckStack->[GrowStackEntry]
  Tick->[FuelSaveEntry]
  CountedTick->[FuelSaveEntry]
  Apply->[ApplyEntry]
  Panic->[PanicEntry]
  StaticEntry->[]
  PushArgument->[]

-- Definitions on forwarded entry pseudos are preserved around their slow
-- calls. A result definition is likewise not a clobbered value.
selectProtocol :: ABI -> SInstr -> SInstr
selectProtocol abi instr=case embedded (siOpcode instr) of
  Nothing->instr
  Just protocol->instr
    {siImplicitDefs=implicitDefs abi protocol,siImplicitUses=implicitUses abi protocol,
     siClobbers=clobbers abi protocol (siDefs instr),siFlags=protocolFlags abi protocol,
     siControl=protocolControl protocol,siCalls=protocolCalls protocol}

entry :: Embedded -> Bool
entry protocol=protocol `elem` [CheckAndTick,CheckStack,Tick,CountedTick]
implicitDefs :: ABI -> Embedded -> [Phys]
implicitDefs abi protocol=map Phys $ case protocol of
  StaticEntry->[]
  PushArgument->case abi of X86_64->["rsp"];_->["sp"]
  Apply->case abi of AArch64->["x1","x2","sp"];X86_64->["rdi","rsi","rdx","rsp"];RiscV->["a1","a2","sp","t6"]
  Panic->case abi of AArch64->["x0"];X86_64->["rdi","rsp"];RiscV->["a0"]
  _->case abi of AArch64->["x9","x10","x11","sp"];X86_64->["r10","r11","rax","rsp"];RiscV->["t3","t4","t5","sp"]
implicitUses :: ABI -> Embedded -> [Phys]
implicitUses abi protocol
  | entry protocol=case abi of AArch64->[Phys "x28"];RiscV->[Phys "tp"];X86_64->[]
  | otherwise=[]
protocolFlags :: ABI -> Embedded -> Flags
protocolFlags abi protocol
  | abi/=RiscV && (entry protocol || protocol==Apply)=FlagsDef
  | otherwise=FlagsNone
protocolControl :: Embedded -> Control
protocolControl Panic=Return
protocolControl _=Next
physical :: Operand -> Maybe Phys
physical (OV _ (Fix p))=Just p
physical (OP p)=Just p
physical _=Nothing
clobbers :: ABI -> Embedded -> [Operand] -> [Phys]
clobbers abi protocol defs
  | protocol `elem` [StaticEntry,PushArgument]=[]
  -- a tick's slow path goes through the unit's register-saving wrapper
  -- (fpr_fuel_save_local): nothing allocatable is clobbered
  | protocol `elem` [Tick,CountedTick]=[]
  | otherwise=filter (`notElem` [p | d<-defs,Just p<-[physical d]]) (callerClobbers abi)

checkProtocols :: ABI -> String -> [Item] -> Either String ()
checkProtocols abi owner items=do
  checkPackets owner items
  forM_ [i | I i<-items,Just _<-[embedded (siOpcode i)]] $ \i->case embedded (siOpcode i) of
    Nothing->pure ()
    Just protocol->do
      let bad why=Left ("selected runtime protocol "++owner++" "++siOp i++": "++why)
          require why yes=unless yes (bad why)
          fixed p operand=physical operand==Just p
          params ds=length ds<=length (argumentRegisters abi) && and (zipWith fixed (argumentRegisters abi) ds)
          shape=case protocol of
            PushArgument->null (siDefs i) && case siUses i of [OV _ _]->True;[OP _]->True;_->False
            StaticEntry->abi==RiscV && null (siDefs i) && null (siUses i)
            Apply->case (siDefs i,siUses i) of ([d],[OI n])->fixed (resultRegister abi) d && n>=1;_->False
            Panic->null (siDefs i) && case siUses i of [OAddr (StaticObject _)]->True;_->False
            CountedTick->null (siDefs i) && case siUses i of [OI n]->n>=1;_->False
            _->siDefs i==siUses i && params (siDefs i)
      require "operand/target contract mismatch" shape
      require "runtime event contract mismatch" (siCalls i==protocolCalls protocol)
      require "implicit register contract mismatch" (sort (siImplicitDefs i)==sort (implicitDefs abi protocol) && sort (siImplicitUses i)==sort (implicitUses abi protocol))
      require "caller clobber contract mismatch" (sort (siClobbers i)==sort (clobbers abi protocol (siDefs i)))
      require "flag/control contract mismatch" (siFlags i==protocolFlags abi protocol && siControl i==protocolControl protocol)

-- Apply consumes the head plus every argument, each in a 16-byte cell. The
-- selector evaluates them first; allocation may insert neutral register/slot
-- transfers, but no call or control boundary may split the staged packet.
checkPackets :: String -> [Item] -> Either String ()
checkPackets owner=go 0
  where
    require why yes=unless yes (Left ("selected runtime protocol "++owner++": argument packet "++why))
    go pending []=require "is unterminated" (pending==0)
    go pending (ILabel _:rest)=require "crosses a label" (pending==0) >> go 0 rest
    go pending (I i:rest)=case embedded (siOpcode i) of
      Just PushArgument->go (pending+1) rest
      Just Apply->do
        require "does not match the apply count" (case siUses i of [OI n]->pending==n+1;_->False)
        go 0 rest
      _->do
        when (not (null (siCalls i)) || siControl i/=Next) (require "crosses a call/control boundary" (pending==0))
        go pending rest
