import ExportPlans (checkExports)
import Core.Syntax
import Core.Opt.Pipeline
import Core.Opt.Vector (vecSpec, pipelinePlan)
import Core.Opt.Vector.Plan
import Core.Primitives
import KernelKinds (Kind(..))
import Control.Monad (unless)
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
none = OptimizationOptions False False False False False False

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
    [FuseVectors,MakeWorkers,NormalizeForReuse,ReuseConstructors])
  check "pass activation" (map passEnabled (optimizationReports result)==[False,True,True,True])
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
