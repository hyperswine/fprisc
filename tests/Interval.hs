module Main where
import Core.Syntax
import Codegen.IR
import Codegen.Policy
import Codegen.Lower (lowerProgram)
import Codegen.Simplify (Options(..),simplifyProgramWith)
import Codegen.Verify (verifyProgramWidth)
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
on =Options False Nothing True (Just W64)
off=Options False Nothing True Nothing
simplified o=fst (either error id (simplifyProgramWith o lowered))
operations fn=[op | b<-fnBlocks fn,Instr _ op<-bInstrs b]
unchecked fn=[() | OArithU {} <- operations fn]
condbrs fn=[() | b<-fnBlocks fn,TCondBr {}<-[bTerm b]]
maxI=4611686018427387903 :: Integer

main=do
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
  putStrLn "Interval discharge: guarded-counter proofs, boundary refusal, branch threading and evaluator differential PASS"
  where prefix p s=take (length p) s==p
