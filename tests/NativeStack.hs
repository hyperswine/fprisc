import qualified Codegen.Stack as St
import Codegen.Frame (layout)
import Codegen.IR
import Codegen.Policy
import Codegen.Target.Common
import qualified Codegen.Target.A64 as A
import qualified Codegen.Target.X64 as X
import qualified Codegen.Target.RV as R
import Codegen.Verify (verifyProgramWidth)
import Codegen.Selected (CodeSymbol(..))
import Codegen.Export.Plan
import Codegen.Target.RV.Export (adapterStack)
import Control.Monad (forM_,unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isInfixOf)
import System.Environment (lookupEnv)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

check n ok = unless ok (error ("native-stack: "++n))
sym = CodeSymbol
frame n bytes edges = St.Frame (sym n) bytes [St.Edge (sym to) held | (to,held)<-edges] []
get fs n = St.analyse fs M.! sym n
unproved (St.Unproved _) = True
unproved _ = False

main :: IO ()
main = do
  let leaf=frame "leaf" 16 []
      child=frame "child" 32 [("leaf",32)]
      root=frame "root" 48 [("child",48),("leaf",48)]
  check "ordinary calls add frames, siblings use maximum" (get [leaf,child,root] "root"==St.Bounded 96)
  check "exact stack budget admits" (St.admit 96 [sym "root"] [leaf,child,root]==Right [(sym "root",96)])
  check "one-byte shortage refuses" (either (const True) (const False) (St.admit 95 [sym "root"] [leaf,child,root]))
  check "unknown entry refuses admission" (either (const True) (const False) (St.admit 100 [sym "absent"] [leaf]))
  check "empty entry set refuses admission" (either (const True) (const False) (St.admit 100 [] [leaf]))
  check "duplicate roots refuse admission" (either (const True) (const False) (St.admit 100 [sym "leaf",sym "leaf"] [leaf]))
  let adapt make args result = adapterStack (either error id (make SoftFloat (CExportSymbol "public") (FprEntrySymbol "leaf") (Signature args result)))
      plainAdapter=adapt planAdapter [KInt,KWord,KF32,KF64,KBool,KUnit,KAddr] KInt
  check "C wrapper frame participates in admission" (St.admit 32 [sym "public"] [leaf,plainAdapter]==Right [(sym "public",32)])
  check "C wrapper cannot spend callee-only budget" (either (const True) (const False) (St.admit 16 [sym "public"] [leaf,plainAdapter]))
  forM_ [adapt planUniformAdapter [KWord] KInt,adapt planUniformAdapter [] KWord] $ \f->
    check "uniform conversion is an unproved runtime boundary" (unproved (get [leaf,f] "public"))
  check "tail cycle shares maximum frame" (get [frame "a" 16 [("b",0)],frame "b" 48 [("a",0)]] "a"==St.Bounded 48)
  check "mixed tail/ordinary cycle is unproved" (unproved (get [frame "a" 16 [("b",16)],frame "b" 48 [("a",0)]] "a"))
  check "missing import propagates" (unproved (get [child,root] "root"))
  let badCycle=(frame "badCycle" 16 [("goodCycle",16)]) {St.frameUnknown=["runtime:unknown"]}
      goodCycle=frame "goodCycle" 16 [("badCycle",0)]
  check "locally refused member cannot break a cycle into a finite proof"
    (all unproved (M.elems (St.analyse [badCycle,goodCycle])))
  check "duplicate symbols refuse" (unproved (get [leaf,leaf] "leaf"))
  check "negative frame refuses" (unproved (get [frame "bad" (-1) []] "bad"))
  check "negative retained bytes refuse" (unproved (get [leaf,frame "bad" 1 [("leaf",-1)]] "bad"))
  check "layout includes x64 return PC" (St.frameLocal (St.selectedFrame St.StackReturnAddress (layout 16 16 []) (sym "x") [] [])==24)
  check "entry shim remains unknown" (unproved (get [St.selectedFrame St.LinkRegister (layout 16 16 []) (sym "x") ["reserve"] []] "x"))
  -- Independent bounded-walk oracle: enumerate all 19,683 three-node graphs
  -- (absent/tail/retaining edges). A repeated node at a greater depth is a
  -- growing stack cycle; equal-depth repetition can be cut without loss.
  forM_ (sequence (replicate 9 [0::Int,1,2])) $ \choices -> do
    let names=["a","b","c"]
        fs=[frame n (16+16*toInteger i)
              [(m,if tag==1 then 0 else 16+16*toInteger i)
              | (j,m)<-zip [0..] names,let tag=choices!!(3*i+j),tag/=0]
           | (i,n)<-zip [0..] names]
        tab=M.fromList [(St.frameSymbol f,f) | f<-fs]
        walk seen depth n = case M.lookup n seen of
          Just old | depth>old->Nothing
                   | otherwise->Just 0
          Nothing -> let f=tab M.! n in do
            children<-mapM (\e->walk (M.insert n depth seen) (depth+St.edgeRetained e) (St.edgeTarget e)) (St.frameEdges f)
            pure (maximum (depth+St.frameLocal f:children))
        actual=St.analyse fs
    forM_ names $ \n -> check ("graph oracle "++show choices++" "++n)
      (case (walk M.empty 0 (sym n),actual M.! sym n) of
        (Nothing,St.Unproved _)->True;(Just x,St.Bounded y)->x==y;_->False)
  nativeChecks
  putStrLn "native stack: graph oracle and four target layouts passed"

fixtures :: [Fn]
fixtures =
  spillFn : [fn "leaf" [] (TRet (VId 0)),
   fn "middle" [call "leaf"] (TRet (VId 1)),
   fn "root" [call "middle"] (TRet (VId 1)),
   fn "tail" [] (TTailCall (callee "middle") [VId 0]),
   fn "recursive" [call "recursive"] (TRet (VId 1)),
   fn "ta" [] (TTailCall (callee "tb") [VId 0]),
   fn "tb" [] (TTailCall (callee "ta") [VId 0]),
   fn "missing" [call "outside"] (TRet (VId 1)),
   fn "foreign" [Instr (Just (VId 1,TVal)) (OCall (Callee "foreign" (Foreign "foreign_entry") [TVal] TVal) [VId 0])] (TRet (VId 1)),
   fn "apply" [Instr (Just (VId 1,TVal)) (OApply (VId 0) [VId 0])] (TRet (VId 1)),
   fn "trap" [] (TUnreachable "stack probe trap")]
  where
    fn n ops term=Fn n ["x"] TVal (BId 0) [Block (BId 0) [(VId 0,TVal)] ops term]
    callee n=Callee n Imported [TVal] TVal
    call n=Instr (Just (VId 1,TVal)) (OCall (callee n) [VId 0])

spillFn :: Fn
spillFn = Fn "spills" ["x"] TVal (BId 0) [Block (BId 0) [(VId 0,TVal)] ops (TRet (VId 74))]
  where
    ops=[Instr (Just (VId n,TVal)) (OCall (Callee "leaf" Imported [TVal] TVal) [VId 0]) | n<-[1..24]]
      ++[Instr (Just (VId (n+24),TInt)) (OUntag (VId n)) | n<-[1..24]]
      ++[Instr (Just (VId 49,TInt)) (OConstInt 0)]
      ++[Instr (Just (VId (50+n),TInt)) (OBit BXor (VId (if n==0 then 49 else 49+n)) (VId (25+n))) | n<-[0..23]]
      ++[Instr (Just (VId 74,TVal)) (OTag (VId 73))]

nativeChecks = do
  out<-lookupEnv "FPR_STACK_TEST_OUT"
  let builtin=m2Policy {polProfile=Builtin,polFuel=False,polStackCheck=StackStatic}
      exported=S.fromList (map fnName fixtures)
      targets=
        [("a64",W64,A.emitFnA64 (A.A64Config MachO A.HartX28 m2Policy exported False False False False noTune),0),
         ("x64",W64,X.emitFnX64 (X.X64Config m2Policy exported False False False noTune X.HartTls),8),
         ("rv64",W64,R.emitFnRV (R.RVConfig W64 builtin R.HartTp exported False False),0),
         ("rv32",W32,R.emitFnRV (R.RVConfig W32 builtin {polProfile=Builtin32} R.HartTp exported False False),0)]
  weak<-either error pure (R.emitFnRV (R.RVConfig W64 builtin R.HartTp exported True False)
    (head [f | f<-fixtures,fnName f=="leaf"]))
  check "weak definition cannot establish a callback budget"
    (either (isInfixOf "interposable-entry:") (const False)
      (St.admit 4096 [sym (functionSymbol "leaf")] [nfStack weak]))
  forM_ targets $ \(target,width,emit,pad) -> do
    let hosted=target `elem` ["a64","x64"]
        inputs=if hosted then map (\f->f {fnBlocks=map (\b->b {bInstrs=[Instr Nothing OStackCheck,Instr Nothing OSafepoint]++bInstrs b}) (fnBlocks f)}) fixtures else fixtures
    either error pure (verifyProgramWidth width (M.fromList [(fnName f,f) | f<-inputs]))
    fns<-mapM (either error pure . emit) inputs
    let fs=map nfStack fns
        fullBounds=St.analyse fs
        -- A synthetic projection checks call/frame arithmetic separately from
        -- runtime costs. It is never emitted as a physical execution bound.
        bounds=St.analyse (if hosted then map (\f->f {St.frameUnknown=[]}) fs else fs)
        local n=St.frameLocal (head [f | f<-fs,St.frameSymbol f==sym (functionSymbol n)])
        at n=bounds M.! sym (functionSymbol n)
    check (target++" three-deep physical frames")
      (at "root"==St.Bounded (sum (map local ["root","middle","leaf"])+2*pad))
    check (target++" spill frame is accounted") (local "spills">local "leaf" && at "spills"==St.Bounded (local "spills"+pad+local "leaf"))
    check (target++" tail frame released")
      (at "tail"==St.Bounded (max (local "tail") (local "middle"+pad+local "leaf")))
    check (target++" tail recursion bounded") (at "ta"==St.Bounded (max (local "ta") (local "tb")))
    forM_ ["recursive","missing","foreign","apply","trap"] $ \n -> check (target++" refuses "++n) (unproved (fullBounds M.! sym (functionSymbol n)))
    check (target++" hosted runtime boundaries unproved") (not hosted || all unproved (M.elems fullBounds))
    check (target++" dynamic packet identified") (any (elem "dynamic-argument-packet" . St.frameUnknown) fs)
    case out of
      Nothing->pure ()
      Just dir->do
        createDirectoryIfMissing True dir
        -- Only returning, closed probes are linked by the independent runner.
        let good=[f | f<-fns,nfName f `elem` ["leaf","middle","root","tail","spills"]]
        writeFile (dir</>target++".s") (unlines ([".text"]++concatMap nfLines good))
        writeFile (dir</>target++".bounds") (unlines [St.reportLine (nfStack f) (fullBounds M.! St.frameSymbol (nfStack f)) | f<-good])
    check (target++" no implicit runtime in bounded probes")
      (hosted || all (not . isInfixOf "fpr_stack_grow" . unlines . nfLines) fns)
