module Main where
-- Codegen.RawInts: raw-word copies of Int loops (docs/2026-11-22-RAW-INTS.md).
-- The copies must give the reference evaluator's exact answers (bignums
-- included) for inputs that leave the small range in the middle of an
-- iteration, and the copies' fit tests must go where the bounds prove them.
import Core.Syntax
import Codegen.IR
import Codegen.Policy
import Codegen.Lower (lowerProgram)
import Codegen.Simplify (Options(..),simplifyProgramWith)
import Codegen.Verify (verifyProgramWidth)
import Codegen.Eval
import Codegen.Dump (dumpFn)
import System.Environment (lookupEnv)
import Control.Monad (unless,forM_)
import qualified Data.Map.Strict as M

check :: String -> Bool -> IO ()
check label ok=unless ok (error ("raw ints: "++label))
app :: String -> [Core] -> Core
app n=foldl CApp (CVar n)

-- count i n acc = if i >= n then acc else count (i + 1) n (acc + i)
-- down n x = if n == 0 then x else down (n - 1) (x * 3)
-- steps i n k s = if i >= n then s else steps (i + 1) n k (s + k * i - 1)
-- equal i n c = if i == n then c else equal (i + 1) n (if i == 7 then c + 100 else c + 1)
-- the monomorphised std List.fold worker's shapes: the element is a list
-- cell's field (tested on the way, never "cheap"), the accumulator is the
-- loop-carried parameter, k is a captured invariant
-- foldk xs k a = case xs of Nil -> a | x :: r -> foldk r k (a + x * k)
-- foldsum xs a = case xs of Nil -> a | x :: r -> foldsum r (a + x)
-- foldprod xs a = case xs of Nil -> a | x :: r -> foldprod r (a * x)
-- foldabs xs a = case xs of Nil -> a | x :: r -> foldabs r (if x < 0 then a - x else a + x)
--   (the accumulator reaches the header through a join block's parameter)
prog :: M.Map String ([String], Core)
prog=M.fromList
  [("foldk",(["xs","k","a"],CIf (CTagEq listTid 0 (CVar "xs")) (CVar "a")
      (app "foldk" [CProj 1 (CVar "xs"),CVar "k",app "+" [CVar "a",app "*" [CProj 0 (CVar "xs"),CVar "k"]]]))),
   ("foldsum",(["xs","a"],CIf (CTagEq listTid 0 (CVar "xs")) (CVar "a")
      (app "foldsum" [CProj 1 (CVar "xs"),app "+" [CVar "a",CProj 0 (CVar "xs")]]))),
   ("foldprod",(["xs","a"],CIf (CTagEq listTid 0 (CVar "xs")) (CVar "a")
      (app "foldprod" [CProj 1 (CVar "xs"),app "*" [CVar "a",CProj 0 (CVar "xs")]]))),
   ("foldabs",(["xs","a"],CIf (CTagEq listTid 0 (CVar "xs")) (CVar "a")
      (CLet "x" (CProj 0 (CVar "xs"))
        (app "foldabs" [CProj 1 (CVar "xs"),CIf (app "<" [CVar "x",CInt 0]) (app "-" [CVar "a",CVar "x"]) (app "+" [CVar "a",CVar "x"])])))),
   ("count",(["i","n","acc"],CIf (app ">=" [CVar "i",CVar "n"]) (CVar "acc")
      (app "count" [app "+" [CVar "i",CInt 1],CVar "n",app "+" [CVar "acc",CVar "i"]]))),
   ("down",(["n","x"],CIf (app "==" [CVar "n",CInt 0]) (CVar "x")
      (app "down" [app "-" [CVar "n",CInt 1],app "*" [CVar "x",CInt 3]]))),
   ("steps",(["i","n","k","s"],CIf (app ">=" [CVar "i",CVar "n"]) (CVar "s")
      (app "steps" [app "+" [CVar "i",CInt 1],CVar "n",CVar "k",app "-" [app "+" [CVar "s",app "*" [CVar "k",CVar "i"]],CInt 1]]))),
   ("equal",(["i","n","c"],CIf (app "==" [CVar "i",CVar "n"]) (CVar "c")
      (app "equal" [app "+" [CVar "i",CInt 1],CVar "n",
                    CIf (app "==" [CVar "i",CInt 7]) (app "+" [CVar "c",CInt 100]) (app "+" [CVar "c",CInt 1])])))]

listTid :: Int
listTid=7

list :: [Integer] -> RV
list=foldr (\x r->RObj listTid 1 [RInt x,r]) (RObj listTid 0 [])

lowered :: Program
lowered=let (ir,failures)=lowerProgram m2Policy M.empty prog prog M.empty M.empty
  in if null failures then ir else error (show failures)

on, off :: Options
on=Options False Nothing True (Just W64) False
off=Options False Nothing True Nothing False

simplified :: Options -> Program
simplified o=fst (either error id (simplifyProgramWith o lowered))

operations :: Fn -> [Op]
operations fn=[op | b<-fnBlocks fn,Instr _ op<-bInstrs b]

fits :: Fn -> [ArithOp]
fits fn=[o | OArithFits o _ _<-operations fn]

unchecked :: Fn -> [ArithOp]
unchecked fn=[o | OArithU o _ _<-operations fn]

maxI, minI :: Integer
maxI=4611686018427387903
minI=negate maxI-1

main :: IO ()
main=do
  let fast=simplified on
      slow=simplified off
  dump<-lookupEnv "RAWINTS_DUMP"
  forM_ dump $ \n->putStrLn (dumpFn (fast M.! n))
  check "both pipelines verify" (verifyProgramWidth W64 fast==Right () && verifyProgramWidth W64 slow==Right ())
  check "no copy without the interval pass" (all (null . fits) (M.elems slow) && all (null . unchecked) (M.elems slow))
  -- count: i + 1 is proven (i < n, n small); acc + i keeps its fit test
  check "count's i + 1 needs no fit test, acc + i keeps one" (fits (fast M.! "count")==[Add] && length (unchecked (fast M.! "count"))==2)
  check "count's raw copy compares raw words" (not (null [() | OCmp Ge _ _<-operations (fast M.! "count")]))
  check "down's n - 1 and x * 3 are tested" (length (fits (fast M.! "down"))==2)
  -- List.fold's worker: before the accumulator rule no exact operation
  -- had two cheap operands (the element is a load), so none was copied
  forM_ ["foldk","foldsum","foldprod","foldabs"] $ \n->
    check (n++" (a List.fold shape) gets a raw copy with tested arithmetic")
      (not (null (fits (fast M.! n))) && not (null (unchecked (fast M.! n))))
  check "foldk's raw copy tests the element's tag on the way" (not (null [() | OIsInt _<-operations (fast M.! "foldk")]))
  -- the evaluator: the same answers, bignums included, before and after
  let cases=
        [ ("count",[RInt 0,RInt 100000,RInt 0]),("count",[RInt 5,RInt 5,RInt 7])
        , ("count",[RInt (maxI-3),RInt maxI,RInt 0]),("count",[RInt 0,RInt 10,RInt (maxI-20)])
        , ("count",[RInt (maxI+5),RInt (maxI+9),RInt 0]),("count",[RInt (maxI-2),RInt (maxI+3),RInt 0])
        , ("down",[RInt 50,RInt 1]),("down",[RInt 3,RInt (maxI `div` 2)]),("down",[RInt 0,RInt (maxI+1)])
        , ("steps",[RInt 0,RInt 40,RInt (maxI `div` 1000),RInt 0]),("steps",[RInt 0,RInt 5,RInt 3,RInt (minI+2)])
        , ("steps",[RInt (minI+1),RInt (minI+4),RInt 2,RInt 0])
        , ("equal",[RInt 0,RInt 12,RInt 0]),("equal",[RInt (maxI-2),RInt (maxI+3),RInt 0])
        , ("foldk",[list [1..1000],RInt 7,RInt 0]),("foldk",[list [],RInt 7,RInt 5])
        , ("foldk",[list [maxI,maxI,-maxI,-maxI,3],RInt 1,RInt 0]),("foldk",[list [1,2,3],RInt maxI,RInt 0])
        , ("foldk",[list [1,maxI+1,2],RInt 1,RInt 0]),("foldk",[list [1,2,3],RInt (maxI+1),RInt 0])
        , ("foldk",[list [5,6],RInt 2,RInt (minI-1)])
        , ("foldsum",[list [maxI,maxI,5],RInt 0]),("foldsum",[list [maxI,1,-maxI-1],RInt 0])
        , ("foldsum",[list [minI,-1,1],RInt 0]),("foldprod",[list [1..30],RInt 1]),("foldprod",[list [2,maxI,0,9],RInt 1])
        , ("foldabs",[list [-3,4,-5],RInt 0]),("foldabs",[list [maxI,minI,7],RInt 0]),("foldabs",[list [minI,1],RInt (-1)]) ]
  forM_ cases $ \(fn,args)->
    check (fn++" "++show args++" evaluates identically")
      (ocResult (evalProgram lowered fn args)==ocResult (evalProgram fast fn args))
  check "count past the small range is exact"
    (ocResult (evalProgram fast "count" [RInt 0,RInt 10,RInt (maxI-20)])==Right (RInt (maxI-20+45)))
  check "down grows into a bignum" (ocResult (evalProgram fast "down" [RInt 50,RInt 1])==Right (RInt (3^(50::Int))))
  -- a List.fold sum that leaves the 63-bit small range promotes to a bignum
  -- (no wrap, no trap) and comes back down exactly
  check "fold sum past the small range is a bignum"
    (ocResult (evalProgram fast "foldsum" [list [maxI,maxI,5],RInt 0])==Right (RInt (2*maxI+5)))
  check "fold sum leaves the small range and comes back"
    (ocResult (evalProgram fast "foldsum" [list [maxI,1,-maxI-1],RInt 0])==Right (RInt 0))
  check "fold k-sum over 1..1000 is exact" (ocResult (evalProgram fast "foldk" [list [1..1000],RInt 7,RInt 0])==Right (RInt (7*500500)))
  check "fold with a bignum element is exact" (ocResult (evalProgram fast "foldk" [list [1,maxI+1,2],RInt 1,RInt 0])==Right (RInt (maxI+4)))
  check "fold of absolute values through a join is exact" (ocResult (evalProgram fast "foldabs" [list [maxI,minI,7],RInt 0])==Right (RInt (2*maxI+8)))
  check "fold product grows into a bignum" (ocResult (evalProgram fast "foldprod" [list [1..30],RInt 1])==Right (RInt (product [1..30])))
  putStrLn "Raw-Int loop copies: fit tests proven or kept, raw comparisons, exact answers across the small range PASS"
