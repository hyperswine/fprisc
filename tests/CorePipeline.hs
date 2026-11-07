import ExportPlans (checkExports)
import Core.Syntax
import Core.Opt.Pipeline
import Core.Opt.PairReturns (productWorkerWidth,productReturnProgramWithVariants)
import Core.Opt.Vector (vecSpec, pipelinePlan)
import Core.Opt.Vector.Plan
import Core.Primitives
import KernelKinds (Kind(..))
import Control.Monad (unless, forM_)
import Control.Exception (ErrorCall(..), evaluate, try)
import Workers (Agreement(..), signatureAgreement)
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
none = OptimizationOptions False False False False False False 2 False False S.empty

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
  -- P2 signature bridge: KernelKinds' worker signature against checked kinds
  let bridge ck=signatureAgreement (M.fromList ck) sigs
      counts a=(agreed a,guarded a,unchecked a)
  check "bridge: checked Int signature agrees" (counts (bridge [("sum",([Just KI,Just KI],Just KI))])==(1,0,0))
  check "bridge: a non-raw checked parameter stays guarded" (counts (bridge [("sum",([Nothing,Just KI],Just KI))])==(0,1,0))
  check "bridge: no checked interface is unchecked" (counts (bridge [])==(0,0,1))
  check "bridge: an arity mismatch is unchecked" (counts (bridge [("sum",([Just KI],Just KI))])==(0,0,1))
  conflict <- try (evaluate (agreed (bridge [("sum",([Just KB,Just KI],Just KI))])))
  check "bridge: a disagreement stops the compile" (case conflict of
    Left (ErrorCall msg) -> "signature bridge" `isInfixOf` msg
    Right _ -> False)
  check "named pass order" (map passName (optimizationReports result)==
    [FuseVectors,MakeWorkers,NormalizeForReuse,ReuseConstructors,PairReturns])
  check "pass activation" (map passEnabled (optimizationReports result)==[False,True,True,True,False])
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
  -- Batched fuel ticks are decided after lowering (Codegen.Placement, tests/Placement.hs).
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
  let sumLayout=(887,M.fromList [(0,0),(1,1),(2,2)])
      sumFacts=M.singleton "produce" sumLayout
      payload=v "payload"
      choose=(["n"],CIf (v "n") (CMk 887 0 []) (CMk 887 2 [CInt 4,CInt 5]))
      guarded=CIf (CTagEq 887 2 payload) (CProj 1 payload) (CInt 14)
      readSum params expr=(params,CLet "payload" (app "produce" [CInt 1]) expr)
      variantEntry="$worker.ret3.$variant.produce"
      inputs=M.fromList [("produce",choose),("good",readSum [] guarded),
        ("badField",readSum [] (CProj 0 payload)),("capture",readSum [] (CLam ["z"] guarded)),
        ("escape",readSum [] payload),("privateShadow",readSum [variantEntry] guarded),
        ("eqShadow",readSum ["=="] guarded),("calleeShadow",readSum ["produce"] guarded)]
      transformed facts program=let (p,_,_)=productReturnProgramWithVariants facts 8 program M.empty in p
      resultSums=transformed sumFacts inputs
  check "variant reader retains a discriminant and admits dominated fields"
    (M.member variantEntry resultSums && M.lookup "good" inputs/=M.lookup "good" resultSums)
  forM_ ["badField","capture","escape","privateShadow","eqShadow","calleeShadow"] $ \name->
    check ("variant fallback at "++name) (M.lookup name inputs==M.lookup name resultSums)
  check "ordinary sum calls and colliding private names retain the public ABI"
    (M.lookup "produce" resultSums==Just choose
      && let collision=M.insert variantEntry ([],CInt 99) inputs in transformed sumFacts collision==collision)
  check "source constructor observations alone cannot choose a smaller sum layout"
    (transformed M.empty inputs==inputs)
  check "unary return workers retain the ordinary tagged-value convention"
    (productWorkerWidth "$worker.ret1.product" == Nothing)
  forM_ [1..9] $ \n -> do
    let shape = CMk 4 0 [app "+" [v "n", CInt (toInteger i)] | i <- [0..n-1]]
        source = M.fromList [("product",(["n"],shape)),
          ("reader",(["n"],CLet "p" (app "product" [v "n"]) (CProj (n-1) (v "p")))),
          ("escape",(["n"],CLet "p" (app "product" [v "n"]) (v "p")))]
    forM_ [1,2,8] $ \width -> do
      let output = optimizedProgram (right (optimizeCore (none {optPairReturns=True,optProductWidth=width}) S.empty source))
          twin = "$worker.ret" ++ show n ++ ".product"
      check "target width controls product admission" (M.member twin output == (n <= width))
      check "escaping products retain their tagged call" (output M.! "escape" == source M.! "escape")
      check "original product entry stays available" (output M.! "product" == source M.! "product")
      if n==1 then do
        check "unary worker returns its evaluated payload"
          (M.lookup twin output == Just (["n"],app "+" [v "n",CInt 0]))
        check "unary reader uses the returned value without projecting it"
          (M.lookup "reader" output == Just (["n"],CLet "p" (app twin [v "n"]) (v "p")))
      else pure ()
  let unary=(["n"],CMk 999 0 [v "n"])
      prefixed=(["n"],CLet "box" (CLet "arg" (app "print" [v "n"]) (app "unary" [v "arg"]))
        (CProj 0 (v "box")))
      capture=(["arg"],CLet "box" (CLet "arg" (CInt 7) (app "unary" [v "arg"]))
        (app "+" [CProj 0 (v "box"),v "arg"]))
      shadow=(["n"],CLet "box" (CLet "unary" (v "n") (app "unary" [CInt 7])) (CProj 0 (v "box")))
      privateShadow=(["n"],CLet "box" (CLet "$worker.ret1.unary" (v "n") (app "unary" [CInt 7])) (CProj 0 (v "box")))
      unaryInput=M.fromList [("unary",unary),("prefixed",prefixed),("capture",capture),("shadow",shadow),("privateShadow",privateShadow)]
      unaryOutput=optimizedProgram (right (optimizeCore (none {optPairReturns=True}) S.empty unaryInput))
  check "strict producer prefixes keep effects before the payload call"
    (unaryOutput M.! "prefixed" == (["n"],CLet "arg" (app "print" [v "n"])
      (CLet "box" (app "$worker.ret1.unary" [v "arg"]) (v "box"))))
  check "producer prefix cannot capture a consumer's outer variable" (unaryOutput M.! "capture"==capture)
  check "producer prefix shadowing cannot supply a known return shape" (unaryOutput M.! "shadow"==shadow)
  check "producer prefix cannot capture the new worker reference" (unaryOutput M.! "privateShadow"==privateShadow)
  let returnOpt p = optimizedProgram (right (optimizeCore (none {optPairReturns=True}) S.empty p))
      longResult=foldr (\i b -> CLet ("v"++show i) (app "+" [v "n",CInt i]) b) (snd unary) [1..300]
      reader f=(["n"],CLet "r" (app f [v "n"]) (CProj 0 (v "r")))
      chain=[("h"++show i,(["n"],app ("h"++show (i+1)) [v "n"])) | i<-[0..159::Int]]
      longGraph=M.fromList (("reader",reader "h0"):("h160",(["n"],longResult)):chain)
      longOutput=returnOpt longGraph
  check "large result and every reachable forwarding worker are admitted"
    (all (\i -> M.member ("$worker.ret1.h"++show i) longOutput) [0..160::Int])
  let collision=M.insert "$worker.ret1.unary" (["x"],CInt 0) (M.fromList [("unary",unary),("reader",reader "unary")])
      captureTail=M.fromList [("unary",unary),("reader",reader "outer"),
        ("outer",(["n"],CLet "$worker.ret1.unary" (CInt 1) (app "unary" [v "n"])))]
  check "existing private return name preserves original calls" (returnOpt collision==collision)
  check "tail worker cannot capture a lexical binding" (returnOpt captureTail==captureTail)
  let pair a b = CMk 4 0 [a,b]
      makeTree=( ["x"],pair (pair (v "x") (CInt 2)) (pair (CInt 3) (CInt 4)))
      treeReader=(["x"],CLet "result" (app "tree" [v "x"])
        (CLet "l" (CProj 0 (v "result")) (CLet "alias" (v "l")
          (CIf (CTagEq 4 0 (v "alias")) (app "+" [CProj 1 (v "alias"),CProj 0 (CProj 1 (v "result"))]) (CErr "bad")))))
      treeProg=M.fromList [("tree",makeTree),("reader",treeReader)]
      treeOpt w p=optimizedProgram (right (optimizeCore (none {optPairReturns=True,optProductWidth=w}) S.empty p))
      deepEntry="$worker.ret4.$nested.result.tree"
      flat=treeOpt 4 treeProg
      innerEscape=(["x"],CLet "result" (app "tree" [v "x"]) (CProj 0 (v "result")))
      tagMismatch=(["x"],CLet "result" (app "tree" [v "x"]) (CIf (CTagEq 999 0 (CProj 0 (v "result"))) (CInt 1) (CInt 0)))
      captureTree=(["x"],CLet "result" (app "tree" [v "x"]) (CLam [] (CProj 0 (CProj 0 (v "result")))))
  check "nested packet follows aliases and maps projections to flat words"
    (M.lookup "reader" flat == Just (["x"],CLet "result" (app deepEntry [v "x"]) (app "+" [CProj 1 (v "result"),CProj 2 (v "result")])))
  check "nested packet retains public entry" (flat M.! "tree"==makeTree)
  check "flattened width must fit the target" (M.notMember deepEntry (treeOpt 2 treeProg))
  mapM_ (\reader -> check "inner escape, capture or foreign tag cannot use a flat packet"
    (M.notMember deepEntry (treeOpt 4 (M.insert "reader" reader treeProg)))) [innerEscape,captureTree,tagMismatch]
  let collided=M.insert deepEntry (["x"],v "x") treeProg
      conflict=(["x"],CLet "inner" (pair (CInt 1) (CInt 2)) (CLet "effect" (app "print" [v "inner"]) (pair (v "inner") (pair (v "x") (v "x")))))
  check "existing private symbol cannot be replaced" (treeOpt 4 collided M.! deepEntry==collided M.! deepEntry)
  check "strict let cannot be both a packet and an ordinary effect argument"
    (M.notMember deepEntry (treeOpt 4 (M.insert "tree" conflict treeProg)))
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
  let reference e=case e of
        CVar n->[n]
        CApp a b->reference a++reference b
        CLam ps b->filter (`notElem` ps) (reference b)
        CLet n a b->reference a++filter (/=n) (reference b)
        CIf c t f->reference c++reference t++reference f
        CMk _ _ fs->concatMap reference fs
        CTagEq _ _ x->reference x
        CProj _ x->reference x
        _->[]
      generated 0 n=CVar (["x","y","z"]!!(n `mod` 3))
      generated depth n=let { a=generated (depth-1) (n*5+1); b=generated (depth-1) (n*7+3);
                             name=["x","y","z"]!!(n `mod` 3) }
                       in case n `mod` 8 of
                         0->CLet name a b
                         1->CLam [name,"x"] a
                         2->CApp a b
                         3->CIf a b (CVar name)
                         4->CMk 9 0 [a,b,CVar name]
                         5->CTagEq 9 0 a
                         6->CProj 0 a
                         _->CVar name
  check "free occurrences preserve order, duplicates and lexical scope"
    (all (\e->freeVars e==reference e) (nodes++[generated 6 n | n<-[0..255]]))
  putStrLn "Core pipeline: ABI checks, pass ordering, typed vector plans and Binary compatibility passed"
