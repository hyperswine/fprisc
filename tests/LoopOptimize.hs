module Main where
import Codegen.IR
import Codegen.ControlFlow
import Codegen.LoopOptimize
import Codegen.Simplify
import Codegen.Verify
import Codegen.Eval
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
      moved=moveInvariants loop
      candidate=M.insert "loop" moved program
  check "input verifies" (verifyProgram program==Right ())
  check "output verifies at both word widths" (all (\w->verifyProgramWidth w candidate==Right ()) [W32,W64])
  check "capture copy is resolved into preheader" (OUntag (v 1) `elem` ops moved 0)
  check "dependent invariant moves too" (OBit BXor (v 9) (v 10) `elem` ops moved 0)
  check "calls and trapping division remain in the loop" (all (`elem` ops moved 3)
    [OCall (Callee "identity" Local [TInt] TInt) [v 11],OArith Div (v 12) (v 2),OSafepoint])
  check "motion is idempotent" (moveInvariants moved==moved)
  forM_ [W32,W64] $ \width->forM_ [0,1,2,7] $ \n->forM_ [-7,0,11] $ \seed->forM_ [0,1,3] $ \divisor->do
    let args=[RInt n,RInt seed,RInt divisor]
    check "answers, exact traps and events preserved" (evalProgramWidth width program "loop" args==evalProgramWidth width candidate "loop" args)
  let risky=[instr 16 TAddr (OAddress (v 1)),instr 17 TInt (OLoad TInt (v 16) 0),
             instr 18 TInt (OLoadByte (v 16) 0),instr 19 TVal (OField 0 (v 1)),
             instr 20 TPred (OTagTest 7 0 (v 1)),instr 21 TInt (OHartCell 58),
             instr 22 TPred (ORegionRoom (v 1)),instr 23 TPred (OTruth (v 1)),
             instr 24 TInt (OShift Shl (v 9) (v 10))]
      guarded=loop {fnBlocks=[if bId block==b 3 then block {bInstrs=bInstrs block++risky} else block | block<-fnBlocks loop]}
      guardedMoved=moveInvariants guarded
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
  check "no preheader means no motion" (moveInvariants noPre==noPre)
  let Right (off,_)=simplifyFnWith (Options False) program loop
      Right (on,_)=simplifyFnWith (Options True) program loop
  check "independent option preserves an on/off distinction" (OUntag (v 1) `notElem` ops off 0 && OUntag (v 1) `elem` ops on 0)
  putStrLn "Loop optimization: shared CFG/natural loops, capture forwarding, bounded total invariant motion, zero-trip traps and exact events on both widths PASS"
