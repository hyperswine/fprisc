module Main where
import qualified Codegen.Heap as H
import Codegen.Symbol (CodeSymbol(..))
import Codegen.Target.Common (functionSymbol)
import Codegen.Target.RV.ScalarAdapters (scalarAdapter)
import qualified Codegen.IR as I
import qualified Data.Map.Strict as M
import Control.Monad (forM_,unless)

need :: Bool -> String -> IO ()
need ok why=unless ok (error why)
k :: Int -> H.Key
k i=H.Entry (CodeSymbol ("f"++show i))
e :: Int -> H.Demand -> [H.Key] -> [H.Key] -> [String] -> H.Equation
e i=H.Equation (k i)
unit :: H.Demand
unit=H.Demand 1 24
check :: [H.Equation] -> H.Bound -> IO ()
check es want=need (M.lookup (k 0) (H.analyse es)==Just want) (show (es,H.analyse es,want))

main :: IO ()
main=do
  check [e 0 unit [k 1,k 1] [] [],e 1 unit [] [] []] (H.Bounded (H.Demand 3 72))
  check [e 0 H.zero [] [k 1,k 2] [],e 1 (H.Demand 2 16) [] [] [],e 2 (H.Demand 1 64) [] [] []] (H.Bounded (H.Demand 2 64))
  check [e 0 H.zero [] [k 0] []] (H.Bounded H.zero)
  let refused es=case M.lookup (k 0) (H.analyse es) of Just (H.Unproved _)->True;_->False
  forM_ [[e 0 unit [] [k 0] []], [e 0 H.zero [k 1] [] []],
         [e 0 (H.Demand (-1) 0) [] [] []], [e 0 H.zero [] [] ["runtime"]],
         [e 0 H.zero [] [] [],e 0 H.zero [] [] []],
         [e 0 H.zero [k 1] [] [],e 1 H.zero [k 0] [] ["runtime"]]] $ \es->need (refused es) "unsafe graph admitted"
  -- Exhaust all acyclic three-node graphs with repeated sequential calls.
  -- The independent oracle literally expands every call and chooses a flow
  -- path; its pair of scalar maxima is an upper bound, not a correlated pair.
  forM_ [0..7::Int] $ \mask->forM_ [0..26::Int] $ \edges->forM_ [0..7::Int] $ \branches->do
    let bit m i=(m `div` (2^i)) `mod` 2==1
        d i=if bit mask i then H.Demand 1 (8+8*toInteger i) else H.zero
        mult i=(edges `div` (3^i)) `mod` 3
        cs i=case i of 0->replicate (mult 0) 1++replicate (mult 1) 2;1->replicate (mult 2) 2;_->[]
        fs i=case i of 0->[j | (j,b)<-[(1,0),(2,1)],bit branches b];1->[2 | bit branches 2];_->[]
        paths i=[foldl H.plus (d i) costs `H.plus` rest | costs<-sequence [paths j | j<-cs i],rest<-case fs i of []->[H.zero];js->concatMap paths js]
        answers=paths 0
        expected=H.Demand (maximum (map H.requests answers)) (maximum (map H.requestedBytes answers))
    check [e i (d i) (map k (cs i)) (map k (fs i)) [] | i<-[0..2]] (H.Bounded expected)
  -- A verified IR allocation is charged after lowering; annotations never
  -- override it. A weak entry, unknown runtime or missing callee refuses.
  let v=I.VId 0
      fn=I.Fn "make" [] I.TVal (I.BId 0) [I.Block (I.BId 0) [] [I.Instr (Just (v,I.TVal)) (I.OMake 7000 0 [])] (I.TRet v)]
      root=H.Entry (CodeSymbol "fpr_fn_make")
  need (M.lookup root (H.analyse (H.fromFn False fn))==Just (H.Bounded (H.Demand 1 8))) "typed constructor request"
  need (case M.lookup root (H.analyse (H.fromFn True fn)) of Just (H.Unproved _)->True;_->False) "weak entry admitted"
  need (H.runtimeDemand (CodeSymbol "fpr_fn__x24arc_x2euniformBoxWord")==Just unit) "uniform box missing"
  need (H.runtimeDemand (CodeSymbol "fpr_alloc")==Nothing) "unbounded allocator guessed"
  let scalarNames=[(n,2) | n<-["wordadd","wordsub","wordand","wordor","wordxor","wordeq","rawEq","rawNe","lt","gt","le","ge","addradd","addreq"]]
        ++[(n,1) | n<-["wordnot","wordfromInt","wordtoInt","wordbits","addrfromWord","addrtoWord","addrnull"]]
      adapter n ar=I.Callee ("$arc."++n) (I.Foreign (functionSymbol ("$arc."++n))) (replicate ar I.TVal) I.TVal
      callFn c ar tailCall=let args=map I.VId [0..ar-1];r=I.VId ar in
        I.Fn "scalar" (map (('p':) . show) [0..ar-1]) I.TVal (I.BId 0)
          [I.Block (I.BId 0) (zip args (repeat I.TVal)) (if tailCall then [] else [I.Instr (Just (r,I.TVal)) (I.OCall c args)])
            (if tailCall then I.TTailCall c args else I.TRet r)]
      scalarBound c ar tailCall=M.lookup (H.Entry (CodeSymbol "fpr_fn_scalar")) (H.analyse (H.fromFn False (callFn c ar tailCall)))
  forM_ scalarNames $ \(n,ar)->forM_ [False,True] $ \tailCall->do
    need (scalarBound (adapter n ar) ar tailCall==Just (H.Bounded H.zero)) ("selected scalar still treated as a runtime call: "++n)
  let valid=adapter "wordadd" 2
  forM_ [valid {I.calleeKind=I.Local},valid {I.calleeKind=I.Foreign "another_symbol"},
         valid {I.calleeName="another_name"},valid {I.calleeParams=[I.TVal]},valid {I.calleeResult=I.TInt}] $ \c->
    need (scalarAdapter c 2==Nothing) "spelling, target or incomplete signature supplied scalar evidence"
  forM_ [("add",2),("div",2),("wordshl",2),("wordshr",2),("wordmask",2),("memread8",1),("memwriteWord",2),("cpuirqEnable",1)] $ \(n,ar)->
    need (case scalarBound (adapter n ar) ar False of Just (H.Unproved _)->True;_->False) ("guarded/unsafe adapter admitted: "++n)
  forM_ [H.zero,H.Demand 1 0,H.Demand 1 24,H.Demand 7 130,H.Demand 500 12000] $ \d->do
    bytes<-either error pure (H.arenaBytes d)
    let sym=CodeSymbol "f0";es=[e 0 d [] [] []]
    need (case H.admit (max 1 bytes) [sym] es of Right _->True;_->False) "exact arena refused"
    if bytes>0 then need (case H.admit (bytes-1) [sym] es of Left _->True;_->False) "short arena admitted" else pure ()
    let bitmap=((bytes+127) `div` 128+15) `div` 16*16
    need (d==H.zero || bytes-bitmap>=H.requestedBytes d+176*H.requests d) "bitmap omitted"
  need (case H.arenaBytes (H.Demand (2^(64::Int)) 0) of Left _->True;_->False) "overflowing arena"
  putStrLn "Heap bounds: 1728 independent path-expansion cases, graph refusals, typed constructors, runtime boundaries and physical capacity passed"
