import Codegen (emitProgram, rv32, rv64, Target(..))
import Codegen.Policy (Policy(..),Profile(..),StackPolicy(..))
import FPRISC (Core(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isInfixOf)
import Control.Monad (unless)

check name yes = unless yes (error name)
main = do
  let prog = M.fromList [("Token",([],CMk 42 2 [])),
                        ("Unused",([],CMk 99 0 [])),
                        ("get",([],CVar "Token")),
                        ("again",([],CVar "Token"))]
      emit t p = fst (emitProgram t False False [] M.empty
                      (S.fromList ["get","again"]) (S.fromList ["Token","Unused"]) p)
  mapM_ (\target -> do
    let t = target {tgtArc=True,tgtFuel=False,tgtPolicy=(tgtPolicy target) {polProfile=if tgtW target==4 then Builtin32 else BuiltinArc,polFuel=False,polStackCheck=StackStatic}}
        asm = emit t prog
    check "elided constructor function stays elided" (not ("fpr_fn_Token:" `isInfixOf` asm))
    check "referenced local nullary is defined exactly once"
      (length (filter (== ".Lnul_42_2:") (lines asm)) == 1)
    check "both constructor references use the local constant"
      (length (filter (isInfixOf ", .Lnul_42_2") (lines asm)) == 2)
    check "unreferenced elided nullary stays absent" (not (".Lnul_99_0:" `isInfixOf` asm))
    let shadow = emit t (M.insert "get" (["Token"],CVar "Token") (M.delete "again" prog))
    check "a shadowing parameter does not materialize a constructor"
      (not (".Lnul_42_2:" `isInfixOf` shadow))
    ) [rv32,rv64]
  let base = emit rv64 prog
  check "Base materializes a referenced immortal constructor once"
    (length (filter (== ".Lnul_42_2:") (lines base))==1)
  let unit=fst (emitProgram rv64 False False [] M.empty S.empty S.empty
                    (M.singleton "unit" ([],CMk 0 0 [])))
  check "Unit references the canonical runtime object" (", fpr_unit" `isInfixOf` unit)
  putStrLn "Native constants: elided constructors, unique definitions, unused constructors, shadowing, Base and canonical Unit PASS"
