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
