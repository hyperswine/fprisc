-- Internal region operations and physical bundle layouts have one renderer.
-- These names are runtime ABI, not source-level polymorphic declarations.
module Core.Region.Runtime (Hook(..),hookName,packState) where
import Core.Syntax (Core(..))
import Compiler.DataLayout (tupWideBase)
data Hook=CallPending | CallLeave | LoopLeave | SequenceNumber | Open | PoolMark | HasRoom | Cycle | ReceiveLoop
  deriving (Eq,Ord,Show)
hookName h=case h of
  CallPending->"$callPend";CallLeave->"$callLeave";LoopLeave->"$loopLeave"
  SequenceNumber->"$regionSeq";Open->"$regionOpen";PoolMark->"$regionMark";HasRoom->"$regionRoom"
  Cycle->"$regionCycle";ReceiveLoop->"$receiveLoop"
packState []=CInt 0
packState [x]=x
packState xs=CMk (case length xs of 2->4;3->5;n | n<=8->n+6;n->tupWideBase+n) 0 xs
