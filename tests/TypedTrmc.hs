-- Mutation authority is fresh-cell provenance, not the payload's LShape.
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Trmc
import Core.Typed.Callback.Catalog
import Data.List (isInfixOf)
import Core.Typed.Verify
import Core.Typed.TrmcProof
import Core.Typed.Contract (codeContracts)
import Core.Typed.Erase
import Core.Identity
import Type.Syntax
import Ownership.Shape (LShape(..))
import qualified Core.Syntax as C
import qualified Data.Map.Strict as M
import Control.Monad (unless)
import Control.Monad.State.Strict

check name ok=unless ok (error name)
failed (Left _)=True
failed _=False
right=either error id
list=TAp (TC "List") (TC "Int")
b n ty=Binder (BinderId (Namespace "trmc-test") n) ("v"++show n) (Forall [] [] ty) LU
e ty node=Expr ty LU Generated Nothing node
ref x=e (binderType x) (Var (Local (binderId x)))
nil=e list (Construct "Nil" [])
cell=e list (Construct "Cons" [e (TC "Int") (IntValue 7),nil])
bind x a body=e (exprType body) (Let x a body)
key=CodeId "$worker.trmc.test"
x=b 0 list
root=b 1 list
cursor=b 2 list
next=b 3 list
unit=b 4 (TC "Unit")
store index a v=e (TC "Unit") (SetField a index v)
call args=e list (CodeCall key [] args)
marker body=e list (ListBuilder (binderId root) (binderId cursor) body)
worker body=CodeFunction key EntryCode [] [x,root,cursor] (marker body)
step=bind next cell (bind unit (store 1 (ref cursor) (ref next)) (call [ref x,ref root,ref next]))
entryCell=b 5 list
entry=Function "entry" [b 6 list] (bind entryCell cell (call [nil,ref entryCell,ref entryCell]))
constructors=M.fromList [("Nil",Forall [0] [] (TAp (TC "List") (TV 0))),
  ("Cons",Forall [0] [] (TFn (TV 0) (TFn (TAp (TC "List") (TV 0)) (TAp (TC "List") (TV 0)))))]
types=TypeContext [] constructors

main=do
  passChecks
  let code=worker step
      codes=M.singleton key code
      contracts=codeContracts M.empty codes
      valid body=verifyFunctionWith contracts types (codeAsFunction (worker body))
  check "unrestricted payload can have fresh-cell authority" (binderShape cursor==LU && valid step==Right ())
  check "private fresh-cell start verifies" (verifyBuilderGraph entry codes==Right ())
  check "malformed marker is refused before checking callers" (failed (verifyBuilderGraph entry
    (M.singleton key (code {codeBody=e list (ListBuilder (binderId (b 99 list)) (binderId cursor) step)}))))
  check "shared input cannot start builder" (failed (verifyBuilderGraph
    (entry {functionBody=call [nil,ref (b 6 list),ref (b 6 list)]}) codes))
  check "two different cells cannot start builder" (failed (verifyBuilderGraph
    (entry {functionBody=bind entryCell cell (call [nil,ref entryCell,nil])}) codes))
  check "cursor cannot escape to callback" (failed (valid (bind (b 7 list) (ref cursor) step)))
  check "root cannot escape through another argument" (failed (valid (call [ref root,ref root,ref cursor])))
  check "nested self call cannot grant authority over a shared cell" (failed (verifyBuilderGraph entry
    (M.singleton key (worker (bind (b 7 list) (call [ref x,ref x,ref x]) step)))))
  check "cursor cannot be returned" (failed (valid (ref cursor)))
  check "wrong field cannot be stored" (failed (valid
    (bind unit (store 0 (ref cursor) nil) (ref root))))
  check "shared argument cannot become next cursor" (failed (valid
    (bind unit (store 1 (ref cursor) (ref x)) (call [ref x,ref root,ref x]))))
  check "store cannot be used outside protocol" (failed (verifyFunction types
    (Function "bad" [cursor] (store 1 (ref cursor) nil))))
  check "builder cannot become source entry" (failed (verifyBuilderGraph (codeAsFunction code) codes))
  check "builder cannot escape as closure" (failed (verifyBuilderGraph
    (entry {functionBody=e (TFn list (TFn list (TFn list list))) (ClosureValue key [])}) codes))
  let fresh _=do n<-get;put (n+1);pure ("erase"++show (n::Int))
      layout=Layout fresh (\n->case n of "Cons"->Just (2,1,2);"Nil"->Just (2,0,0);_->Nothing) M.empty (\_ _ _->pure ())
      erased=right (evalState (eraseFunctionWith contracts types layout (codeAsFunction code)) 0)
      hasStore expr=case expr of
        C.CApp (C.CApp (C.CVar "$trmc.setTail") _) _->True
        C.CLet _ a z->hasStore a || hasStore z
        _->False
  check "verified builder erases to backend store" (hasStore (snd erased))
  putStrLn "typed TRMC freshness, escape, field and erasure checks PASS"

-- Exercise the pass itself against a checked helper catalog, independently of
-- the source/compiler driver and without granting authority by function name.
passChecks=do
  let freshName _=do n<-get;put (n+1);pure ("closed"++show (n::Int))
      close fn=right (evalState (closeFunction (Namespace "pass") freshName types fn) 0)
      xs=b 10 list;acc=b 11 list;hd=b 12 (TC "Int");tl=b 13 list
      mx=b 20 list;ma=b 21 list;mh=b 22 (TC "Int");mt=b 23 list
      invoke name args=foldl (\f a->case exprType f of TFn _ ty->e ty (Apply f a);_->error "test arrow") head' args
        where ty=foldr (TFn . exprType) list args
              head'=e ty (Var (Global name (Forall [] [] ty)))
      cases input h t no yes=e list (MatchTail CaseMatch [ref input]
        [Alternative [Pattern list "Nil" (ConstructorPattern "Nil" [])] [] no,
         Alternative [Pattern list "Cons" (ConstructorPattern "Cons"
           [Pattern (TC "Int") "head" (Bind h),Pattern list "tail" (Bind t)])] [] yes]
        (e list (Fail "no match")))
      cons' h a=e list (Construct "Cons" [ref h,ref a])
      reverseFn=Function "revOnto" [xs,acc] (cases xs hd tl (ref acc)
        (invoke "revOnto" [ref tl,cons' hd acc]))
      copyFn=Function "copy" [mx,ma] (cases mx mh mt (invoke "revOnto" [ref ma,nil])
        (invoke "copy" [ref mt,cons' mh ma]))
      before=close copyFn
      snapshot=right (catalog types (M.fromList [("revOnto",close reverseFn),("copy",before)]))
      (after,loops,_,changed)=right (trmcClosed (Namespace "pass") types (planTrmc snapshot) before)
  check "typed pass creates and calls a verified worker" (changed && loops==1 && not (M.null (closedCode after))
    && "$worker.trmc." `isInfixOf` show (functionBody (closedRoot after)) && verifyClosed types after==Right ())
  let escaped=close (copyFn {functionBody=e list (Sequence (ref ma) (functionBody copyFn))})
      (_,declined,_,didChange)=right (trmcClosed (Namespace "pass") types (planTrmc snapshot) escaped)
  check "typed pass refuses an observed accumulator" (declined==0 && not didChange)
  let receiverArg=b 30 list
      receiver=close (Function "recvHelper" [receiverArg] (invoke "receive" [ref receiverArg]))
      receiving=close (copyFn {functionBody=e list (Sequence (invoke "recvHelper" [ref mx]) (functionBody copyFn))})
      receiveSnapshot=right (catalog types (M.fromList [("revOnto",close reverseFn),("copy",receiving),("recvHelper",receiver)]))
      (_,receiveLoops,_,receiveChanged)=right (trmcClosed (Namespace "pass") types (planTrmc receiveSnapshot) receiving)
  check "typed pass leaves indirectly receiving loops to region planning" (receiveLoops==0 && not receiveChanged)
  let fake=close (reverseFn {functionBody=ref xs})
      fakeSnapshot=right (catalog types (M.fromList [("revOnto",fake),("copy",before)]))
      (_,fakeLoops,_,fakeChanged)=right (trmcClosed (Namespace "pass") types (planTrmc fakeSnapshot) before)
  check "reverse spelling alone is not semantic evidence" (fakeLoops==0 && not fakeChanged)
