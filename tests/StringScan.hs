module Main where
import Core.Syntax
import Codegen.IR
import Codegen.Policy
import Codegen.Lower (lowerProgram,Prim(..))
import Codegen.Simplify (simplifyProgramWith,policyOptions)
import Codegen.StringScan (versionScan)
import Codegen.ControlFlow (analyze,naturalLoops,loopBlocks)
import Codegen.Verify (verifyProgramWidth)
import Codegen.Eval
import Control.Monad (unless,forM_)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

check label ok=unless ok (error ("StringScan: "++label))
right=either error id
app n=foldl CApp (CVar n)
hal=M.singleton "charAt" (Prim 2 (Just "fpr_g_charAt_call2") Nothing)
scan cmp step changing = (["s","i","n","acc"],
  CIf (app cmp [CVar "i",CVar "n"]) (CVar "acc")
    (app "scan" [CVar "s",app "+" [CVar "i",step],
      if changing then app "-" [CVar "n",CInt 1] else CVar "n",
      app "+" [CVar "acc",app "charAt" [CVar "s",CVar "i"]]]))
twoLatches stride = (["s","i","n","acc"],
  CIf (app ">=" [CVar "i",CVar "n"]) (CVar "acc")
    (CIf (app "==" [CVar "i",CInt 0]) (recur 1) (recur stride)))
  where recur step=app "scan" [CVar "s",app "+" [CVar "i",CInt step],CVar "n",
                               app "+" [CVar "acc",app "charAt" [CVar "s",CVar "i"]]]
policy=m2Policy {polEarlyLoops=True}
lower p body=let src=M.singleton "scan" body;(ir,failures)=lowerProgram p M.empty src src M.empty hal
             in if null failures then ir else error (show failures)
simplify p = fst . right . simplifyProgramWith (policyOptions p)
ops fn=[o | b<-fnBlocks fn,Instr _ o<-bInstrs b]

main=do
  let original=simplify policy (lower policy (scan ">=" (CInt 1) False))
      fast=simplify (policy {polStringScan=True}) (lower policy (scan ">=" (CInt 1) False))
      a=original M.! "scan"; b=fast M.! "scan"
  check "both verify" (all ((==Right ()) . verifyProgramWidth W64) [original,fast])
  check "version created" (length (fnBlocks b)>length (fnBlocks a))
  check "idempotent" (versionScan b==b)
  let loops=naturalLoops b (analyze b)
      loopOps l=[o | block<-fnBlocks b,S.member (bId block) (loopBlocks l),Instr _ o<-bInstrs block]
      calls l=[c | OCall c _<-loopOps l,calleeName c=="charAt"]
  check "checked and fast loops coexist" (length loops==2 && any (null . calls) loops && any (not . null . calls) loops)
  check "fast loop keeps accumulator overflow check" (all (any (\o->case o of OArith Add _ _->True;_->False) . loopOps) loops)
  check "fast loop has no descriptor reload or type test" (any (\l->null (calls l) && not (any descriptor (loopOps l))) loops)
  -- Exhaustive small domains include arbitrary callers, all bytes, early exits,
  -- bounds misses after several successful iterations, and wrong String values.
  let strings=[RString [],RString [0],RString [1,127,128,255],RInt 7,RObj 42 0 []]
      (_,hi)=intBounds W64
      indices=[-2,-1,0,1,2,3,4,5,hi-1,hi]
      accumulators=[-3,0,hi-255,hi-1,hi]
  forM_ strings $ \s->forM_ indices $ \i->forM_ indices $ \n->forM_ accumulators $ \acc->do
    let args=[s,RInt i,RInt n,RInt acc]
        before=evalProgram original "scan" args
        after=evalProgram fast "scan" args
    check ("exact outcome/events "++show args) (before==after)
    check "evaluator actually executes" (case ocResult after of Left (Stuck _)->False;_->True)
    if i>=n then check "zero trip returns even for invalid String" (ocResult after==Right (RInt acc)) else pure ()
  -- The proof must not depend on the earlier interval pass having run, and
  -- invariant motion may change where the harmless definitions are placed.
  forM_ [policy {polInterval=False},policy {polLoopMotion=True}] $ \p->do
    let before=simplify p (lower p (scan ">=" (CInt 1) False))
        after=simplify (p {polStringScan=True}) (lower p (scan ">=" (CInt 1) False))
    check "option composition verifies" (verifyProgramWidth W64 after==Right ())
    forM_ [[RString [1,2,3],RInt 0,RInt 3,RInt 0],
           [RString [1],RInt 0,RInt 1,RInt hi],
           [RString [1],RInt (-1),RInt 1,RInt 0]] $ \args->
      check "option composition exact outcome/events" (evalProgram before "scan" args==evalProgram after "scan" args)
  check "independent sum" (ocResult (evalProgram fast "scan" [RString [1,127,128,255],RInt 0,RInt 4,RInt 0])==Right (RInt 511))
  check "independent accumulator overflow" (case ocResult (evalProgram fast "scan" [RString [1],RInt 0,RInt 1,RInt hi]) of Left (Trap _)->True;_->False)
  forM_ [("inclusive",scan ">" (CInt 1) False),("stride two",scan ">=" (CInt 2) False),
         ("descending",scan ">=" (CInt (-1)) False),("changing bound",scan ">=" (CInt 1) True),
         ("mixed backedges",scan ">=" (CIf (app "==" [CVar "i",CInt 0]) (CInt 1) (CInt 2)) False)] $ \(label,body)->do
    let plain=simplify policy (lower policy body)
        candidate=simplify (policy {polStringScan=True}) (lower policy body)
    check (label++" refuses") (plain==candidate)
  forM_ [1,2] $ \stride->do
    let before=simplify policy (lower policy (twoLatches stride))
        after=simplify (policy {polStringScan=True}) (lower policy (twoLatches stride))
    check "both backedges verify" (verifyProgramWidth W64 after==Right ())
    check "every backedge must prove unit stride" ((before/=after)==(stride==1))
    forM_ [[RString [1,2,3,4],RInt 0,RInt 4,RInt 0],
           [RString [1],RInt 0,RInt 2,RInt 0]] $ \args->
      check "two-latch outcomes/events" (evalProgram before "scan" args==evalProgram after "scan" args)
  let inclusive=simplify (policy {polStringScan=True}) (lower policy (scan ">" (CInt 1) False))
  check "index overflow precedes invalid string" (case ocResult (evalProgram inclusive "scan" [RInt 9,RInt hi,RInt hi,RInt 0]) of
      Left (Trap message)->take 12 message=="Int overflow";_->False)
  forM_ [policy {polProfile=Rv32},policy {polStringFast=False},policy {polEarlyLoops=False}] $ \p->do
    let plain=simplify p (lower p (scan ">=" (CInt 1) False))
        candidate=simplify (p {polStringScan=True}) (lower p (scan ">=" (CInt 1) False))
    check "unsupported lowering unchanged" (plain==candidate)
  putStrLn "StringScan: guarded version, 2500 exact evaluator outcomes/events, bounds/overflow/zero-trip/refusal proofs PASS"
  where descriptor o=case o of OLoad {}->True;OTagTest {}->True;OIsInt {}->True;_->False
