module Main where
import Core.Syntax
import Codegen.IR
import Codegen.Policy
import Codegen.Lower (lowerProgram)
import Codegen.Simplify (Options(..),simplifyProgramWith,simplifyFnWith)
import Codegen.Verify (verifyProgramWidth,verifyFn)
import Codegen.Eval
import Control.Monad (unless,forM_)
import qualified Data.Map.Strict as M

check label ok=unless ok (error ("interval: "++label))
app n=foldl CApp (CVar n)

-- count i n acc = if i >= n then acc else count (i + 1) n (acc + i)
-- over i n acc = if i > n then acc else over (i + 1) n acc   (i can reach maxInt: i + 1 must stay checked)
-- fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)
-- twice i n = if i < n then (if i < n then 1 else 2) else 0
prog=M.fromList
  [("count",(["i","n","acc"],CIf (app ">=" [CVar "i",CVar "n"]) (CVar "acc")
      (app "count" [app "+" [CVar "i",CInt 1],CVar "n",app "+" [CVar "acc",CVar "i"]]))),
   ("over",(["i","n","acc"],CIf (app ">" [CVar "i",CVar "n"]) (CVar "acc")
      (app "over" [app "+" [CVar "i",CInt 1],CVar "n",CVar "acc"]))),
   ("fib",(["n"],CIf (app "<" [CVar "n",CInt 2]) (CVar "n")
      (app "+" [app "fib" [app "-" [CVar "n",CInt 1]],app "fib" [app "-" [CVar "n",CInt 2]]]))),
   ("twice",(["i","n"],CIf (app "<" [CVar "i",CVar "n"])
      (CIf (app "<" [CVar "i",CVar "n"]) (CInt 1) (CInt 2)) (CInt 0)))]
lowered=let (ir,failures)=lowerProgram m2Policy M.empty prog prog M.empty M.empty
  in if null failures then ir else error (show failures)
on =Options False Nothing True (Just W64) False
off=Options False Nothing True Nothing False
simplified o=fst (either error id (simplifyProgramWith o lowered))
operations fn=[op | b<-fnBlocks fn,Instr _ op<-bInstrs b]
unchecked fn=[() | OArithU {} <- operations fn]
condbrs fn=[() | b<-fnBlocks fn,TCondBr {}<-[bTerm b]]
maxI=4611686018427387903 :: Integer

-- Both outcomes enter b1. Having one predecessor block does not establish
-- either i < n or i >= n there. In particular i=maxInt must still trap.
sameDestination=Fn "sameDestination" ["i","n"] TInt (BId 0)
  [Block (BId 0) [(VId 0,TVal),(VId 1,TVal)]
     [Instr (Just (VId 2,TInt)) (OUntag (VId 0)),
      Instr (Just (VId 3,TInt)) (OUntag (VId 1)),
      Instr (Just (VId 4,TPred)) (OCmp Lt (VId 2) (VId 3))]
     (TCondBr (VId 4) (BId 1) [] (BId 1) []),
   Block (BId 1) []
     [Instr (Just (VId 5,TInt)) (OConstInt 1),
      Instr (Just (VId 6,TInt)) (OArith Add (VId 2) (VId 5))]
     (TRet (VId 6))]

-- Arithmetic step fact propagation: after `v1 = i + 2` and `v1 <= n`, `i + 1`
-- in the dominated arm has `i <= n - 2 <= maxInt - 2` and discharges to OArithU,
-- while `v1 = i + 2` in the entry before the guard stays checked.
stepChainFn=Fn "stepChain" ["i","n"] TInt (BId 0)
  [Block (BId 0) [(VId 0,TInt),(VId 1,TInt)]
     [Instr (Just (VId 2,TInt)) (OConstInt 2),
      Instr (Just (VId 3,TInt)) (OArith Add (VId 0) (VId 2)),
      Instr (Just (VId 4,TPred)) (OCmp Le (VId 3) (VId 1))]
     (TCondBr (VId 4) (BId 1) [] (BId 2) []),
   Block (BId 1) []
     [Instr (Just (VId 5,TInt)) (OConstInt 1),
      Instr (Just (VId 6,TInt)) (OArith Add (VId 0) (VId 5)),
      Instr (Just (VId 7,TPred)) (OCmp Le (VId 6) (VId 1))]
     (TCondBr (VId 7) (BId 3) [] (BId 2) []),
   Block (BId 2) [] [Instr (Just (VId 8,TInt)) (OConstInt 0)] (TRet (VId 8)),
   Block (BId 3) [] [] (TRet (VId 6))]

-- Acyclic join-block fact intersection: both arms of b0 establish `i < n`
-- before jumping to join block b3, so `i + 1` in b3 discharges to OArithU.
joinIntersectFn=Fn "joinIntersect" ["c","i","n"] TInt (BId 0)
  [Block (BId 0) [(VId 0,TPred),(VId 1,TInt),(VId 2,TInt)]
     [Instr (Just (VId 3,TPred)) (OCmp Lt (VId 1) (VId 2))]
     (TCondBr (VId 0) (BId 1) [] (BId 2) []),
   Block (BId 1) [] [] (TCondBr (VId 3) (BId 3) [] (BId 4) []),
   Block (BId 2) [] [] (TCondBr (VId 3) (BId 3) [] (BId 4) []),
   Block (BId 3) []
     [Instr (Just (VId 4,TInt)) (OConstInt 1),
      Instr (Just (VId 5,TInt)) (OArith Add (VId 1) (VId 4))]
     (TRet (VId 5)),
   Block (BId 4) [] [Instr (Just (VId 6,TInt)) (OConstInt 0)] (TRet (VId 6))]

-- Natural-loop induction lower bound + cross-block pure sharing:
-- b0 enters header b1 with i = 0; b1 checks i < n; b2 checks i >= 0 (proven by
-- non-decreasing induction i >= 0), increments i' = i + 1 (proven by i < n),
-- and repeats `OUntag v0` which shares b0's dominating `OUntag v0`.
loopInductFn=Fn "loopInduct" ["box","n"] TInt (BId 0)
  [Block (BId 0) [(VId 0,TVal),(VId 1,TInt)]
     [Instr (Just (VId 2,TInt)) (OUntag (VId 0)),
      Instr (Just (VId 3,TInt)) (OConstInt 0)]
     (TBr (BId 1) [VId 3,VId 2]),
   Block (BId 1) [(VId 4,TInt),(VId 5,TInt)]
     [Instr (Just (VId 6,TPred)) (OCmp Lt (VId 4) (VId 1))]
     (TCondBr (VId 6) (BId 2) [] (BId 3) []),
   Block (BId 2) []
     [Instr (Just (VId 7,TInt)) (OConstInt 0),
      Instr (Just (VId 8,TPred)) (OCmp Ge (VId 4) (VId 7))]
     (TCondBr (VId 8) (BId 4) [] (BId 3) []),
   Block (BId 3) [] [] (TRet (VId 5)),
   Block (BId 4) []
     [Instr (Just (VId 9,TInt)) (OUntag (VId 0)),
      Instr (Just (VId 10,TInt)) (OConstInt 1),
      Instr (Just (VId 11,TInt)) (OArith Add (VId 4) (VId 10)),
      Instr (Just (VId 12,TInt)) (OArithU Add (VId 5) (VId 9))]
     (TBr (BId 1) [VId 11,VId 12])]

-- Non-negative producer bounds: OStrLen s >= 0 and BAnd x 255 in 0..255.
producerBoundsFn=Fn "producerBounds" ["s","x"] TInt (BId 0)
  [Block (BId 0) [(VId 0,TVal),(VId 1,TInt)]
     [Instr (Just (VId 2,TInt)) (OStrLen (VId 0)),
      Instr (Just (VId 3,TInt)) (OConstInt 0),
      Instr (Just (VId 4,TPred)) (OCmp Ge (VId 2) (VId 3))]
     (TCondBr (VId 4) (BId 1) [] (BId 2) []),
   Block (BId 1) []
     [Instr (Just (VId 5,TInt)) (OConstInt 255),
      Instr (Just (VId 6,TInt)) (OBit BAnd (VId 1) (VId 5)),
      Instr (Just (VId 7,TInt)) (OConstInt 1),
      Instr (Just (VId 8,TInt)) (OArith Add (VId 6) (VId 7))]
     (TRet (VId 8)),
   Block (BId 2) [] [Instr (Just (VId 9,TInt)) (OConstInt (-1))] (TRet (VId 9))]

main=do
  forM_ [W32,W64] $ \width->do
    let original=M.singleton "sameDestination" sameDestination
        candidate=fst (either error id (simplifyProgramWith (Options False Nothing True (Just width) False) original))
        (lo,hi)=intBounds width
    check "convergent branch verifies before and after" (all ((==Right ()) . verifyProgramWidth width) [original,candidate])
    check "convergent branch cannot discharge overflow" (null (unchecked (candidate M.! "sameDestination")))
    forM_ [(0,1),(5,1),(hi,hi),(lo,lo)] $ \(i,n)->do
      let before=evalProgramWidth width original "sameDestination" [RInt i,RInt n]
          after=evalProgramWidth width candidate "sameDestination" [RInt i,RInt n]
      check "both outcomes preserve real answers and exact traps" (before==after)
      check "independent answer excludes a stuck evaluator" (if i==hi then case ocResult after of Left (Trap _)->True;_->False else ocResult after==Right (RInt (i+1)))
  let fast=simplified on
      slow=simplified off
  check "both pipelines verify" (verifyProgramWidth W64 fast==Right () && verifyProgramWidth W64 slow==Right ())
  check "count's guarded i + 1 discharges" (length (unchecked (fast M.! "count"))==1)
  check "nothing discharges without the pass" (all (null . unchecked) (M.elems slow))
  check "fib's two subtractions discharge" (length (unchecked (fast M.! "fib"))==2)
  check "the accumulator add keeps its check" (1==length [() | OArith Add _ _<-operations (fast M.! "count")])
  check "over's i + 1 can overflow at the last iteration: it keeps its check"
    (null (unchecked (fast M.! "over")))
  check "the twice-tested comparison's inner branch is threaded"
    (length (condbrs (fast M.! "twice"))==1 && length (condbrs (slow M.! "twice"))==2)
  -- Arithmetic step chains, join intersection, loop induction, producer bounds, and cross-block sharing
  let (stepSimpl,_)=either error id (simplifyFnWith on M.empty stepChainFn)
      (joinSimpl,_)=either error id (simplifyFnWith on M.empty joinIntersectFn)
      (loopSimpl,_)=either error id (simplifyFnWith on M.empty loopInductFn)
      (prodSimpl,_)=either error id (simplifyFnWith on M.empty producerBoundsFn)
  check "stepChain verifies and discharges dominated i + 1 and i + 1 <= n"
    (verifyFn M.empty stepSimpl==Right ()
     && length (unchecked stepSimpl)==1
     && length [() | OArith Add _ _<-operations stepSimpl]==1
     && length (condbrs stepSimpl)==1)
  check "joinIntersect verifies and discharges i + 1 after acyclic join"
    (verifyFn M.empty joinSimpl==Right () && length (unchecked joinSimpl)==1)
  check "loopInduct verifies, threads i >= 0 induction guard, discharges i + 1, and shares OUntag across blocks"
    (verifyFn M.empty loopSimpl==Right ()
     && length (condbrs loopSimpl)==1
     && length (unchecked loopSimpl)==2
     && length [() | OUntag _<-operations loopSimpl]==1)
  check "producerBounds verifies, threads OStrLen >= 0, and discharges masked add"
    (verifyFn M.empty prodSimpl==Right ()
     && null (condbrs prodSimpl)
     && length (unchecked prodSimpl)==1)
  -- the evaluator sees the same results, traps and texts before and after
  forM_ [("count",[RInt 0,RInt 1000000,RInt 0]),("count",[RInt 5,RInt 5,RInt 7]),
         ("fib",[RInt 20]),("twice",[RInt 3,RInt 4]),("twice",[RInt 9,RInt 4])] $ \(fn,args)->
    check (fn++" evaluates identically") (evalProgram lowered fn args==evalProgram fast fn args)
  check "count computes" (ocResult (evalProgram fast "count" [RInt 0,RInt 1000000,RInt 0])==Right (RInt 499999500000))
  check "overflow at the last iteration keeps the exact runtime trap"
    (case ocResult (evalProgram fast "over" [RInt (maxI-1),RInt maxI,RInt 0]) of
       Left (Trap reason)->"Int overflow" `prefix` reason; _->False)
  check "a discharged counter reaches maxInt exactly without trapping"
    (ocResult (evalProgram fast "count" [RInt (maxI-1),RInt maxI,RInt 0])==Right (RInt (maxI-1)))
  putStrLn "Interval discharge: guarded-counter proofs, step chains, join intersection, loop induction, producer bounds, cross-block sharing and evaluator differential PASS"
  where prefix p s=take (length p) s==p
