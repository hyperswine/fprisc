import FPRISC (Core(..))
import Workers
import qualified Data.Map.Strict as M
import Control.Monad (unless)
app n = foldl CApp (CVar n)
check n p = unless p (error n)
main = do
  let v=CVar; pair a b=CMk 4 0 [a,b]
      loop=( ["n","p"], CIf (CTagEq 4 0 (v "p"))
         (CIf (app "==" [v "n",CInt 0]) (pair (CProj 0 (v "p")) (CProj 1 (v "p")))
           (app "loop" [app "-" [v "n",CInt 1],pair (CProj 0 (v "p")) (CProj 1 (v "p"))])) (CErr "shape"))
      p=M.fromList [("loop",loop),("main",([],app "loop" [CInt 10,pair (CInt 0) (CInt 0)]))]
      out=fst (workerize True False p)
  check "two fields selected" (M.member "$worker.fields.loop" out)
  check "original arity retained" (fst (out M.! "loop")==["n","p"])
  let shadow=M.insert "shadow" (["loop"],app "loop" [CInt 10,pair (CInt 0) (CInt 0)]) p
  check "lexical shadow preserved" (fst (workerize True False shadow) M.! "shadow"==shadow M.! "shadow")
  let escape=M.insert "loop" (["n","p"],CIf (app "==" [v "n",CInt 0]) (v "p") (snd loop)) p
  check "whole value escaping declines" (not (M.member "$worker.fields.loop" (fst (workerize True False escape))))
  let variable=M.insert "other" ([],CMk 4 0 [CInt 1]) p
  check "variable constructor arity declines" (not (M.member "$worker.fields.loop" (fst (workerize True False variable))))
  -- Wider products use all fields in order, including the spill-cell limit.
  let wide width guarded =
        let fields=[CProj k (v "p") | k<-[0..width-1]]
            ctor=CMk 42 0
            body=CIf (app "==" [v "n",CInt 0]) (ctor fields)
                 (app "wide" [app "-" [v "n",CInt 1],ctor fields])
        in M.fromList [("wide",(["n","p"],if guarded then CIf (CTagEq 42 0 (v "p")) body (CErr "shape") else body)),
                       ("entry",([],app "wide" [CInt 10,ctor (map CInt [1..fromIntegral width])]))]
  mapM_ (\(width,guarded) -> do
    let source=wide width guarded; transformed=fst (workerize True False source)
        (params,body)=transformed M.! "$worker.fields.wide"
    check "wider worker arity" (length params==width+1)
    check "public wider arity" (fst (transformed M.! "wide")==["n","p"])
    check "distinct field names" (M.size (M.fromList [(p,()) | p<-params])==length params)
    check "all direct fields in original order"
      (snd (transformed M.! "entry")==app "$worker.fields.wide" (CInt 10:map CInt [1..fromIntegral width]))
    check "all wider projections reduced" (not (hasProj body)))
    [(width,guarded) | width<-[3,4,8,16,63], guarded<-[False,True]]
  check "expanded arity over native limit declines"
    (not (M.member "$worker.fields.wide" (fst (workerize True False (wide 64 True)))))
  let badProj=M.adjust (\(ps,b)->(ps,CLet "bad" (CProj 3 (v "p")) b)) "wide" (wide 3 True)
  check "out of bounds wider projection declines"
    (not (M.member "$worker.fields.wide" (fst (workerize True False badProj))))
  let rebound=M.adjust (\(ps,b)->(ps,CLet "wide" (v "unknown") b)) "wide" (wide 3 True)
  check "shadowed recursion declines"
    (not (M.member "$worker.fields.wide" (fst (workerize True False rebound))))
  let vectorsWide=M.insert "vec" ([],app "Vec.map" [v "wide",v "xs"]) (wide 3 True)
  check "wider vector callback unchanged" (fst (workerize True False vectorsWide)==vectorsWide)
  let shared=M.adjust (\(ps,b)->(ps,CLet "shared"
        (CIf (CTagEq 43 0 (v "p")) (CProj 7 (v "p")) (CProj 2 (v "p"))) b)) "wide" (wide 3 False)
      sharedOut=fst (workerize True False shared)
  check "record offsets in excluded shapes are harmless" (M.member "$worker.fields.wide" sharedOut)
  check "record original fallback retains other shape branch"
    (case snd (sharedOut M.! "wide") of
      CIf _ _ (CLet "shared" expr _) -> expr==CIf (CTagEq 43 0 (v "p")) (CProj 7 (v "p")) (CProj 2 (v "p"))
      _ -> False)
  let wideEscape=M.adjust (\(ps,b)->(ps,CLet "saved" (app "unknown" [v "p"]) b)) "wide" (wide 8 True)
  check "wider whole-value escape declines"
    (not (M.member "$worker.fields.wide" (fst (workerize True False wideEscape))))
  let mixed=M.insert "other" ([],CMk 42 0 [CInt 1,CInt 2]) (wide 3 True)
  check "inconsistent wider constructor width declines"
    (not (M.member "$worker.fields.wide" (fst (workerize True False mixed))))
  let forwarding=M.adjust (\(ps,b)->(ps,foldr (\k rest -> CLet ("forward"++show k)
        (app "wide" [CInt 0,v "p"]) rest) b [1..20])) "wide" (wide 63 True)
  check "expanded forwarding respects clone body budget"
    (not (M.member "$worker.fields.wide" (fst (workerize True False forwarding))))
  let scalar=( ["n","a"],CIf (app "==" [v "n",CInt 0]) (v "a") (app "sum" [app "-" [v "n",CInt 1],app "+" [v "a",v "n"]]))
      sums=M.fromList [("sum",scalar)]
  check "recursive scalar selected" (M.member "$worker.scalar.sum" (fst (workerize False True sums)))
  let vectors=M.insert "main" ([],app "Vec.map" [v "sum",v "vector"]) sums
  check "vector callback retains kernel view" (fst (workerize False True vectors)==vectors)
  let unknown=M.fromList [("eq",(["n","a","b"],CIf (app "==" [v "n",CInt 0]) (app "==" [v "a",v "b"]) (app "eq" [app "-" [v "n",CInt 1],v "a",v "b"])))]
  check "polymorphic equality declines" (fst (workerize False True unknown)==unknown)
  let helper=M.fromList [("sum",(["n","a"],app "+" [v "n",v "a"]))]
  check "one-off helper declines" (fst (workerize False True helper)==helper)
  let many=M.fromList [("f"++show n,(["x"],CIf (app "==" [v "x",CInt 0]) (CInt 0) (app ("f"++show n) [app "-" [v "x",CInt 1]]))) | n<-[1..300]]
  check "clone count bounded" (M.size (fst (workerize False True many))==M.size many+128)
  putStrLn "Workers Core: admission, public arity, shadowing, escaping values, unknown kinds, vector tier and clone budget PASS"

hasProj e = case e of
  CProj _ _ -> True
  CApp a b -> hasProj a || hasProj b
  CIf a b c -> any hasProj [a,b,c]
  CLet _ a b -> hasProj a || hasProj b
  CMk _ _ xs -> any hasProj xs
  CTagEq _ _ a -> hasProj a
  _ -> False
