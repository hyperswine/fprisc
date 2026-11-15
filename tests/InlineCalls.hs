-- Calls inside loops merged on the IR (Codegen.InlineCalls), the pass that
-- makes their handles one value (forward-single-valued-parameters), and the
-- dominators both lean on (Codegen.ControlFlow).
module Main where
import Codegen.IR
import Codegen.ControlFlow
import Codegen.InlineCalls
import Codegen.Simplify
import Codegen.Verify
import Codegen.Eval
import Control.Monad (forM_,unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

check :: String -> Bool -> IO ()
check label ok=unless ok (error ("inline calls: "++label))
v :: Int -> VId
v=VId
b :: Int -> BId
b=BId
instr :: Int -> Ty -> Op -> Instr
instr n t op=Instr (Just (v n,t)) op
callee :: String -> Int -> Callee
callee name n=Callee name Local (replicate n TVal) TVal
program :: [Fn] -> Program
program fs=M.fromList [(fnName f,f) | f<-fs]

-- step x: x / 2 + 3 for an even x (a tail call does the halving); an odd x
-- answers 100 / (x - 7), which traps at 7. Two exits, one of them a tail call.
half :: Fn
half=Fn "half" ["x"] TVal (b 0)
  [Block (b 0) [(v 0,TVal)]
    [Instr Nothing OStackCheck,Instr Nothing OSafepoint,
     instr 1 TInt (OUntag (v 0)),instr 2 TInt (OConstInt 2),instr 3 TInt (OArith Div (v 1) (v 2)),
     instr 4 TInt (OConstInt 3),instr 5 TInt (OArith Add (v 3) (v 4)),instr 6 TVal (OTag (v 5))]
    (TRet (v 6))]
step :: Fn
step=Fn "step" ["x"] TVal (b 0)
  [Block (b 0) [(v 0,TVal)]
    [Instr Nothing OStackCheck,Instr Nothing OSafepoint,
     instr 1 TInt (OUntag (v 0)),instr 2 TInt (OConstInt 1),instr 3 TInt (OBit BAnd (v 1) (v 2)),
     instr 4 TInt (OConstInt 0),instr 5 TPred (OCmp Eq (v 3) (v 4))]
    (TCondBr (v 5) (b 1) [] (b 2) []),
   Block (b 1) [] [] (TTailCall (callee "half" 1) [v 0]),
   Block (b 2) []
    [instr 6 TInt (OConstInt 7),instr 7 TInt (OArith Sub (v 1) (v 6)),
     instr 8 TInt (OConstInt 100),instr 9 TInt (OArith Div (v 8) (v 7)),instr 10 TVal (OTag (v 9))]
    (TRet (v 10))]
-- run n x: step applied n times; the call is the program's only use of step
run :: Fn
run=Fn "run" ["n","x"] TVal (b 0)
  [Block (b 0) [(v 0,TVal),(v 1,TVal)]
    [Instr Nothing OStackCheck,Instr Nothing OSafepoint,instr 2 TInt (OUntag (v 0))] (TBr (b 1) [v 2,v 1]),
   Block (b 1) [(v 3,TInt),(v 4,TVal)] [instr 5 TInt (OConstInt 0),instr 6 TPred (OCmp Le (v 3) (v 5))]
    (TCondBr (v 6) (b 2) [] (b 3) []),
   Block (b 2) [] [] (TRet (v 4)),
   Block (b 3) []
    [instr 7 TInt (OConstInt 1),instr 8 TInt (OArithU Sub (v 3) (v 7)),
     instr 9 TVal (OCall (callee "step" 1) [v 4]),Instr Nothing OSafepoint]
    (TBr (b 1) [v 8,v 9])]
-- the same loop, with a second call of step outside it: step is shared
twice :: Fn
twice=run {fnName="twice",fnBlocks=[if bId x==b 2
  then x {bInstrs=[instr 20 TVal (OCall (callee "step" 1) [v 4])],bTerm=TRet (v 20)} else x | x<-fnBlocks run]}
-- a loop that calls itself from inside: never merged into itself
self :: Fn
self=run {fnName="self",fnBlocks=[if bId x==b 3
  then x {bInstrs=[instr 7 TInt (OConstInt 1),instr 8 TInt (OArithU Sub (v 3) (v 7)),instr 30 TInt (OConstInt 0),
                   instr 31 TVal (OTag (v 30)),instr 9 TVal (OCall (callee "self" 2) [v 31,v 4]),Instr Nothing OSafepoint]}
  else x | x<-fnBlocks run]}

-- pair x: the product (x, x + 1), called for its two words inside a loop
pair :: Fn
pair=Fn "pair" ["x"] (TProduct 2) (b 0)
  [Block (b 0) [(v 0,TVal)]
    [Instr Nothing OStackCheck,Instr Nothing OSafepoint,
     instr 1 TInt (OUntag (v 0)),instr 2 TInt (OConstInt 1),instr 3 TInt (OArith Add (v 1) (v 2)),instr 4 TVal (OTag (v 3))]
    (TRetProduct [v 0,v 4])]
sums :: Fn
sums=Fn "sums" ["n","x"] TVal (b 0)
  [Block (b 0) [(v 0,TVal),(v 1,TVal)]
    [Instr Nothing OStackCheck,Instr Nothing OSafepoint,instr 2 TInt (OUntag (v 0)),instr 20 TInt (OConstInt 0)]
    (TBr (b 1) [v 2,v 1,v 20]),
   Block (b 1) [(v 3,TInt),(v 4,TVal),(v 21,TInt)] [instr 5 TInt (OConstInt 0),instr 6 TPred (OCmp Le (v 3) (v 5))]
    (TCondBr (v 6) (b 2) [] (b 3) []),
   Block (b 2) [] [instr 22 TVal (OTag (v 21))] (TRet (v 22)),
   Block (b 3) []
    [instr 7 TInt (OConstInt 1),instr 8 TInt (OArithU Sub (v 3) (v 7)),
     instr 9 TVal (OCallProduct (Callee "pair" Local [TVal] (TProduct 2)) [v 4]),instr 10 TVal (OResult 1),
     instr 11 TInt (OUntag (v 9)),instr 12 TInt (OArith Add (v 21) (v 11)),Instr Nothing OSafepoint]
    (TBr (b 1) [v 8,v 10,v 12])]

calls :: Fn -> [Name]
calls f=[calleeName c | x<-fnBlocks f,Instr _ op<-bInstrs x,c<-case op of OCall c _->[c];OCallProduct c _->[c];_->[]]
  ++[calleeName c | x<-fnBlocks f,TTailCall c _<-[bTerm x]]
-- what a caller can observe: the answer or the trap, and how often fuel was charged
seen :: Outcome -> (Either Failure RV,Int)
seen out=(ocResult out,length [() | EvSafepoint _<-ocEvents out])

-- dominators by definition: d dominates x when removing d cuts x off from the entry
reference :: Fn -> M.Map BId (S.Set BId)
reference fn=M.fromList [(bId x,if S.member (bId x) live then S.fromList [d | d<-S.toList live,d==bId x || S.notMember (bId x) (reach (Just d))]
                                else S.singleton (bId x)) | x<-fnBlocks fn]
  where
    succs=M.fromList [(bId x,map fst (termSuccs (bTerm x))) | x<-fnBlocks fn]
    live=reach Nothing
    reach without=go S.empty [fnEntry fn | Just (fnEntry fn)/=without]
      where go done []=done
            go done (x:xs) | S.member x done || Just x==without=go done xs
                           | otherwise=go (S.insert x done) (M.findWithDefault [] x succs++xs)
graph :: [(Int,[Int])] -> Fn
graph edges=Fn "graph" [] TVal (b 0) (Block (b 0) [(v 0,TVal)] [instr 1 TPred (OIsInt (v 0))] (term (snd (head edges)))
  :[Block (b n) [] [] (term ts) | (n,ts)<-tail edges])
  where term ts=case ts of []->TRet (v 0);[t]->TBr (b t) [];t:e:_->TCondBr (v 1) (b t) [] (b e) []

main :: IO ()
main=do
  let single=program [half,step,run]
      merged=inlineCalls single
      inRun=merged M.! "run"
  check "inputs verify" (all ((==Right ()) . verifyProgram . program) [[half,step,run],[half,step,run,twice],[self],[pair,sums]])
  check "the merged program verifies" (verifyProgram merged==Right ())
  check "a callee named once is merged, and so is its own tail callee" (calls inRun==[])
  check "the callee keeps its definition" (merged M.! "step"==step && merged M.! "half"==half)
  check "the callee's stack check goes, the caller's stays" (length [() | x<-fnBlocks inRun,Instr _ OStackCheck<-bInstrs x]==1)
  forM_ [W32,W64] $ \width->forM_ [0,1,2,5] $ \n->forM_ [-9,0,4,7,10,13,22] $ \x->do
    let args=[RInt n,RInt x]
    check ("run "++show (n,x)++": answer, trap and fuel charges preserved")
      (seen (evalProgramWidth width single "run" args)==seen (evalProgramWidth width merged "run" args))
  -- the comparison above is of real runs: one that answers, one that traps (100 / (7 - 7))
  check "run 2 10 answers (10 / 2 + 3) / 2 + 3 = 7" (fst (seen (evalProgramWidth W64 merged "run" [RInt 2,RInt 10]))==Right (RInt 7))
  check "run 1 9 answers 100 / (9 - 7) = 50" (fst (seen (evalProgramWidth W64 merged "run" [RInt 1,RInt 9]))==Right (RInt 50))
  check "run 1 7 traps in the merged callee" (case fst (seen (evalProgramWidth W64 merged "run" [RInt 1,RInt 7])) of Left (Trap _)->True;_->False)
  check "a callee named twice is not merged" (inlineCalls (program [half,step,run,twice])==program [half,step,run,twice])
  check "a function is not merged into its own recursion" (inlineCalls (program [self])==program [self])
  let products=program [pair,sums]
      mergedProducts=inlineCalls products
  check "a product call is merged" (calls (mergedProducts M.! "sums")==[] && verifyProgram mergedProducts==Right ())
  check "sums 3 5 answers 5 + 6 + 7" (fst (seen (evalProgramWidth W64 mergedProducts "sums" [RInt 3,RInt 5]))==Right (RInt 18))
  forM_ [0,1,3,6] $ \n->forM_ [-2,0,5] $ \x->
    check "product results preserved" (seen (evalProgramWidth W64 products "sums" [RInt n,RInt x])
      ==seen (evalProgramWidth W64 mergedProducts "sums" [RInt n,RInt x]))

  -- a parameter every edge passes one value, or itself round a loop, is that value
  let Just forward=lookup "forward-single-valued-parameters" passes
      carried=Fn "carried" ["h","n"] TVal (b 0)
        [Block (b 0) [(v 0,TVal),(v 1,TVal)] [instr 2 TInt (OUntag (v 1))] (TBr (b 1) [v 0,v 2]),
         Block (b 1) [(v 3,TVal),(v 4,TInt)] [instr 5 TInt (OConstInt 0),instr 6 TPred (OCmp Le (v 4) (v 5))]
           (TCondBr (v 6) (b 2) [v 3] (b 3) [v 3]),
         Block (b 2) [(v 7,TVal)] [] (TRet (v 7)),
         Block (b 3) [(v 8,TVal)] [instr 9 TInt (OConstInt 1),instr 10 TInt (OArithU Sub (v 4) (v 9))] (TBr (b 1) [v 8,v 10])]
      forwarded=forward carried
  check "forwarding verifies" (verifyProgram (program [forwarded])==Right ())
  check "the handle carried round the loop is the entry's value" (TRet (v 0) `elem` map bTerm (fnBlocks forwarded))
  check "only the counter is still a parameter" ([length (bParams x) | x<-fnBlocks forwarded]==[2,1,0,0])
  check "forwarding is idempotent" (forward forwarded==forwarded)
  forM_ [0,3] $ \n->check "forwarding preserves the answer"
    (evalProgramWidth W64 (program [carried]) "carried" [RInt 41,RInt n]==evalProgramWidth W64 (program [forwarded]) "carried" [RInt 41,RInt n])
  -- two unreached blocks whose parameters only name each other: nothing to forward, and the pass ends
  let orphans=Fn "orphans" ["x"] TVal (b 0)
        [Block (b 0) [(v 0,TVal)] [] (TRet (v 0)),
         Block (b 1) [(v 1,TVal)] [] (TBr (b 2) [v 1]),
         Block (b 2) [(v 2,TVal)] [] (TBr (b 1) [v 2])]
  check "a cycle of parameters nothing reaches ends the pass" (forward orphans==orphans)

  -- dominators: straight line, diamond, nested loops, an irreducible pair, unreached blocks
  forM_ [ [(0,[1]),(1,[2]),(2,[])],
          [(0,[1,2]),(1,[3]),(2,[3]),(3,[])],
          [(0,[1]),(1,[2,5]),(2,[3]),(3,[2,4]),(4,[1]),(5,[])],
          [(0,[1,2]),(1,[2]),(2,[1,3]),(3,[])],
          [(0,[1]),(1,[]),(2,[3]),(3,[2])],
          [(0,[1,4]),(1,[2]),(2,[3,1]),(3,[5]),(4,[5,4]),(5,[6,0]),(6,[])] ] $ \edges->
    check ("dominators of "++show edges) (dominators (analyze (graph edges))==reference (graph edges))
  putStrLn "Inline calls: single-site merge, tail and product exits, shared and recursive callees kept, single-valued parameters, dominators PASS"
