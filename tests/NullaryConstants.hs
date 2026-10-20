import Codegen (emitProgram, rv32, rv64, Target(..))
import FPRISC (Core(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isInfixOf)
import Control.Monad (unless)

check name yes = unless yes (error name)
main = do
  let prog = M.fromList [("Unit",([],CMk 0 0 [])),
                        ("Unused",([],CMk 99 0 [])),
                        ("get",([],CVar "Unit")),
                        ("again",([],CVar "Unit"))]
      emit t p = fst (emitProgram t False False [] M.empty
                      (S.fromList ["get","again"]) (S.fromList ["Unit","Unused"]) p)
  mapM_ (\target -> do
    let t = target {tgtArc=True,tgtFuel=False}
        asm = emit t prog
    check "elided constructor function stays elided" (not ("fpr_fn_Unit:" `isInfixOf` asm))
    check "referenced local nullary is defined exactly once"
      (length (filter (== ".Lnul_0_0:") (lines asm)) == 1)
    check "both constructor references use the local constant"
      (length (filter (== "    la a0, .Lnul_0_0") (lines asm)) == 2)
    check "unreferenced elided nullary stays absent" (not (".Lnul_99_0:" `isInfixOf` asm))
    let shadow = emit t (M.insert "get" (["Unit"],CVar "Unit") (M.delete "again" prog))
    check "a shadowing parameter does not materialize a constructor"
      (not (".Lnul_0_0:" `isInfixOf` shadow))
    ) [rv32,rv64]
  let base = emit rv64 prog
  check "ordinary base calls do not materialize elided nullaries"
    (not (".Lnul_0_0:" `isInfixOf` base))
  -- Indexed-memory lowering synthesizes Unit for the release. There is
  -- deliberately no CMk or constructor definition in the original Core.
  let app h = foldl CApp (CVar h)
      get = (["p","i"],CLet "addr" (app "Addr.add" [CVar "p",CVar "i"])
               (CLet "value" (app "Mem.read8" [CVar "addr"])
                 (CLet "released" (app "Rc.release" [CVar "addr"]) (CVar "value"))))
      hal = M.fromList [("Addr.add",2),("Mem.read8",1),("Rc.release",1)]
  mapM_ (\target -> do
    let t = target {tgtFuel=False,tgtArc=False,tgtHal=hal}
        asm = fst (emitProgram t False False [] M.empty (S.singleton "get") S.empty (M.singleton "get" get))
    check "indexed memory actually fused" ("fpr_prim_fn__x24mem_x2eread8at" `isInfixOf` asm)
    check "synthesized Unit reference has a definition"
      ("    la a0, .Lnul_0_0" `isInfixOf` asm && ".Lnul_0_0:" `isInfixOf` asm)
    ) [rv32,rv64]
  putStrLn "Nullary constants: lowering-created Unit, elided functions, unique definitions, unused constructors, shadowing and Base boundary PASS"
