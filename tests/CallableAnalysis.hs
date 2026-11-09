import Core.Typed.Callable
import Core.Typed.Callback.Model
import Core.Typed.Syntax
import Core.Identity
import Type.Syntax
import Ownership.Shape (LShape(..))
import Control.Monad (unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

check label ok=unless ok (error label)
int=TC "Int"
arrow=TFn int int
b n name ty=Binder (BinderId (Namespace "callable-tests") n) name (Forall [] [] ty) LU
e ty n=Expr ty LU Generated Nothing n
ref x=e (binderType x) (Var (Local (binderId x)))
global name ty=e ty (Var (Global name (Forall [] [] ty)))
apply f x=case exprType f of TFn _ result->e result (Apply f x);_->error "test application"
num n=e int (IntValue n)
root name ps body=(RootTarget name,template name EntryCode [] ps body)
code name cs ps body=(CodeTarget (CodeId name),template name ClosureCode cs ps body)
template name kind cs ps body=let fn=CodeFunction (CodeId name) kind cs ps body in Template cs ps body (codeContract fn) kind
run limits names defs=analyze limits (S.fromList (map RootTarget names)) (M.fromList defs)
result a name=summaryResult (analysisSummaries a M.! RootTarget name)
known v=S.map memberTarget (valueMembers v)
closed v=S.null (valueUnknowns v)
main=do
  let x=b 0 "x" int
      f=b 1 "f" arrow
      n=b 2 "n" int
      arg=b 3 "arg" int
      saved=b 4 "saved" arrow
      cap=b 5 "capture" int
      flag=b 6 "flag" (TC "Bool")
      ident=root "identity@one" [x] (ref x)
      other=root "identity@two" [x] (num 2)
      choice=root "choose" [flag] (e arrow (If (ref flag) (global "identity@one" arrow) (global "identity@two" arrow)))
      a=run defaultLimits ["choose"] [choice,ident,other]
  check "branches retain distinct qualified targets"
    (known (result a "choose")==S.fromList [RootTarget "identity@one",RootTarget "identity@two"] && closed (result a "choose"))
  check "escaping targets get open ordinary arguments" (all summaryReached (M.elems (analysisSummaries a)))
  let forward=root "forward" [f] (ref f)
      mainFn=root "entry" [] (apply (global "forward" (TFn arrow arrow)) (global "identity@one" arrow))
      returned=run defaultLimits ["entry"] [mainFn,forward,ident]
  check "arguments and return values compose" (known (result returned "entry")==S.singleton (RootTarget "identity@one") && closed (result returned "entry"))
  let two=root "two" [f,x] (ref f)
      partial=apply (global "two" (TFn arrow (TFn int arrow))) (global "identity@one" arrow)
      partialRoot=root "partial" [] partial
      pa=run defaultLimits ["partial"] [partialRoot,two,ident]
  check "partial application retains target and ordinary prefix" (valueMembers (result pa "partial")==S.singleton (Member (RootTarget "two") 1))
  check "PAP candidate site" (any ((==PartialApplication).siteKind) (analysisSites pa))
  let saturated=root "saturated" [] (apply partial (num 5))
      sat=run defaultLimits ["saturated"] [saturated,two,ident]
  check "saturation reads saved callable arguments" (known (result sat "saturated")==S.singleton (RootTarget "identity@one"))
  let captured=code "add-code" [cap] [arg] (ref cap)
      maker=root "make" [n] (e arrow (ClosureValue (CodeId "add-code") [binderId n]))
      makeRoot=root "made" [] (apply (global "make" (TFn int arrow)) (num 42))
      made=run defaultLimits ["made"] [captured,maker,makeRoot]
  check "returned closure code identity" (known (result made "made")==S.singleton (CodeTarget (CodeId "add-code")))
  check "capture schema preserved" (length (summaryCaptures (analysisSummaries made M.! CodeTarget (CodeId "add-code")))==1)
  let held=code "held-code" [saved] [arg] (ref saved)
      store=root "store" [f] (e (TFn int arrow) (ClosureValue (CodeId "held-code") [binderId f]))
      use=root "use" [] (apply (apply (global "store" (TFn arrow (TFn int arrow))) (global "identity@one" arrow)) (num 3))
      heldResult=run defaultLimits ["use"] [held,store,use,ident]
  check "function-valued captures propagate without assuming ownership" (known (result heldResult "use")==S.singleton (RootTarget "identity@one"))
  let open=run defaultLimits ["forward"] [forward]
  check "open root input is unknown, not an empty closed set" (not (closed (result open "forward")))
  let external=root "external" [] (apply (global "foreignFactory" (TFn int arrow)) (num 0))
      ext=run defaultLimits ["external"] [external]
  check "external callable source remains unknown" (not (closed (result ext "external")) && any ((==BoundaryApplication).siteKind) (analysisSites ext))
  let record=e (TRec (RExt "cb" arrow RNil)) (RecordValue [("cb",global "identity@one" arrow)])
      projection=root "projection" [] (e arrow (RecordField record ["cb"]))
      projected=run defaultLimits ["projection"] [projection,ident]
  check "closed record projection" (known (result projected "projection")==S.singleton (RootTarget "identity@one") && closed (result projected "projection"))
  let recursive=root "recursive" [flag] (e arrow (If (ref flag) (global "identity@one" arrow) (apply (global "recursive" (TFn (TC "Bool") arrow)) (ref flag))))
      rec=run defaultLimits ["recursive"] [recursive,ident]
  check "recursive return fixed point" (analysisStatus rec=="fixed-point" && known (result rec "recursive")==S.singleton (RootTarget "identity@one"))
  let cycle=root "cycle" [x] (apply (global "cycle" (TFn int arrow)) (ref x))
      cy=run defaultLimits ["cycle"] [cycle]
  check "unproductive cycle is not an empty closed family" (not (closed (result cy "cycle")))
  let limited=run (Limits 1 64 4) ["entry"] [mainFn,forward,ident]
  check "iteration budget poisons published evidence" (analysisStatus limited=="budget-limited" && not (closed (result limited "entry")))
  let wide=run (Limits 32 1 4) ["choose"] [choice,ident,other]
  check "truncated family is visibly unknown" (S.member "member-budget" (valueUnknowns (result wide "choose")))
  let modified=root "forward" [f] (global "identity@two" arrow)
      changed=run defaultLimits ["entry"] [mainFn,modified,ident,other]
  check "new snapshot does not reuse old callee evidence" (known (result changed "entry")==S.singleton (RootTarget "identity@two"))
  check "deterministic summaries" (show a==show (run defaultLimits ["choose"] [other,ident,choice]))
  let returner=root "returner" [x] (global "identity@one" arrow)
      select=root "select" [b 7 "cb" (TFn int arrow),x] (ref (b 7 "cb" (TFn int arrow)))
      over=root "over" [] (apply (apply (apply (global "select" (TFn (TFn int arrow) (TFn int (TFn int arrow))))
        (global "returner" (TFn int arrow))) (num 1)) (num 2))
      overResult=run defaultLimits ["over"] [over,select,returner,ident]
  check "over-application follows the returned callable" (known (result overResult "over")==S.singleton (RootTarget "identity@one"))
  let mixed=root "mixed" [flag,f] (e arrow (If (ref flag) (global "identity@one" arrow) (ref f)))
      mixedResult=run defaultLimits ["mixed"] [mixed,ident]
  check "a known branch cannot hide an unknown branch" (not (closed (result mixedResult "mixed")) && not (S.null (known (result mixedResult "mixed"))))
  let deep=run (Limits 32 64 0) ["projection"] [projection,ident]
  check "structure budget cannot certify a closed projection" (not (closed (result deep "projection")))
  let linear=cap {binderShape=LL}
      linearCode=code "linear-code" [linear] [arg] (ref linear)
      linearAnalysis=run defaultLimits [] [linearCode]
  check "capture shape is preserved without inventing unrestricted evidence"
    (map binderShape (summaryCaptures (analysisSummaries linearAnalysis M.! CodeTarget (CodeId "linear-code")))==[LL])
  let rb=b 8 "record" (exprType record)
      opaqueCall=apply (global "foreignMutator" (TFn (exprType record) int)) (ref rb)
      mutated=root "mutated" [] (e arrow (Let rb record
        (e arrow (Sequence opaqueCall (e arrow (RecordField (ref rb) ["cb"]))))))
      mutation=run defaultLimits ["mutated"] [mutated,ident]
  check "opaque calls invalidate product evidence rather than keeping stale fields"
    (not (closed (result mutation "mutated")) && summaryProductFlowInvalidated (analysisSummaries mutation M.! RootTarget "mutated"))
  let acrossOwners=run defaultLimits ["mutated","projection"] [mutated,projection,ident]
  check "opaque effects invalidate potentially aliased product evidence in other owners"
    (not (closed (result acrossOwners "projection")))
  putStrLn "Callable analysis: branches, imports, parameters/returns, PAP prefixes, captures, products, recursion, unknowns and budgets PASS"
