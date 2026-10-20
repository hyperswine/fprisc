import Codegen.Lower
import Codegen.IR
import Codegen.Eval
import Codegen.Verify
import Codegen.Dump
import Workers
import FPRISC (Core(..))
import qualified Data.Map.Strict as M
app f = foldl CApp (CVar f)
v = CVar
main = do
 let mixed = (["z", "a"], CIf (app "<" [v "z", CInt 1]) (CIf (CTagEq 1 1 (v "a")) (app "+" [v "z",CInt 1]) (app "+" [v "z",CInt 2])) (app "mixed" [app "-" [v "z",CInt 1],v "a"]))
     boolEq = (["n", "b"], CIf (app "==" [v "n", CInt 0]) (app "==" [v "b", CMk 1 1 []]) (app "boolEq" [app "-" [v "n",CInt 1],v "b"]))
 mapM_ (\(name, def, args) -> do
   let (p, notes) = workerize False True (M.singleton name def)
       (ir, failures) = lowerProgram p M.empty
   putStrLn name
   print notes
   print (workerSignatures p)
   print failures
   print (verifyProgram ir)
   print (ocResult (evalProgram ir name args)))
   [("mixed",mixed,[RInt 2,rvBool True]),("boolEq",boolEq,[RInt 2,rvBool True])]
