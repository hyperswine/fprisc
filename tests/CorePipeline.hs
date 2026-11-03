import ExportPlans (checkExports)
import Core.Syntax
import Core.Opt.Pipeline
import Core.Opt.Vector (vecSpec, pipelinePlan)
import Core.Opt.Vector.Plan
import Core.Primitives
import KernelKinds (Kind(..))
import Control.Monad (unless)
import Data.List (isInfixOf,isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.ByteString.Lazy as B
import Data.Binary (encode, decode)
import Numeric (showHex)

check :: String -> Bool -> IO ()
check label ok = unless ok (error label)
app n = foldl CApp (CVar n)
right = either error id
failed (Left _) = True
failed _ = False
none = OptimizationOptions False False False False False False False False False False S.empty

main = do
  checkExports
  -- Generated worker metadata must survive later passes and describe its ABI.
  let v=CVar
      sumBody=CIf (app "==" [v "n",CInt 0]) (v "a")
        (app "sum" [app "-" [v "n",CInt 1],app "+" [v "a",v "n"]])
      source=M.singleton "sum" (["n","a"],sumBody)
      opts=none {optWorkers=True,optScalarWorkers=True,optNormalize=True,optReuse=True}
      result=right (optimizeCore opts S.empty source)
      sigs=optimizedSignatures result
      worker="$worker.scalar.sum"
  check "private worker created" (M.member worker (optimizedProgram result))
  check "worker ABI retained through normalization and reuse" (M.lookup worker sigs==Just ([KI,KI],KI))
  check "public entry retained" (fst (optimizedProgram result M.! "sum")==["n","a"])
  check "named pass order" (map passName (optimizationReports result)==
    [FuseVectors,MakeWorkers,NormalizeForReuse,ReuseConstructors,Trmc,BatchTicks,PairReturns])
  check "pass activation" (map passEnabled (optimizationReports result)==[False,True,True,True,False,False,False])
  check "missing function refused" (failed (verifyPassResult source M.empty M.empty))
  check "entry arity drift refused" (failed (verifyPassResult source (M.singleton "sum" (["n"],CInt 0)) M.empty))
  check "duplicate parameters refused" (failed (optimizeCore none S.empty (M.singleton "f" (["x","x"],v "x"))))
  check "dangling worker ABI refused" (failed (verifyPassResult source source sigs))
  check "mismatched worker ABI refused" (failed (verifyPassResult source (optimizedProgram result) (M.singleton worker ([KI],KI))))
  check "public function cannot acquire private ABI" (failed (verifyPassResult source source (M.singleton "sum" ([KI,KI],KI))))
  -- Preserve the established opt-out: normalization belongs to reuse here.
  let aliases=M.singleton "entry" (["x"],CLet "alias" (v "x") (v "alias"))
      disabled=right (optimizeCore (none {optNormalize=True}) S.empty aliases)
      normalized=right (optimizeCore (none {optNormalize=True,optReuse=True}) S.empty aliases)
  check "reuse opt-out retains Core" (optimizedProgram disabled==aliases)
  check "reuse input is normalized" (snd (optimizedProgram normalized M.! "entry")==v "x")
  check "disabled worker diagnostic retained" (optimizationNotes disabled==["# private workers: fields=0 scalar=0"])
  -- A self-looping function keeps one tick per iteration: the entry ticks of
  -- callees inlined into its body are dropped. Non-looping functions and the
  -- rollback keep theirs.
  let tick=CApp (CVar entryTickName) (CInt 0)
      ticked b=CLet "$inlined.tick" tick b
      loopDef=(["n","a"],CIf (app "==" [v "n",CInt 0]) (v "a")
        (ticked (app "loop" [app "-" [v "n",CInt 1],CMk 2 1 [ticked (v "n"),v "a"]])))
      helperDef=(["n"],ticked (app "+" [v "n",CInt 1]))
      shadowLoopDef=(["shadowLoop","x"],ticked (app "shadowLoop" [v "x"]))
      tickInput=M.fromList [("loop",loopDef),("helper",helperDef),("shadowLoop",shadowLoopDef)]
      tickOnResult=right (optimizeCore (none {optTickBatch=True}) S.empty tickInput)
      tickOn=optimizedProgram tickOnResult
      tickOff=optimizedProgram (right (optimizeCore none S.empty tickInput))
      hasTick name p=case M.lookup name p of Just (_,b)->"$fuel" `isInfixOf` show b; Nothing->False
  check "self-looping function batches inlined entry ticks including inside CMk" (not (hasTick "loop" tickOn))
  check "non-looping function keeps its inlined entry tick" (hasTick "helper" tickOn)
  check "shadowed parameter does not trigger self-loop tick batching" (hasTick "shadowLoop" tickOn)
  check "tick batching rollback keeps inlined entry ticks" (hasTick "loop" tickOff)
  check "tick batching reports its decision"
    ("# tick batching: self-loops=1 batched=1" `elem` optimizationNotes tickOnResult)
  -- B2 TRMC: accumulator-reverse list loops and two-pass append.
  let revOntoDef=(["xs","acc"],CIf (CTagEq 2 0 (v "xs")) (v "acc")
        (app "revOnto" [CProj 1 (v "xs"),CMk 2 1 [CProj 0 (v "xs"),v "acc"]]))
      reverseDef=(["xs"],app "revOnto" [v "xs",CMk 2 0 []])
      mapGoDef=(["f","xs","acc"],CIf (CTagEq 2 0 (v "xs")) (app "reverse" [v "acc"])
        (app "mapGo" [v "f",CProj 1 (v "xs"),CMk 2 1 [CApp (v "f") (CProj 0 (v "xs")),v "acc"]]))
      filterGoDef=(["p","xs","acc"],CIf (CTagEq 2 0 (v "xs")) (app "revOnto" [v "acc",CMk 2 0 []])
        (CIf (CTagEq 1 1 (CApp (v "p") (CProj 0 (v "xs"))))
          (app "filterGo" [v "p",CProj 1 (v "xs"),CMk 2 1 [CProj 0 (v "xs"),v "acc"]])
          (app "filterGo" [v "p",CProj 1 (v "xs"),v "acc"])))
      appendDef=(["xs","ys"],app "revOnto" [app "revOnto" [v "xs",CMk 2 0 []],v "ys"])
      trmcInput=M.fromList [("revOnto",revOntoDef),("reverse",reverseDef),
                            ("mapGo",mapGoDef),("filterGo",filterGoDef),("append",appendDef)]
      trmcOnResult=right (optimizeCore (none {optTrmc=True}) S.empty trmcInput)
      trmcOn=optimizedProgram trmcOnResult
      trmcOff=optimizedProgram (right (optimizeCore none S.empty trmcInput))
  check "TRMC creates private workers for accumulator-reverse list loops"
    (M.member "$worker.trmc.mapGo" trmcOn && M.member "$worker.trmc.filterGo" trmcOn)
  check "TRMC leaves revOnto and reverse untouched"
    (not (M.member "$worker.trmc.revOnto" trmcOn) && M.lookup "revOnto" trmcOn==Just revOntoDef)
  check "TRMC rewrites two-pass append to single-pass worker"
    (M.member "$worker.trmc.append" trmcOn && "$worker.trmc.append" `isInfixOf` show (trmcOn M.! "append"))
  check "TRMC workers link tail cells with $trmc.setTail"
    ("$trmc.setTail" `isInfixOf` show (trmcOn M.! "$worker.trmc.mapGo")
     && not ("reverse" `isInfixOf` show (trmcOn M.! "$worker.trmc.mapGo")))
  -- A worker nothing calls saves nothing: the entry must branch into it when
  -- the accumulator is empty and keep the original loop otherwise.
  check "TRMC entries transition into their worker"
    (all (\n -> ("$worker.trmc." ++ n) `isInfixOf` show (snd (trmcOn M.! n))) ["mapGo","filterGo"]
     && "$worker.trmc.append" `isInfixOf` show (snd (trmcOn M.! "append")))
  check "TRMC reports loop and append counts"
    ("# trmc: loops=2 appends=1" `elem` optimizationNotes trmcOnResult)
  check "TRMC rollback leaves program unchanged" (trmcOff==trmcInput)
  -- A pair answered to a caller that only decides its shape and reads its
  -- fields is answered in two registers (the $worker.ret2 twin).
  let pairF=(["n"],CIf (app "==" [v "n",CInt 0]) (CMk 4 0 [CInt 0,CInt 0])
        (CLet "t" (app "pairf" [app "-" [v "n",CInt 1]])
          (CIf (CTagEq 4 0 (v "t"))
            (CLet "s" (CProj 0 (v "t")) (CLet "c" (CProj 1 (v "t")) (CMk 4 0 [app "+" [v "s",v "n"],app "+" [v "c",CInt 1]])))
            (CErr "no match"))))
      escapes=(["n"],CLet "t" (app "pairf" [v "n"]) (CMk 4 0 [v "t",v "t"]))
      partialPair=(["n"],CLet "unused" (CVar "pairf") (CInt 42))
      shadowPair=(["pairf","x"],app "pairf" [v "x"])
      pairInput=M.fromList [("pairf",pairF),("escapes",escapes),("partialPair",partialPair),("shadowPair",shadowPair)]
      pairOnResult=right (optimizeCore (none {optPairReturns=True}) S.empty pairInput)
      pairOn=optimizedProgram pairOnResult
      callsTwin name=maybe False (("$worker.ret2.pairf" `isInfixOf`) . show . snd) (M.lookup name pairOn)
  check "pair returns create a twin for the recursive pair function" (M.member "$worker.ret2.pairf" pairOn)
  check "pair returns route the recursive call through the twin" (callsTwin "$worker.ret2.pairf")
  check "pair returns keep the original function" (fmap fst (M.lookup "pairf" pairOn)==Just ["n"])
  check "pair returns leave an escaping pair alone" (M.lookup "escapes" pairOn==Just escapes)
  check "pair returns do not rewrite partial or unused applications" (M.lookup "partialPair" pairOn==Just partialPair)
  check "pair returns do not misclassify shadowed local calls" (not (M.member "$worker.ret2.shadowPair" pairOn))
  check "pair returns report their decision" (any ("# pair returns:" `isInfixOf`) (optimizationNotes pairOnResult))
  check "pair returns rollback keeps the word ABI" (not (M.member "$worker.ret2.pairf" (optimizedProgram (right (optimizeCore none S.empty pairInput)))))
  let nested=app "Vec.map" [v "inc",app "Vec.map" [v "double",v "xs"]]
      fusionInput=M.fromList [("inc",(["x"],app "+" [v "x",CInt 1])),
                             ("double",(["x"],app "*" [v "x",CInt 2])),
                             ("checked",(["xs"],nested)),("compatibility",(["xs"],nested))]
      fusionOutput=optimizedProgram (right (optimizeCoreWithCheckedImports (S.singleton "checked") M.empty
        (none {optFusion=True}) S.empty fusionInput))
  check "checked owners bypass erased callback composition" (fusionOutput M.! "checked"==fusionInput M.! "checked")
  check "compatibility owner still composes callbacks" (fusionOutput M.! "compatibility"/=fusionInput M.! "compatibility")
  -- Typed operation payloads: mixed pipelines retain stage/capture order.
  let callbacks=M.fromList [("inc",(["x"],app "+" [v "x",CInt 1])),
                            ("pos",(["x"],app ">" [v "x",CInt 0]))]
      expr=app "Vec.map" [v "inc",app "Vec.filter" [v "pos",v "xs"]]
      (plan,args)=maybe (error "pipeline admission") id (pipelinePlan callbacks (=="xs") expr)
      expected="pipeline@PipePlan {pipeStages = [(\"filter\",\"pos\",[]),(\"map\",\"inc\",[])], pipeElement = KI, pipeAccumulator = Nothing}"
  check "typed pipeline stages" (case spOp plan of
    FusedPipeline p -> pipeStages p==[(Filter,"pos",[]),(Map,"inc",[])]
    _ -> False)
  check "entry vector order" (args==[v "xs"])
  check "existing symbol serialization" (operationKey (spOp plan)==expected)
  check "shadowed primitive declines" (case pipelinePlan callbacks (`elem` ["xs","Vec.map"]) expr of Nothing->True; _->False)
  check "layout payload survives punctuation" (operationKey (LayoutMap "a@b")=="mapAs@a@b")
  let layoutExpr=app "Vec.mapAs" [CStr "a@b",v "inc",v "xs"]
  check "layout plan has typed payload" (case vecSpec False callbacks (=="xs") layoutExpr of
    Just (p,_) -> spOp p==LayoutMap "a@b"
    _ -> False)
  check "float primitive inventory" ("F32.+" `elem` fPrimsOf Float32 && "F64.+" `notElem` fPrimsOf Float32)
  -- A checked-in byte oracle made from the previous FPRISC.Core definition.
  -- Every constructor appears, including Unicode and multi-byte integers.
  let nodes=[CVar "x",CInt (-12345678901234567890),CStr "λ\n",CApp (v "f") (CInt 1),
             CLam ["x"] (v "x"),CLet "x" (CInt 3) (v "x"),CIf (v "c") (CInt 1) (CInt 0),
             CMk 12 2 [v "x"],CTagEq 12 2 (v "x"),CProj 3 (v "x"),CErr "bad"]
      bytes=encode nodes
      hex=concatMap (\b -> let s=showHex b "" in if length s==1 then '0':s else s) (B.unpack bytes)
  oracle<-readFile "tests/core-binary-v1.hex"
  check "Core Binary cache compatibility" (hex==concat (lines oracle))
  check "Core Binary roundtrip" ((decode bytes :: [Core])==nodes)
  check "lexical shadowing" (freeVars (CLet "x" (v "outside") (CLam ["outside"] (v "x")))==["outside"])
  check "occurs respects lambda binder" (not (occurs "x" (CLam ["x"] (v "x"))))
  putStrLn "Core pipeline: ABI checks, pass ordering, typed vector plans and Binary compatibility passed"
