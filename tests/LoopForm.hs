module Main where
import Codegen.IR
import Codegen.Policy
import Codegen.LoopForm
import Codegen.ControlFlow
import Codegen.Lower (lowerProgram)
import Codegen.Simplify
import Codegen.Verify
import Codegen.Eval
import Core.Syntax
import Control.Monad (forM_,unless)
import qualified Data.Map.Strict as M

check label ok=unless ok (error ("early loops: "++label))
app n=foldl CApp (CVar n)
v=CVar
-- Swapping loop-carried values exercises parallel assignment; limit and
-- divisor are invariant, while both branches are independent back edges.
prog=M.fromList
  [("loop",(["i","limit","a","b","divisor"],
     CIf (app ">=" [v "i",v "limit"]) (v "a")
       (CLet "q" (app "/" [v "a",v "divisor"])
         (CIf (app "<" [v "i",CInt 2])
           (app "loop" [app "+" [v "i",CInt 1],v "limit",v "b",v "a",v "divisor"])
           (app "loop" [app "+" [v "i",CInt 1],v "limit",v "b",v "a",v "divisor"]))))),
   ("over",(["i","limit"],CIf (app ">" [v "i",v "limit"]) (v "i")
     (app "over" [app "+" [v "i",CInt 1],v "limit"]))),
   ("fib",(["n"],CIf (app "<" [v "n",CInt 2]) (v "n")
     (app "+" [app "fib" [app "-" [v "n",CInt 1]],app "fib" [app "-" [v "n",CInt 2]]])))]
lower policy=case lowerProgram policy M.empty prog prog M.empty M.empty of
  (ir,[])->ir
  (_,failures)->error (show failures)
-- Stack probes are resource checks: the existing machine loop already
-- checks its one frame only once. Every other event must match exactly.
semantic o=o {ocEvents=[e | e<-ocEvents o,case e of EvStackCheck _->False;_->True]}

main=do
  forM_ [m2Policy,m2Policy {polProfile=Rv32},
         m2Policy {polProfile=Builtin,polFuel=False,polStackCheck=StackStatic},
         m2Policy {polProfile=Builtin32,polFuel=False,polStackCheck=StackStatic}] $ \policy->do
    let enabled=policy {polEarlyLoops=True}
        slow=lower policy
        early=lower enabled
        width=policyWidth policy
        f=early M.! "loop"
        old=slow M.! "loop"
        loops=naturalLoops f (analyze f)
        optimized=fst (either error id (simplifyProgramWith (policyOptions enabled {polLoopMotion=True}) early))
    check "formed and optimized programs verify" (all ((==Right ()) . verifyProgramWidth width) [early,optimized])
    check "recursive loop has a real preheader" (case loops of [l]->loopPreheader l==Just (fnEntry f);_->False)
    check "entry still has all ABI parameters" (length (bParams (head (fnBlocks f)))==5)
    check "only changing parameters are carried" (case loops of [l]->[length (bParams b) | b<-fnBlocks f,bId b==loopHeader l]==[3];_->False)
    check "two back edges are retained" (length [() | b<-fnBlocks f, TBr t _<-[bTerm b],t==fnEntry old,bId b/=fnEntry f]==2)
    check "disabled and repeated formation are identities" (formSelfLoop policy old==old && formSelfLoop enabled f==f)
    check "ordinary recursion stays ordinary" (early M.! "fib"==slow M.! "fib")
    forM_ [0,1,2,9] $ \n->forM_ [0,1,3] $ \divisor->do
      let args=map RInt [0,n,7,11,divisor]
          original=evalProgramWidth width slow "loop" args
          result=evalProgramWidth width early "loop" args
      check "values, argument order, traps and fuel match" (semantic original==semantic result)
      check "simplification preserves exact events" (result==evalProgramWidth width optimized "loop" args)
      check "one stack check per frame" (length [() | EvStackCheck _<-ocEvents result]==if polStackCheck policy==StackStatic then 0 else 1)
      whenSuccess n divisor result
    let hi=snd (intBounds width)
    forM_ [("loop",map RInt [hi-1,hi,7,11,1]),("over",map RInt [hi-1,hi])] $ \(name,args)->
      check "integer boundary/trap differential" (semantic (evalProgramWidth width slow name args)==semantic (evalProgramWidth width optimized name args))
    let conditional=old {fnBlocks=[if bId b==fnEntry old then b {bTerm=TCondBr (VId 999) (fnEntry old) [] (fnEntry old) []} else b | b<-fnBlocks old]}
    check "unsupported entry edge is unchanged" (formSelfLoop enabled conditional==conditional)
  putStrLn "Early loops: verified preheaders, invariant parameters, parallel swaps, two latches, width boundaries, ordered traps, fuel and conservative fallback PASS"
  where
    whenSuccess n divisor result
      | divisor/=0 || n==0=check "independent swap answer" (ocResult result==Right (RInt (if even n then 7 else 11)))
      | otherwise=check "division trap retained" (case ocResult result of Left (Trap _)->True;_->False)
