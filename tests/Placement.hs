module Main where
import Codegen.IR
import Codegen.Policy
import Codegen.ControlFlow
import Codegen.Lower (lowerProgram)
import Codegen.Verify
import Codegen.Eval
import Core.Syntax
import Core.Primitives (entryTickName)
import Control.Monad (forM_,unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

check label ok=unless ok (error ("tick placement: "++label))
app n=foldl CApp (CVar n)
v=CVar
-- an inlined callee's entry tick, as Inline.hs leaves it
ticked b=CLet "$inlined.tick" (CApp (CVar entryTickName) (CInt 0)) b

prog=M.fromList
  [ -- a self tail loop with an inlined callee in the body and one in the exit arm
    ("loop",(["n","a"],CIf (app "==" [v "n",CInt 0]) (ticked (app "+" [v "a",CInt 1]))
       (ticked (app "loop" [app "-" [v "n",CInt 1],app "+" [v "a",v "n"]])))),
    -- recursion that is not a loop: direct calls to itself in argument position
    ("tree",(["n"],CIf (app "<" [v "n",CInt 2]) (v "n")
       (ticked (app "+" [app "tree" [app "-" [v "n",CInt 1]],app "tree" [app "-" [v "n",CInt 2]]])))),
    -- no recursion: the inlined tick stays, fuel counts the call
    ("helper",(["n"],ticked (app "+" [v "n",CInt 1]))),
    -- a self loop whose body is above the bound keeps its ticks
    ("wide",(["n","a"],CIf (app "==" [v "n",CInt 0]) (v "a")
       (ticked (app "wide" [app "-" [v "n",CInt 1],foldl (\acc i->app "+" [acc,CInt i]) (v "a") [1..1100]]))))]

lower policy=case lowerProgram policy M.empty prog prog M.empty M.empty of
  (ir,[])->ir
  (_,failures)->error (show failures)
ticks f=length [() | b<-fnBlocks f,Instr _ OSafepoint<-bInstrs b]
-- fuel and stack probes are the resource events placement decides; every
-- other event, the value and the trap must match exactly
semantic o=o {ocEvents=[e | e<-ocEvents o,case e of EvStackCheck _->False;EvSafepoint _->False;_->True]}
loopTicks f=and [or [True | b<-fnBlocks f,S.member (bId b) (loopBlocks l),Instr _ OSafepoint<-bInstrs b] | l<-naturalLoops f (analyze f)]

main=forM_ [m2Policy,m2Policy {polProfile=Rv32},m2Policy {polEarlyLoops=True}] $ \policy->do
  let on=lower policy
      off=lower policy {polTickBatch=False}
      width=policyWidth policy
      formed=polEarlyLoops policy
  check "placed programs verify" (all ((==Right ()) . verifyProgramWidth width) [on,off])
  -- the entry's tick, plus the formed loop's back-edge tick when LoopForm ran
  check "a self loop keeps one tick per iteration" (ticks (on M.! "loop")==(if formed then 2 else 1))
  check "the rollback keeps both inlined ticks" (ticks (off M.! "loop")==ticks (on M.! "loop")+2)
  check "recursion that is not a loop drops its inlined tick" (ticks (on M.! "tree")==1 && ticks (off M.! "tree")==2)
  check "a non-recursive function keeps its inlined tick" (ticks (on M.! "helper")==2)
  check "a body above the bound keeps its ticks" (on M.! "wide"==off M.! "wide" && ticks (on M.! "wide")>=2)
  check "every loop still ticks" (all loopTicks (M.elems on))
  check "disabled fuel is untouched" (lower policy {polProfile=Builtin,polFuel=False,polStackCheck=StackStatic}
    ==lower policy {polProfile=Builtin,polFuel=False,polStackCheck=StackStatic,polTickBatch=False})
  forM_ [0,1,5] $ \n->do
    let args=[RInt n,RInt 3]
    check "loop values, calls and traps match" (semantic (evalProgramWidth width on "loop" args)==semantic (evalProgramWidth width off "loop" args))
    check "tree values, calls and traps match" (semantic (evalProgramWidth width on "tree" [RInt n])==semantic (evalProgramWidth width off "tree" [RInt n]))
    check "placement charges fewer ticks" (length [() | EvSafepoint _<-ocEvents (evalProgramWidth width on "loop" args)]
      <= length [() | EvSafepoint _<-ocEvents (evalProgramWidth width off "loop" args)])
  putStrLn "tick placement: PASS"
