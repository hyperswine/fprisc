import Core.Identity
import qualified Core.Typed.Syntax as T
import Core.Typed.Close
import Core.Typed.Stage
import Core.Typed.Callback
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
types=T.TypeContext [] M.empty
expr ty node=T.Expr ty (linShapeT [] ty) T.Generated Nothing node
binder ns n name ty=T.Binder (BinderId (Namespace ns) n) name (Forall [] [] ty) (linShapeT [] ty)
ref b=expr (T.binderType b) (T.Var (T.Local (T.binderId b)))
apply f a=case T.exprType f of TFn _ result->expr result (T.Apply f a);_->error "test arrow"
initial=DEnv 0 M.empty M.empty [] []
close f=right (evalState (closeFunction (Namespace "callback-tests") fresh types f) initial)
erased closed=evalState (do
  let layout=Layout fresh (\n->if n=="Tup2" then Just (2,0,2) else Nothing) M.empty (\_ _ _->pure ())
      erase f=eraseFunctionWith (closedContracts closed) types layout f >>= either error pure
  root<-erase (closedRoot closed)
  codes<-mapM (\code->do value<-erase (T.codeAsFunction code);let T.CodeId name=T.codeId code in pure (name,value)) (M.elems (closedCode closed))
  pure (M.insert (T.functionName (closedRoot closed)) root (M.fromList codes))) initial
answer prog name args=let (ir,_)=Lower.lowerProgram m2Policy M.empty prog prog M.empty M.empty
                     in Eval.ocResult (Eval.evalProgram ir name args)

main=do
  let q=TV 0
      x=binder "cb" 0 "x" q
      f=binder "cb" 1 "f" (TFn q q)
      a=binder "cb" 2 "apply" (TFn (TFn q q) (TFn q q))
      ident=binder "cb" 3 "ident" (TFn q q)
      idArg=binder "cb" 4 "idArg" q
      idValue=expr (TFn q q) (T.Lambda [idArg] (ref idArg))
      helper=expr (T.binderType a) (T.Lambda [f,x] (apply (ref f) (ref x)))
      monoRef b ty=expr ty (T.Var (T.Local (T.binderId b)))
      invoke ty arg=apply (apply (monoRef a (TFn (TFn ty ty) (TFn ty ty))) (monoRef ident (TFn ty ty))) arg
      pair=expr (TTupT [int,TC "Bool"]) (T.TupleValue [invoke int (expr int (T.IntValue 7)),invoke (TC "Bool") (expr (TC "Bool") (T.BoolValue True))])
      aPoly=a {T.binderScheme=Forall [0] [] (T.binderType a)}
      idPoly=ident {T.binderScheme=Forall [0] [] (T.binderType ident)}
      source=T.Function "callbacks" [] (expr (T.exprType pair) (T.Let idPoly idValue (expr (T.exprType pair) (T.Let aPoly helper pair))))
      closed=close source
      result=right (specializeCallbacks SpecializeCallbacks (Namespace "test") types M.empty closed)
      output=callbackClosed result
  check "one generic clone is shared by Int and Bool" (S.size (callbackClones result)==1)
  check "checked clone graph verifies" (verifyClosed types output==Right ())
  check "callback calls preserve independent evaluation" (answer (erased output) "callbacks" []==Right (Eval.RObj 2 0 [Eval.RInt 7,Eval.RObj 1 1 []])
     && answer (erased closed) "callbacks" []==Right (Eval.RObj 2 0 [Eval.RInt 7,Eval.RObj 1 1 []]))
  check "callback object removed when used only for invocation" (all ((==1) . length . T.codeParameters) (M.elems (M.restrictKeys (closedCode output) (callbackClones result))))
  check "original nested code identities survive" (M.keysSet (closedCode closed) `S.isSubsetOf` M.keysSet (closedCode output))
  let untouched=callbackClosed (right (specializeCallbacks PreserveCallbacks (Namespace "test") types M.empty closed))
  check "disabled mode preserves the exact graph" (show (closedRoot untouched,closedCode untouched)==show (closedRoot closed,closedCode closed))
  let eq ty=let interface=TFn ty (TFn ty (TC "Bool"))
            in expr interface (T.Var (T.Global "==" (Forall [] [] interface)))
      eqCall ty=let value=monoRef ident ty in apply (apply (eq ty) value) value
      equalities=expr (TTupT [TC "Bool",TC "Bool"]) (T.TupleValue [eqCall (TFn int int),eqCall (TFn (TC "Bool") (TC "Bool"))])
      equalitySource=T.Function "equality" [] (expr (T.exprType equalities) (T.Let idPoly idValue equalities))
      equality=right (specializeCallbacks SpecializeCallbacks (Namespace "test") types (M.singleton "==" 2) (close equalitySource))
  check "primitive schemas remain valid at differently typed occurrences"
    (verifyClosed types (callbackClosed equality)==Right ())
  let run=right . specializeCallbacks SpecializeCallbacks (Namespace "test") types M.empty . close
      callbackTy=TFn int int
      callback=binder "nullary" 0 "callback" callbackTy
      callbackArg=binder "nullary" 1 "arg" int
      helperArg=binder "nullary" 2 "f" callbackTy
      helperBinder=binder "nullary" 3 "helper" (TFn callbackTy int)
      callbackValue=expr callbackTy (T.Lambda [callbackArg] (ref callbackArg))
      helperValue=expr (TFn callbackTy int) (T.Lambda [helperArg] (apply (ref helperArg) (expr int (T.IntValue 11))))
      nullaryBody=expr int (T.Let callback callbackValue (expr int (T.Let helperBinder helperValue (apply (ref helperBinder) (ref callback)))))
      nullary=run (T.Function "nullary" [] nullaryBody)
      [entry]=M.elems (M.restrictKeys (closedCode (callbackClosed nullary)) (callbackClones nullary))
  check "an invocation-only callback can produce a nullary computation entry"
    (T.codeKind entry==T.EntryCode && null (T.codeCaptures entry++T.codeParameters entry)
      && answer (erased (callbackClosed nullary)) "nullary" []==Right (Eval.RInt 11))
  check "a nullary computation cannot escape as a callable value"
    (failed (rewriteClosed types (\root codes->Right (root {T.functionBody=expr callbackTy (T.ClosureValue (T.codeId entry) [])},codes)) (callbackClosed nullary)))
  let unknown=binder "unknown" 0 "unknown" callbackTy
      local=binder "unknown" 1 "local" callbackTy
      localArg=binder "unknown" 2 "x" int
      localValue=expr callbackTy (T.Lambda [localArg] (apply (ref unknown) (ref localArg)))
      uncertain=T.Function "uncertain" [unknown] (expr int (T.Let local localValue
        (expr int (T.Let helperBinder helperValue (apply (ref helperBinder) (ref local))))))
  check "an arrow type does not prove the callback environment unrestricted"
    (S.null (callbackClones (run uncertain)))
  let opaqueBody=expr int (T.Let local localValue nullaryBody)
      opaque=run (T.Function "opaque" [unknown] opaqueBody)
  check "unused closures without capture ownership proof remain in the graph"
    (T.binderId local `elem` map T.binderId (allBinders (T.functionBody (closedRoot (callbackClosed opaque)))))
  let seed=binder "wide" 0 "seed" int
      cb=binder "wide" 1 "cb" callbackTy
      cbArg=binder "wide" 2 "x" int
      selected=binder "wide" 3 "selected" callbackTy
      ordinary=[binder "wide" i ("p"++show i) int | i<-[4..66]]
      params=selected:ordinary
      helperType result=foldr (TFn . T.binderType) result params
      worker result=binder "wide" 67 "worker" (helperType result)
      call w=foldl apply (ref w) (ref cb:replicate 63 (expr int (T.IntValue 1)))
      wide retain=let result=if retain then callbackTy else int
                      invocation=apply (ref selected) (ref (head ordinary))
                      body=if retain then expr callbackTy (T.Sequence invocation (ref selected)) else invocation
                      w=worker result
                  in T.Function (if retain then "overflow" else "maximum") [seed]
                    (expr result (T.Let cb (expr callbackTy (T.Lambda [cbArg] (ref seed)))
                      (expr result (T.Let w (expr (helperType result) (T.Lambda params body)) (call w)))))
      maximum=run (wide False)
      overflow=run (wide True)
  check "projected 64-argument entries are allowed before provisional fields are trimmed"
    (S.size (callbackClones maximum)==1 && all ((==64) . (\f->length (T.codeCaptures f++T.codeParameters f)))
      (M.elems (M.restrictKeys (closedCode (callbackClosed maximum)) (callbackClones maximum)))
      && answer (erased (callbackClosed maximum)) "maximum" [Eval.RInt 5]==Right (Eval.RInt 5))
  check "an escaping callback that exceeds 64 fields restores the original call"
    (S.null (callbackClones overflow) && verifyClosed types (callbackClosed overflow)==Right ()
      && answer (erased (callbackClosed overflow)) "overflow" [Eval.RInt 5]
          ==answer (erased (close (wide True))) "overflow" [Eval.RInt 5])
  let comb=binder "pattern" 0 "comb" (TFn int (TFn int int))
      prefix=binder "pattern" 1 "prefix" int
      item=binder "pattern" 2 "item" int
      saved=binder "pattern" 3 "saved" (TFn int int)
      probe=expr int (T.Var (T.Global "probe" (Forall [] [] int)))
      combine=expr (T.binderType comb) (T.Lambda [prefix,item] (ref item))
      body=expr (TTupT [int,int]) (T.TupleValue [apply (ref saved) (expr int (T.IntValue 1)),apply (ref saved) (expr int (T.IntValue 2))])
      patternBody=expr (T.exprType body) (T.Let comb combine
        (expr (T.exprType body) (T.LetPattern (T.Pattern (T.binderType saved) "saved" (T.Bind saved)) (apply (ref comb) probe) body)))
      patternInput=close (T.Function "pattern" [] patternBody)
      patternOutput=callbackClosed (right (specializeCallbacks SpecializeCallbacks (Namespace "test") types (M.singleton "probe" 0) patternInput))
      probeCalls closed=let program=M.insert "probe" ([],CInt 9) (erased closed)
                            (ir,_)=Lower.lowerProgram m2Policy M.empty program program M.empty M.empty
                        in length [() | Eval.EvCall "probe" _<-Eval.ocEvents (Eval.evalProgram ir "pattern" [])]
  check "pattern aliases do not replay the effects of a stored partial application"
    (probeCalls patternInput==1 && probeCalls patternOutput==1)
  let joinLabel=T.CodeId "original-join"
      joinArg=binder "join" 1 "joinCallback" callbackTy
      joinFn=T.CodeFunction joinLabel T.JoinCode [joinArg] [] (apply (ref joinArg) (expr int (T.IntValue 19)))
      base=close (T.Function "join" [] (expr int (T.Let callback callbackValue (expr int (T.IntValue 0)))))
      withJoin=right (rewriteClosed types (\root codes->case T.exprNode (T.functionBody root) of
        T.Let b value _->Right (root {T.functionBody=expr int (T.Let b value (expr int (T.JoinCall joinLabel [T.binderId b] [])))},M.insert joinLabel joinFn codes)
        _->Left "test join initializer") base)
      joined=right (specializeCallbacks SpecializeCallbacks (Namespace "test") types M.empty withJoin)
      [joinClone]=M.elems (M.restrictKeys (closedCode (callbackClosed joined)) (callbackClones joined))
  check "a callback-only continuation retains its join role and a nonnullary call"
    (T.codeKind joinClone==T.JoinCode && null (T.codeCaptures joinClone)
      && length (T.codeParameters joinClone)==1
      && answer (erased (callbackClosed joined)) "join" []==Right (Eval.RInt 19))
  check "a code entry cannot shadow the root label"
    (failed (rewriteClosed types (\root codes->Right (root,M.insert (T.CodeId (T.functionName root))
      (joinFn {T.codeId=T.CodeId (T.functionName root)}) codes)) base))
  let reservedNamespace=Namespace ("test/callbacks/"++show (T.CodeId "$typed.mono.nullary.0"))
      reserved=binder "unused" 0 "reserved" int
      conflicting=reserved {T.binderId=BinderId reservedNamespace 0}
      collision=run (T.Function "nullary" [conflicting] nullaryBody)
  check "cloned namespaces avoid existing term identities" (all (\(T.CodeId n)->n/="$typed.mono.nullary.0") (S.toList (callbackClones collision)))
  let allIds=[T.binderId b | fun<-closedRoot output:map T.codeAsFunction (M.elems (closedCode output)),
        b<-T.functionParameters fun++allBinders (T.functionBody fun)]
  check "all original and generated identities are unique" (length allIds==S.size (S.fromList allIds))
  check "negative physical arities are refused"
    (failed (specializeCallbacks SpecializeCallbacks (Namespace "test") types (M.singleton "bad" (-1)) closed))
  putStrLn "typed callback checks passed"
