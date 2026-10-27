module Main where
import Codegen.IR
import Codegen.ControlFlow
import Codegen.LoopOptimize
import Codegen.Simplify
import Codegen.Verify
import Codegen.Eval
import Codegen.Policy (RegisterBudget (..))
import Codegen.Pressure
import Control.Monad (forM_,unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

check label ok=unless ok (error ("loop optimization: "++label))
v=VId
b=BId
instr n t op=Instr (Just (v n,t)) op
identity=Fn "identity" ["x"] TInt (b 0) [Block (b 0) [(v 0,TInt)] [] (TRet (v 0))]
loop=Fn "loop" ["n","seed","divisor"] TInt (b 0)
  [Block (b 0) [(v 0,TInt),(v 1,TVal),(v 2,TInt)]
     [instr 3 TInt (OConstInt 0),instr 4 TInt (OConstInt 1)] (TBr (b 1) [v 3,v 3]),
   Block (b 1) [(v 5,TInt),(v 6,TInt)] [instr 7 TPred (OCmp Lt (v 5) (v 0))]
     (TCondBr (v 7) (b 2) [] (b 4) []),
   Block (b 2) [] [] (TBr (b 3) [v 1]),
   Block (b 3) [(v 8,TVal)]
     [Instr Nothing OSafepoint,
      instr 9 TInt (OUntag (v 8)),instr 10 TInt (OConstInt 3),
      instr 11 TInt (OBit BXor (v 9) (v 10)),
      instr 12 TInt (OCall (Callee "identity" Local [TInt] TInt) [v 11]),
      instr 13 TInt (OArith Div (v 12) (v 2)),
      instr 14 TInt (OArith Add (v 6) (v 13)),
      instr 15 TInt (OArith Add (v 5) (v 4))]
     (TBr (b 1) [v 15,v 14]),
   Block (b 4) [] [] (TRet (v 6))]
ops f bid=[op | block<-fnBlocks f,bId block==b bid,Instr _ op<-bInstrs block]
main=do
  let program=M.fromList [(fnName f,f) | f<-[identity,loop]]
      moved=moveInvariants Nothing True loop
      candidate=M.insert "loop" moved program
  check "input verifies" (verifyProgram program==Right ())
  check "output verifies at both word widths" (all (\w->verifyProgramWidth w candidate==Right ()) [W32,W64])
  check "capture copy is resolved into preheader" (OUntag (v 1) `elem` ops moved 0)
  check "dependent invariant moves too" (OBit BXor (v 9) (v 10) `elem` ops moved 0)
  check "calls and trapping division remain in the loop" (all (`elem` ops moved 3)
    [OCall (Callee "identity" Local [TInt] TInt) [v 11],OArith Div (v 12) (v 2),OSafepoint])
  check "motion is idempotent" (moveInvariants Nothing True moved==moved)
  forM_ [W32,W64] $ \width->forM_ [0,1,2,7] $ \n->forM_ [-7,0,11] $ \seed->forM_ [0,1,3] $ \divisor->do
    let args=[RInt n,RInt seed,RInt divisor]
    check "answers, exact traps and events preserved" (evalProgramWidth width program "loop" args==evalProgramWidth width candidate "loop" args)
  let risky=[instr 16 TAddr (OAddress (v 1)),instr 17 TInt (OLoad TInt (v 16) 0),
             instr 18 TInt (OLoadByte (v 16) 0),instr 19 TVal (OField 0 (v 1)),
             instr 20 TPred (OTagTest 7 0 (v 1)),instr 21 TInt (OHartCell 58),
             instr 22 TPred (ORegionRoom (v 1)),instr 23 TPred (OTruth (v 1)),
             instr 24 TInt (OShift Shl (v 9) (v 10))]
      guarded=loop {fnBlocks=[if bId block==b 3 then block {bInstrs=bInstrs block++risky} else block | block<-fnBlocks loop]}
      guardedMoved=moveInvariants Nothing True guarded
  check "risky input/output verify" (verifyFn program guarded==Right () && verifyFn program guardedMoved==Right ())
  check "loads, fields, tag/truth checks, hart clocks, shifts do not speculate" (all (`elem` ops guardedMoved 3) [op | Instr _ op<-drop 1 risky])
  let graph edges=Fn "graph" [] TVal (b 0) [Block (b i) [] [] term | (i,term)<-edges]
      nested=graph [(0,TBr (b 1) []),(1,TCondBr (v 0) (b 2) [] (b 5) []),
        (2,TBr (b 3) []),(3,TCondBr (v 0) (b 4) [] (b 1) []),(4,TBr (b 3) []),(5,TRet (v 0))]
      loops=naturalLoops nested (analyze nested)
  check "nested natural loops merge members and name existing preheaders" (
    [(loopHeader l,loopBlocks l,loopPreheader l) | l<-loops]==
      [(b 1,S.fromList (map b [1,2,3,4]),Just (b 0)),(b 3,S.fromList (map b [3,4]),Just (b 2))])
  let multi=graph [(0,TBr (b 1) []),(1,TCondBr (v 0) (b 2) [] (b 3) []),
                   (2,TBr (b 1) []),(3,TBr (b 1) [])]
  check "multiple latches merge" (case naturalLoops multi (analyze multi) of
    [l]->loopLatches l==S.fromList [b 2,b 3] && loopBlocks l==S.fromList [b 1,b 2,b 3];_->False)
  let irreducible=graph [(0,TCondBr (v 0) (b 1) [] (b 2) []),(1,TBr (b 2) []),(2,TBr (b 1) [])]
  check "irreducible cycle has no natural loop" (null (naturalLoops irreducible (analyze irreducible)))
  let noPre=graph [(0,TCondBr (v 0) (b 1) [] (b 2) []),(1,TBr (b 3) []),
                  (2,TBr (b 3) []),(3,TBr (b 3) [])]
  check "multiple entry edges do not invent a preheader" (case naturalLoops noPre (analyze noPre) of [l]->loopPreheader l==Nothing;_->False)
  check "no preheader means no motion" (moveInvariants Nothing True noPre==noPre)
  let Right (off,_)=simplifyFnWith (Options False Nothing True) program loop
      Right (on,_)=simplifyFnWith (Options True Nothing True) program loop
  check "independent option preserves an on/off distinction" (OUntag (v 1) `notElem` ops off 0 && OUntag (v 1) `elem` ops on 0)
  -- A constant read by an instruction left in the loop stays there: it
  -- costs a register for the whole loop to save a free instruction.
  let mixed=loop {fnBlocks=[if bId block==b 3 then block {bInstrs=bInstrs block++[instr 30 TInt (OBit BAnd (v 5) (v 10))]} else block | block<-fnBlocks loop]}
      mixedMoved=moveInvariants Nothing True mixed
  check "a constant still read in the loop is not hoisted" (OConstInt 3 `elem` ops mixedMoved 3 && OConstInt 3 `notElem` ops mixedMoved 0)
  check "its invariant user stays with it" (OBit BXor (v 9) (v 10) `elem` ops mixedMoved 3)
  check "the other invariant still moves" (OUntag (v 1) `elem` ops mixedMoved 0)
  forM_ [W32,W64] $ \width->forM_ [0,3] $ \n->forM_ [0,2] $ \divisor->do
    let args=[RInt n,RInt 5,RInt divisor]
        mixedProgram=M.insert "loop" mixed program
    check "mixed answers preserved" (evalProgramWidth width mixedProgram "loop" args==evalProgramWidth width (M.insert "loop" mixedMoved program) "loop" args)
  -- The pressure model: values live at once, and live across a call.
  -- In `loop`, motion trades one value live across the call for another;
  -- in `wide`, n|divisor is computed after the call and used at once, so
  -- hoisting it adds a value live across the whole loop.
  let members=S.fromList [b 1,b 2,b 3]
      big=RegisterBudget 9 22 8 14
      wide=loop {fnBlocks=[if bId block==b 3 then block {bInstrs=bInstrs block++[instr 31 TInt (OBit BOr (v 0) (v 2)),instr 32 TInt (OBit BXor (v 14) (v 31))],bTerm=TBr (b 1) [v 15,v 32]} else block | block<-fnBlocks loop]}
      wideProgram=M.insert "loop" wide program
      before=loopPressure big True wide members
      widened=moveInvariants (Just big) True wide
      after=loopPressure big True widened members
  check "wide input verifies" (verifyFn wideProgram wide==Right ())
  check "loop pressure counts the values live across the call" (prGprAcross before>=4 && prGpr before>=prGprAcross before)
  check "a large budget admits all of the motion" (widened==moveInvariants Nothing True wide && OBit BOr (v 0) (v 2) `elem` ops widened 0)
  let trade=prGprAcross (loopPressure big True loop members)-prGprAcross (loopPressure big True moved members)
  check "motion that only trades values does not raise pressure" (trade>=0)
  check "the hoisted value adds one across the call, less the trade" (prGprAcross after==prGprAcross before+1-trade)
  let tight=RegisterBudget (prGprAcross after-1) 22 0 0
      gated=moveInvariants (Just tight) True wide
  check "a budget the motion would overflow refuses that move" (OBit BOr (v 0) (v 2) `elem` ops gated 3 && OBit BOr (v 0) (v 2) `notElem` ops gated 0)
  check "moves that fit are still made" (OUntag (v 1) `elem` ops gated 0)
  check "the gated loop fits the budget" (fitsBudget tight (loopPressure tight True gated members))
  check "nothing fitting falls back to no worse than before" (let none=RegisterBudget 1 22 0 0; g=moveInvariants (Just none) True wide in prGprAcross (loopPressure none True g members)<=prGprAcross before)
  check "gated output verifies" (verifyFn wideProgram gated==Right ())
  forM_ [W32,W64] $ \width->forM_ [0,1,7] $ \n->forM_ [0,3] $ \divisor->do
    let args=[RInt n,RInt (-7),RInt divisor]
        answer=evalProgramWidth width wideProgram "loop" args
    check "gated answers preserved" (answer==evalProgramWidth width (M.insert "loop" gated program) "loop" args)
    check "widened answers preserved" (answer==evalProgramWidth width (M.insert "loop" widened program) "loop" args)
  check "clobbering operations are what the model guards" (clobbersRegisters True (OCall (Callee "identity" Local [TInt] TInt) [v 0]) && clobbersRegisters True (OArith Add (v 0) (v 1))
    && not (clobbersRegisters True OSafepoint) && not (clobbersRegisters True (OKernelArith Add (v 0) (v 1)))
    && not (clobbersRegisters True (OFloatBin FAdd (v 0) (v 1))) && clobbersRegisters False (OFloatBin FAdd (v 0) (v 1)))
  putStrLn "Loop optimization: shared CFG/natural loops, capture forwarding, bounded total invariant motion, rematerializable constants, the register-pressure gate, zero-trip traps and exact events on both widths PASS"
