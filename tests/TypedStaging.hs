import Core.Identity
import qualified Core.Typed.Syntax as T
import Core.Typed.Close
import Core.Typed.Stage
import Core.Typed.Erase
import Core.Typed.Walk (allBinders,mapChildrenM)
import Core.Typed.Verify
import Core.Syntax
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import Frontend.Desugar (DEnv(..),fresh)
import qualified Codegen.Lower as Lower
import qualified Codegen.Eval as Eval
import Codegen.Policy (m2Policy)
import Mono (specializeFunctions)
import Inline (inlineCompatibilityWithImports)
import Control.Monad (unless)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Functor.Const (Const(..))
import Data.Monoid (Sum(..))

check name ok=unless ok (error name)
right=either error id
failed (Left _)=True
failed _=False
int=TC "Int"
fnTy=TFn int (TFn int int)
types=T.TypeContext [] M.empty
expr ty node=T.Expr ty (linShapeT [] ty) T.Generated Nothing node
binder ns n name ty=T.Binder (BinderId (Namespace ns) n) name (Forall [] [] ty) (linShapeT [] ty)
ref b=expr (T.binderType b) (T.Var (T.Local (T.binderId b)))
apply f a=case T.exprType f of TFn _ result->expr result (T.Apply f a);_->error "test arrow"
initial=DEnv 0 M.empty M.empty [] []
close f=right (evalState (closeFunction (Namespace "staging-tests") fresh types f) initial)
stage globals=right . stageCalls (Namespace "test-stage") types globals
erased closed=evalState (do
  let layout=Layout fresh (const Nothing) M.empty (\_ _ _->pure ())
      erase f=eraseFunctionWith (closedContracts closed) types layout f >>= either error pure
  root<-erase (closedRoot closed)
  codes<-mapM (\code->do value<-erase (T.codeAsFunction code);let T.CodeId name=T.codeId code in pure (name,value)) (M.elems (closedCode closed))
  pure (M.insert (T.functionName (closedRoot closed)) root (M.fromList codes))) initial
answer prog name args=let (ir,_)=Lower.lowerProgram m2Policy M.empty prog prog M.empty M.empty
                     in Eval.ocResult (Eval.evalProgram ir name args)
optimized=inlineCompatibilityWithImports S.empty M.empty (const False) 3 24 . specializeFunctions "staging-test" M.empty M.empty
occurrences :: BinderId -> T.Expr -> Int
occurrences uid e=(case T.exprNode e of T.Var (T.Local used) | uid==used->1;_->0)
  +getSum (getConst (mapChildrenM (Const . Sum . occurrences uid) e))

main=do
  let x=binder "input" 0 "x" int
      f=binder "input" 1 "f" fnTy
      lambda=expr fnTy (T.Lambda [x] (expr (TFn int int) (T.Fail "body")))
      call=apply (apply (ref f) (expr int (T.IntValue 1))) (expr int (T.Fail "argument"))
      reserved=binder "test-stage/staging/known/root" 0 "$typed_stage_0" int
      known=close (T.Function "known" [reserved] (expr int (T.Let f lambda call)))
      staged=stage M.empty known
      closed=stagedClosed staged
  check "the staged closed product verifies" (verifyStagedCalls types staged==Right ())
  check "a known physical call saturates before evaluating an argument of its result"
    (answer (erased closed) "known" [Eval.RInt 0]==Left (Eval.Trap "body"))
  check "saved lowering reproduces the unstaged overapplication priority"
    (answer (erased known) "known" [Eval.RInt 0]==Left (Eval.Trap "argument"))
  check "staging does not clone code identities" (M.keys (closedCode known)==M.keys (closedCode closed))
  let beforeIds=S.fromList [T.binderId b | fun<-closedRoot known:map T.codeAsFunction (M.elems (closedCode known)),b<-T.functionParameters fun++allBinders (T.functionBody fun)]
      afterIds=[T.binderId b | fun<-closedRoot closed:map T.codeAsFunction (M.elems (closedCode closed)),b<-T.functionParameters fun++allBinders (T.functionBody fun)]
  check "new identities avoid existing generated namespaces" (beforeIds `S.isSubsetOf` S.fromList afterIds && length afterIds==S.size (S.fromList afterIds))
  let showClosed c=show (closedRoot c,closedCode c)
  check "staging is idempotent" (showClosed closed==showClosed (stagedClosed (stage M.empty closed)))
  check "unreferenced calling metadata cannot perturb local fresh names"
    (showClosed closed==showClosed (stagedClosed (stage (M.singleton "$typed_stage_1" 9) known)))
  check "negative calling arity is refused" (failed (stageCalls (Namespace "bad") types (M.singleton "bad" (-1)) known))
  let emptyLambda=T.Function "empty" [] (expr fnTy (T.Lambda [] (expr fnTy (T.Fail "empty"))))
  check "a zero-parameter computation is not published as an immutable callable value"
    (failed (evalState (closeFunction (Namespace "empty") fresh types emptyLambda) initial))
  let callback=binder "unknown" 0 "callback" fnTy
      unknown=close (T.Function "unknown" [callback]
        (apply (apply (ref callback) (expr int (T.IntValue 1))) (expr int (T.Fail "argument"))))
      unknownStaged=stagedClosed (stage M.empty unknown)
      [target]=M.keys (closedCode known)
      T.CodeId targetName=target
      client=CApp (CVar "unknown") (CVar targetName)
      program=M.insert "client" ([],client) (M.union (erased unknownStaged) (erased known))
      unstaged=M.insert "client" ([],client) (M.union (erased unknown) (erased known))
  check "unknown call operands precede invocation" (answer program "client" []==Left (Eval.Trap "argument"))
  check "later callback specialization/inlining cannot move an operand after the callback"
    (answer (optimized program) "client" []==Left (Eval.Trap "argument"))
  check "the unstaged optimizer reproduces the callback priority bug"
    (answer (optimized unstaged) "client" []==Left (Eval.Trap "body"))
  let global n ty=expr ty (T.Var (T.Global n (Forall [] [] ty)))
      caf=close (T.Function "caf-client" [] (apply (apply (global "factory" fnTy) (expr int (T.IntValue 1))) (expr int (T.Fail "argument"))))
      cafStage=stage (M.singleton "factory" 0) caf
      cafBody=T.functionBody (closedRoot (stagedClosed cafStage))
  check "logical arrows do not turn a CAF into a two-parameter entry" (case T.exprNode cafBody of
    T.Let _ value _->case T.exprNode value of T.Var (T.Global "factory" _)->True;_->False
    _->False)
  let opaque=close (T.Function "opaque-client" [] (apply (apply (global "opaque" fnTy) (expr int (T.IntValue 1))) (expr int (T.Fail "argument"))))
      opaqueBody=T.functionBody (closedRoot (stagedClosed (stage M.empty opaque)))
  check "foreign logical signatures do not invent runtime physical arities" (case T.exprNode opaqueBody of T.Apply {}->True;_->False)
  let partial=binder "partial" 0 "partial" fnTy
      y=binder "partial" 1 "y" int
      pairFn=binder "partial" 2 "pairFn" (TFn int fnTy)
      pairLambda=expr (TFn int fnTy) (T.Lambda [x,y] (expr (TFn int int) (T.Fail "body")))
      initializer=apply (ref pairFn) (global "firstArg" int)
      partialCall=apply (apply (ref partial) (expr int (T.IntValue 2))) (expr int (T.Fail "argument"))
      saved=expr int (T.Let pairFn pairLambda (expr int (T.Let partial initializer partialCall)))
      partialClosed=close (T.Function "partial" [] saved)
      partialStaged=stagedClosed (stage M.empty partialClosed)
      partialProgram=M.insert "firstArg" ([],CInt 1) (erased partialStaged)
      (partialIR,_)=Lower.lowerProgram m2Policy M.empty partialProgram partialProgram M.empty M.empty
      partialAnswer=Eval.evalProgram partialIR "partial" []
  check "stored partial arguments are not copied or reevaluated"
    (Eval.ocResult partialAnswer==Left (Eval.Trap "body")
      && length [() | Eval.EvCall "firstArg" _<-Eval.ocEvents partialAnswer]==1)
  let nested=binder "captured" 0 "nested" (TFn int int)
      unit=binder "captured" 1 "unit" int
      nestedCall=apply (apply (apply (ref pairFn) (expr int (T.IntValue 1))) (expr int (T.IntValue 2))) (expr int (T.Fail "argument"))
      nestedLambda=expr (TFn int int) (T.Lambda [unit] nestedCall)
      capturedSource=T.Function "captured-source" []
        (expr int (T.Let pairFn pairLambda (expr int (T.Let nested nestedLambda (apply (ref nested) (expr int (T.IntValue 0)))))))
      sourceStage=right (stageFunction (Namespace "source-stage") types M.empty capturedSource)
      stagedBeforeClose=close (stagedFunction sourceStage)
      stagedAfterClose=stagedClosed (stage M.empty (close capturedSource))
  check "lexical arity evidence must reach nested lambdas before capture renaming"
    (verifyStagedFunction types sourceStage==Right ()
      && answer (erased stagedBeforeClose) "captured-source" []==Left (Eval.Trap "body")
      && answer (erased stagedAfterClose) "captured-source" []==Left (Eval.Trap "argument"))
  check "a source-stage product cannot borrow a closed graph's code registry"
    (failed (stageFunction (Namespace "wrong-phase") types M.empty (closedRoot known)))
  let recursive=binder "recursive" 0 "loop" fnTy
      selfBody=expr (TFn int int) (T.If (expr (TC "Bool") (T.BoolValue True))
        (expr (TFn int int) (T.Fail "body")) (apply (ref recursive) (expr int (T.IntValue 0))))
      rhs=expr fnTy (T.Lambda [x] selfBody)
      recursiveCall=apply (apply (ref recursive) (expr int (T.IntValue 1))) (expr int (T.Fail "argument"))
      recursiveSource=T.Function "recursive-source" [] (expr int (T.LetRec recursive rhs recursiveCall))
      recursiveStage=right (stageFunction (Namespace "recursive-stage") types M.empty recursiveSource)
  check "recursive initializer and continuation share the declared saturation boundary"
    (answer (erased (close (stagedFunction recursiveStage))) "recursive-source" []==Left (Eval.Trap "body"))
  let ownedTypes=T.TypeContext ["Token"] M.empty
      token=TC "Token"
      owner=(binder "owned" 0 "owner" token) {T.binderShape=linShapeT ["Token"] token}
      ownedFn=binder "owned" 1 "consume" (TFn token (TFn int int))
      ownedRef=expr token (T.Var (T.Local (T.binderId owner)))
      ownedBody=apply (apply (ref ownedFn) (ownedRef {T.exprShape=linShapeT ["Token"] token})) (expr int (T.Fail "argument"))
      owned=right (evalState (closeFunction (Namespace "owned") fresh ownedTypes (T.Function "owned" [owner,ownedFn] ownedBody)) initial)
      ownedStage=right (stageCalls (Namespace "owned-stage") ownedTypes M.empty owned)
  check "operand snapshots transfer an owned value without duplicating its identity"
    (occurrences (T.binderId owner) (T.functionBody (closedRoot (stagedClosed ownedStage)))==1 && verifyStagedCalls ownedTypes ownedStage==Right ())
  putStrLn "Typed staging: saturation/trap priorities, unknown operand snapshots across Mono/inlining, CAF arities, code identity, hygienic binders, idempotence and ownership transfers passed"
