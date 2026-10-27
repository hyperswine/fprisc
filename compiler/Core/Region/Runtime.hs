-- Internal region operations and physical bundle layouts have one renderer.
-- These names are runtime ABI, not source-level polymorphic declarations.
module Core.Region.Runtime (Hook(..),hookName,packState,receiveReady) where
import Core.Syntax (Core(..))
import Core.Region.Syntax (ReceiveProbe(..))
import Compiler.DataLayout (tupWideBase)
data Hook=CallPending | CallLeave | LoopLeave | SequenceNumber | Open | PoolMark | HasRoom | ReceiveReady | Cycle | ReceiveLoop
  deriving (Eq,Ord,Show)
hookName h=case h of
  CallPending->"$callPend";CallLeave->"$callLeave";LoopLeave->"$loopLeave"
  SequenceNumber->"$regionSeq";Open->"$regionOpen";PoolMark->"$regionMark";HasRoom->"$regionRoom"
  ReceiveReady->"$receiveReady"
  Cycle->"$regionCycle";ReceiveLoop->"$receiveLoop"
-- Mirrors the runtime's fpr_receive_probe enum. This observes readiness; it
-- cannot take a message or evaluate a source-level sender expression.
receiveReady probe params=foldl CApp (CVar (hookName ReceiveReady)) [CInt mode,peer]
  where
    (mode,peer)=case probe of
      UnknownReceive->(0,CInt 0);AnyMessage->(1,CInt 0)
      SenderMessage i->(2,CVar (params!!i))
      SenderMessageOrDead i->(3,CVar (params!!i))
      ResultMessage->(4,CInt 0);NonBlocking->(5,CInt 0)
packState []=CInt 0
packState [x]=x
packState xs=CMk (case length xs of 2->4;3->5;n | n<=8->n+6;n->tupWideBase+n) 0 xs
