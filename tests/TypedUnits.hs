import Infer
import Infer.Result
import Core.Identity
import Core.Syntax
import Core.CacheIdentity
import Core.Typed.Close
import qualified Core.Typed.Syntax as T
import qualified Codegen.Lower as Lower
import qualified Codegen.Eval as Eval
import Codegen.Policy (m2Policy)
import Frontend.Parser (program)
import Frontend.Syntax (STop(..))
import Frontend.Desugar
import Frontend.Desugar.Checked
import Control.Monad (unless)
import Control.Monad.State.Strict (evalState)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Text.Megaparsec (parse,errorBundlePretty)

check label ok=unless ok (error label)
right=either error id
failed (Left _)=True
failed _=False
main=do
  let source="provider n = n + 1. client n = provider n + provider n. recursive n = loop k = if k == 0 then provider n else loop (k - 1); loop 2."
      tops=right (either (Left . errorBundlePretty) Right (parse program "units" source))
      checked=inferTopsChecked (Namespace "unit-tests") aotProf M.empty M.empty tops
  check ("source checking: "++show (inferenceErrors checked)) (null (inferenceErrors checked))
  let plans=right (prepareChecked checked)
      names=S.fromList ["client","recursive"]
      unit=right (selectCheckedUnit plans names)
      resolved=inferenceTops checked
      initial=DEnv 0 (collectCons "unit" resolved) (collectShapes resolved) [] []
      product=evalState (desugarCheckedUnit unit) initial
      own=evalState (lowerCheckedUnit unit >>= liftFix) initial
      provider=evalState (lowerCheckedUnit (right (selectCheckedUnit plans (S.singleton "provider"))) >>= liftFix) initial
      allCode=M.union own provider
      (ir,_)=Lower.lowerProgram m2Policy M.empty allCode allCode M.empty M.empty
  check "unit owns exactly the requested definitions" (checkedUnitNames unit==names)
  check "unit has the authoritative elaborated clauses"
    (show (checkedUnitTops unit)==show [t | t@(TBind n _ _ _)<-resolved,n `S.member` names])
  check "missing source owners are refused" (failed (selectCheckedUnit plans (S.singleton "absent")))
  check "empty unit is valid" (null (checkedUnitTops (right (selectCheckedUnit plans S.empty))))
  check "unit lowering retains typed source entries and excludes other owners"
    (names `S.isSubsetOf` M.keysSet (desugaredTyped product) && M.notMember "provider" (desugaredTyped product))
  check "recursive unit code is a typed closed product"
    (any ((==T.ClosureCode) . T.codeKind) (M.elems (closedCode (desugaredClosed product M.! "recursive"))))
  check "calling arities come from the same elaborated run"
    (all (==Just 1) [M.lookup n (checkedCallArities plans) | n<-"provider":S.toList names])
  check "separately lowered checked units compose with exact answers"
    (Eval.ocResult (Eval.evalProgram ir "client" [Eval.RInt 3])==Right (Eval.RInt 8)
     && Eval.ocResult (Eval.evalProgram ir "recursive" [Eval.RInt 3])==Right (Eval.RInt 4))
  let program=M.singleton "entry" (["x"],CApp (CVar "external") (CVar "x"))
      calls=CallArities (M.singleton "external" 1) M.empty
      key elided context=coreCacheIdentity elided context
      old=key S.empty calls program
  check "external entry arities affect cache identity"
    (old/=key S.empty (CallArities (M.singleton "external" 2) M.empty) program)
  check "referenced external reset effects affect cache identity"
    (old/=coreCacheIdentityWithResetters (S.singleton "external") S.empty calls program)
  check "unrelated reset effects preserve cache identity"
    (old==coreCacheIdentityWithResetters (S.singleton "unrelated") S.empty calls program)
  check "global/primitive call classification affects cache identity"
    (old/=key S.empty (CallArities M.empty (M.singleton "external" 1)) program)
  check "unrelated calling contracts do not invalidate a unit"
    (old==key S.empty (CallArities (M.insert "unused" 2 (globalCalls calls)) M.empty) program)
  check "resolved operations affect cache identity"
    (old/=key S.empty calls (M.singleton "entry" (["x"],CApp (CVar "other") (CVar "x"))))
  let elided=S.fromList ["Unused","Used","Dependency"]
      constructors=M.fromList [("Unused",([],CMk 42 0 [])),("Used",([],CVar "Dependency")),("Dependency",([],CMk 43 0 []))]
      withUnused=M.union program constructors
      usesConstructor=M.insert "entry" ([],CVar "Used") withUnused
      altered=M.insert "Dependency" ([],CMk 44 0 []) usesConstructor
  check "unreferenced elided constructors do not invalidate a unit" (old==key elided calls withUnused)
  check "transitive elided constructor bodies affect inlining and cache identity"
    (key elided calls usesConstructor/=key elided calls altered)
  let shadow=M.singleton "entry" ([],CLet "external" (CInt 3) (CVar "external"))
  check "a lexical binder is not an external contract dependency"
    (key S.empty calls shadow==key S.empty (CallArities M.empty M.empty) shadow)
  putStrLn "Typed units: owned checked projections, missing-owner refusals, recursive composition and precise lowered-input/call cache dependencies passed"
