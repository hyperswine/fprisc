import Core.Identity
import qualified Core.Typed.Syntax as T
import Core.Typed.Close
import Core.Typed.Resolve
import Core.Typed.Contract
import Core.Typed.Verify
import Core.Typed.Walk (mapChildrenM)
import Type.Syntax
import Infer
import Infer.Result
import Frontend.Parser (program)
import Frontend.Syntax
import Frontend.Desugar hiding (fresh)
import Frontend.Desugar.Checked
import Struct (sigTable,structTable,expandStructs,erasePSig)
import Text.Megaparsec (parse,errorBundlePretty)
import Ownership.TypeShape (linShapeT)
import Control.Monad (unless)
import Control.Monad.State.Strict
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

check name ok=unless ok (error name)
right=either error id
failed (Left _)=True
failed _=False
int=TC "Int"
bool=TC "Bool"
types=T.TypeContext [] M.empty
sc=Forall [] []
expr ty node=T.Expr ty (linShapeT [] ty) T.Generated Nothing node
binder i name scheme@(Forall _ _ ty)=T.Binder (BinderId (Namespace "typed-calls") i) name scheme (linShapeT [] ty)
ref b ty=expr ty (T.Var (T.Local (T.binderId b)))
fresh name=do n<-get;put (n+1::Int);pure (name++show n)
close f=right (evalState (closeFunction (Namespace "calls-test") fresh types f) 0)
calls e=(case T.exprNode e of T.CodeCall label _ _->[label];_->[])++getConst (mapChildrenM (Const . calls) e)

main=do
  let q=TV 0
      code=T.CodeId "identity"
      contract=T.CodeContract T.ClosureCode ([0],[]) [] [q] q
      valid ty=checkInstance contract [] (TFn ty ty)
  check "one code contract instantiates at Int and Bool" (valid int==Right () && valid bool==Right ())
  check "code argument/result variables stay linked" (failed (checkInstance contract [] (TFn int bool)))
  check "free contract variables are rigid" (failed (checkInstance (contract {T.contractQuantifiers=([],[])}) [] (TFn int int)))
  let capture=T.CodeContract T.ClosureCode ([0],[]) [(sc q,linShapeT [] q)] [q] q
  check "captures instantiate with the ordinary interface" (checkInstance capture [sc int] (TFn int int)==Right ())
  check "captures cannot disagree with the interface" (failed (checkInstance capture [sc bool] (TFn int int)))
  check "caller IDs cannot become the contract flexible variables"
    (failed (checkInstance capture [sc q] (TFn int int)))
  let a=Forall [1,2] [] (TFn (TV 2) (TV 1))
      b=Forall [8,9] [] (TFn (TV 8) (TV 9))
      poly=contract {T.contractCaptures=[(a,linShapeT [] (TFn (TV 2) (TV 1)))]}
  check "capture forall alpha-equivalence uses occurrences" (checkInstance poly [b] (TFn int int)==Right ())
  check "polymorphic capture cannot be weakened to an instance" (failed (checkInstance poly [sc (TFn int bool)] (TFn int int)))
  let escape=contract {T.contractCaptures=[(Forall [1] [] (TFn q (TV 1)),linShapeT [] (TFn q (TV 1)))],
                       T.contractParameters=[int],T.contractResult=int}
  check "a private capture skolem cannot escape into the code quantifiers"
    (failed (checkInstance escape [Forall [2] [] (TFn (TV 2) (TV 2))] (TFn int int)))
  let row=TRec (RExt "value" q (RV 3))
      rows=contract {T.contractQuantifiers=([0],[3]),T.contractParameters=[row],T.contractResult=q}
      actual=TRec (RExt "extra" bool (RExt "value" int RNil))
  check "row and type quantifiers instantiate together" (checkInstance rows [] (TFn actual int)==Right ())
  check "row interface result still agrees" (failed (checkInstance rows [] (TFn actual bool)))
  let global=expr q (T.Var (T.Global "ambient" (sc q)))
      parameter=binder 0 "x" (sc q)
      target=T.CodeFunction code T.ClosureCode [] [parameter] global
      dependent=T.CodeId "dependent"
      wrapper=T.CodeFunction dependent T.ClosureCode [] [] (expr (TFn q q) (T.ClosureValue code []))
      rigid=codeContracts M.empty (M.fromList [(code,target),(dependent,wrapper)])
  check "ambient global variables remain rigid" (T.contractQuantifiers (rigid M.! code)==([],[]))
  check "ambient rigidity propagates across code references" (T.contractQuantifiers (rigid M.! dependent)==([],[]))
  let importedRigid=codeContractsWith (M.singleton code (rigid M.! code)) M.empty (M.singleton dependent wrapper)
  check "ambient rigidity propagates through an imported code declaration"
    (T.contractQuantifiers (importedRigid M.! dependent)==([],[])
      && failed (checkInstance (importedRigid M.! dependent) [] (TFn int int)))
  let polymorphic=codeContracts (M.singleton "ambient" (Forall [0] [] q)) (M.singleton code target)
  check "the authoritative global schema owns rigidity" (T.contractQuantifiers (polymorphic M.! code)==([0],[]))
  let identity=expr (TFn q q) (T.Lambda [parameter] (ref parameter q))
      idBinder=binder 1 "id" (Forall [0] [] (TFn q q))
      alias=binder 2 "alias" (Forall [0] [] (TFn q q))
      apply ty value=expr ty (T.Apply (ref alias (TFn ty ty)) value)
      answer=expr (TTupT [int,bool,TFn q q]) (T.TupleValue
        [apply int (expr int (T.IntValue 7)),apply bool (expr bool (T.BoolValue True)),ref idBinder (TFn q q)])
      source=T.Function "polymorphic-alias" []
        (expr (T.exprType answer) (T.Let idBinder identity
          (expr (T.exprType answer) (T.Let alias (ref idBinder (TFn q q)) answer))))
      closed=close source
      resolved=right (resolveCalls types closed)
      labels=calls (T.functionBody (closedRoot resolved))
  check "typed alias calls reach the same original code" (length labels==2 && all (==head labels) labels && M.size (closedCode resolved)==1)
  check "the escaped original closure still exists" (M.keys (closedCode closed)==M.keys (closedCode resolved))
  check "the complete transformed closed graph verifies" (verifyClosed types resolved==Right ())
  let rankTwo f=Right f {T.codeParameters=[b {T.binderScheme=Forall [0] [] (T.binderType b)} | b<-T.codeParameters f]}
  check "ordinary parameters cannot pretend a capture forall is an arrow argument"
    (failed (mapClosed types Right rankTwo closed))
  let bad f=Right f {T.functionBody=expr int (T.CodeCall code [] [expr bool (T.BoolValue True)])}
  check "a checked closed transformer cannot publish an unknown code target" (failed (mapClosed types bad Right closed))
  let contracts=M.singleton code contract
      direct ty value result=T.Function "direct" [] (expr result (T.CodeCall code [] [expr ty value]))
  check "direct calls consume the checked contract" (verifyFunctionWith contracts types (direct int (T.IntValue 1) int)==Right ())
  check "direct call result mismatch is refused" (failed (verifyFunctionWith contracts types (direct int (T.IntValue 1) bool)))
  check "direct closure calls cannot target join code" (failed (verifyFunctionWith (M.singleton code (contract {T.contractKind=T.JoinCode})) types (direct int (T.IntValue 1) int)))
  check "direct calls cannot omit ordinary arguments" (failed (verifyFunctionWith contracts types (T.Function "empty" [] (expr (TFn int int) (T.CodeCall code [] [])))))
  let ownedTypes=T.TypeContext ["Int"] M.empty
      token=int
      ownedExpr ty node=T.Expr ty (linShapeT ["Int"] ty) T.Generated Nothing node
      owner=(binder 40 "owner" (sc token)) {T.binderShape=linShapeT ["Int"] token}
      unit=binder 41 "unit" (sc bool)
      callable=binder 42 "callable" (sc (TFn bool token))
      ownerValue=ownedExpr token (T.Var (T.Local (T.binderId owner)))
      lambda=ownedExpr (TFn bool token) (T.Lambda [unit] ownerValue)
      invocation=ownedExpr token (T.Apply (ref callable (TFn bool token)) (expr bool (T.BoolValue True)))
      owned=T.Function "owned-capture" [owner] (ownedExpr token (T.Let callable lambda invocation))
      ownedClosed=right (evalState (closeFunction (Namespace "owned-call") fresh ownedTypes owned) 0)
      ownedResolved=right (resolveCalls ownedTypes ownedClosed)
  check "the context's ownership shape overrides a familiar scalar spelling"
    (null (calls (T.functionBody (closedRoot ownedResolved))) && verifyClosed ownedTypes ownedResolved==Right ())
  source<-readFile "tests/typed_core/calls.fpr"
  let tops=right (either (Left . errorBundlePretty) Right (parse program "typed-calls" source))
      sigs=sigTable tops
      (errors,expanded)=expandStructs sigs tops
      checked=inferTopsChecked (Namespace "calls-source") aotProf sigs (structTable tops) expanded
      plans=right (prepareChecked checked)
      elaborated=erasePSig (inferenceTops checked)
      initial=DEnv 0 (collectCons "calls-source" elaborated) (collectShapes elaborated) [] []
      lowered=evalState (compileTopChecked plans elaborated) initial
      products=desugaredClosed lowered
      actualCalls product=calls (T.functionBody (closedRoot product))++concatMap (calls . T.codeBody) (M.elems (closedCode product))
  check ("source checking: "++show (errors,inferenceErrors checked)) (null errors && null (inferenceErrors checked))
  check "the native fixture stays in checked Core" (checkedNames plans==S.fromList [n | TBind n _ _ _<-elaborated])
  check "the real source producer resolves closure calls before erasure"
    (all (not . null . actualCalls . (products M.!)) ["poly","identity","escape","effect","shadow"])
  check "a callable capture needs its environment ownership evidence" (null (actualCalls (products M.! "captured")))
  check "stored partial applications retain their evaluated value" (null (actualCalls (products M.! "partial")))
  check "source closed products verify" (all ((==Right ()) . verifyClosed (desugaredTypeContext lowered)) (M.elems products))
  putStrLn "Typed calls: shared polymorphic code identity, capture/row instantiation, rigid ambient variables, lexical alias resolution and malformed-call refusals passed"
