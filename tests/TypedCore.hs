import Infer
import Infer.Result
import Core.Identity
import qualified Core.Typed.Syntax as T
import Core.Typed.Verify
import Core.Typed.Erase
import Core.Typed.Close
import Core.Typed.Layout
import qualified Codegen.Lower as Lower
import Codegen.Policy (m2Policy)
import qualified Codegen.Eval as Eval
import Core.Syntax
import Frontend.Syntax
import Frontend.Parser (program)
import Frontend.Desugar
import Frontend.Desugar.Checked
import Struct (sigTable,structTable,expandStructs,erasePSig)
import Ownership.Shape (LShape(..))
import Ownership.TypeShape (linShapeT)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Monad.State.Strict (runState)
import Control.Monad (unless)
import qualified Infer.Evidence as Evidence
import Data.List (isInfixOf)
import Text.Megaparsec (parse,errorBundlePretty)

check n ok = unless ok (error n)
right = either error id
failed (Left _) = True
failed _ = False
source = unlines
  [ "identity x = x."
  , "add x y = x + y."
  , "fp x y = x + y + 1.25."
  , "cmp x y = x < y."
  , "capture x = fn y -> x + y."
  , "captureCall x y = (capture x) y."
  , "deepCapture x = fn y -> fn z -> x + y + z."
  , "deepCall x y z = ((deepCapture x) y) z."
  , "polyCapture n = ident x = x; combine y = (ident y,ident True); (a,b) = combine n; if b then a else 0."
  , "shadow x = (fn x -> x + 1) x."
  , "local x = y = x + 1; z = y * 2; z."
  , "choose x = if x < 0 then 0 else x."
  , "inverse x = case x of False -> True | True -> False."
  , "pipeline x = x |> identity."
  , "sequence x = print x >> x."
  , "text x = print x."
  , "Token 1 = Type Int."
  , "take : Token -> Token."
  , "take token = token."
  , "aggregate x = (x,x)."
  , "Choice a = Type (No | Yes a)."
  , "classify (Yes x) (Yes y) = x + y."
  , "classify _ _ = 0."
  , "nested x pair = case pair of (Yes x,Yes y) -> x + y | _ -> x."
  , "wild _ = 42."
  , "tupleArg (a,b) = a + b."
  , "recordArg {x,y} = x + y."
  , "record n = {y = n + 2,x = n + 1}."
  , "other n = {x = n,z = True}."
  , "project r = r.x."
  , "change r n = {r | x = n}."
  , "outer n = {flag = False,inner = {x = n,y = n + 1}}."
  , "deep r n = {r | inner.x = n}."
  , "bindShadow pair = (x,y) = pair; x = 40; y + x."
  , "guarded p | Yes n <- p, n > 0 = n."
  , "guarded _ = 0."
  , "guardShadow x p | Yes x <- p = x."
  , "guardShadow x _ = x."
  , "ints n = [n,n + 1]."
  , "atom = :hello."
  , "render n = print \"value={n + 0.5}\"."
  , "bare n = print (n + 0.5)."
  , "boolSyntax a b = a and b."
  , "chain r f = r |>? f."
  , "localFn x = inc n = n + x; inc 2."
  , "recur n = loop k = if k == 0 then n else loop (k - 1); loop 3."
  , "recAnon n = loop = (fn k -> if k == 0 then n else loop (k - 1)); loop 3."
  , "recNoCapture n = loop k = if k == 0 then 7 else loop (k - 1); loop n."
  , "recNested n = loop k = if k == 0 then n else (fn u -> loop (k - 1)) 0; loop 3."
  , "recEscape n = loop k = if k == 0 then n else loop (k - 1); loop."
  , "recEscapeCall n = (recEscape n) 3."
  , "recPartial n = loop k acc = if k == 0 then acc else loop (k - 1) (acc + n); part = loop 3; part 0."
  , "recPoly n = loop k x = if k == 0 then x else loop (k - 1) x; (a,b) = (loop 2 n,loop 2 True); if b then a else 0."
  , "recInner n = loop k = (fn unit -> inner j = if j == 0 then loop (k - 1) else inner (j - 1); if k == 0 then n else inner 2) 0; loop 3."
  , "recShadow n = loop k = if k == 0 then n else loop (k - 1); apply loop = loop 2; (loop 3,apply (fn x -> x + 1))."
  , "ProbeArith = Sig { ofInt : Int -> t, (+) }."
  , "ProbeOps = Struct ProbeArith { ofInt = fn n -> n, (+) = fn x y -> x + y }."
  , "carrier (s : ProbeArith) n = x = s.ofInt n; x + x."
  , "carrierLeft (s : ProbeArith) n = case n > 0 of True -> carrierRight s (n - 1) | False -> x = s.ofInt n; x + x."
  , "carrierRight (ops : ProbeArith) n = case n > 0 of True -> carrierLeft ops (n - 1) | False -> x = ops.ofInt n; x + x."
  ]
main = do
  let rawTops=right (either (Left . errorBundlePretty) Right (parse program "typed-core.fpr" source))
      (expansionErrors,tops)=expandStructs (sigTable rawTops) rawTops
      result=inferTopsChecked (Namespace "source") aotProf (sigTable rawTops) (structTable rawTops) tops
  check "struct expansion" (null expansionErrors)
  check ("source typing "++show (inferenceErrors result)) (null (inferenceErrors result))
  let plans=right (prepareChecked result)
      expected=S.fromList ["identity","add","fp","cmp","capture","captureCall","deepCapture","deepCall","polyCapture","shadow","local","choose","inverse","pipeline","sequence","text","take","aggregate","classify","nested","wild","tupleArg","recordArg","record","other","outer","project","change","deep","bindShadow","guarded","guardShadow","ints","atom","render","bare","boolSyntax","chain","localFn","recur","recAnon","recNoCapture","recNested","recEscape","recEscapeCall","recPartial","recPoly","recInner","recShadow","ProbeOps.ofInt","ProbeOps.+","ProbeOps","carrier","carrierLeft","carrierRight"]
  check ("coverage "++show (checkedDeclines plans)) (checkedNames plans==expected)
  let Just (Forall _ _ (TFn dict (TFn _ output)))=M.lookup "carrier" (inferenceSchemes result)
  check "unannotated operator member is constrained before generalization"
    (maybe False (sameType (TFn output (TFn output output))) (fieldType dict ["+"]))
  let proof=case inferenceEvidence result of Right (Just e)->e; _->error "missing source proof"
      owners=M.fromList [(Evidence.expressionIdentity e,Evidence.expressionOwner e) | e<-Evidence.evidenceExpressions proof]
      witnesses=[(owner,param) | e<-inferenceElaborations result,OpProj param _<-[elaborationTarget e],
                               Just uid<-[elaborationExpression e],Just (Just owner)<-[M.lookup uid owners]]
  check "dictionary dispatch keeps the lexical witness in mutual recursion"
    (("carrierLeft","s") `elem` witnesses && ("carrierRight","ops") `elem` witnesses)
  let inferSource src=let raw=right (either (Left . errorBundlePretty) Right (parse program "negative.fpr" src))
                          (_,expanded)=expandStructs (sigTable raw) raw
                      in inferTopsChecked (Namespace "negative") aotProf (sigTable raw) (structTable raw) expanded
      badProvider=inferSource (unlines
        ["ProbeArith = Sig { ofInt : Int -> t, (+) }.",
         "Wrong = Struct ProbeArith { ofInt = fn n -> n, (+) = False }.",
         "carrier (s : ProbeArith) n = x = s.ofInt n; x + x.",
         "main = carrier Wrong 1."])
  check "a non-function operator field is refused at its caller" (not (null (inferenceErrors badProvider)))
  let latePromise=inferSource "bad : a -> a. bad x = x + x."
  check "written signatures are validated after defaulting and resolution"
    (any (isInfixOf "more general") (inferenceErrors latePromise))
  let ts=erasePSig (inferenceTops result)
      env=DEnv 0 (collectCons "unit" ts) (collectShapes ts) [] []
      (old,oldState)=runState (compileTop ts) env
      (lowered,newState)=runState (compileTopChecked plans ts) env
      new=desugaredCore lowered
  check ("typed path is used for covered entries: "++show (M.keysSet (desugaredTyped lowered))) (M.keysSet (desugaredTyped lowered)==expected `S.union` M.keysSet (dCons env))
  check "closed stage covers every typed input" (M.keysSet (desugaredClosed lowered)==M.keysSet (desugaredTyped lowered))
  check "all closed products verify" (all (not . failed . verifyClosed (desugaredTypeContext lowered)) (M.elems (desugaredClosed lowered)))
  let oldLift=runState (compileTop ts >>= liftFix) env
      newLift=runState (lowerToUntyped plans ts >>= liftFix) env
      oldProgram=fst oldLift
      newProgram=fst newLift
      (oldIr,_)=Lower.lowerProgram m2Policy M.empty oldProgram oldProgram M.empty M.empty
      (newIr,_)=Lower.lowerProgram m2Policy M.empty newProgram newProgram M.empty M.empty
      noLambda body=case body of
        CLam _ _->False
        CApp a b->noLambda a && noLambda b
        CLet _ a b->noLambda a && noLambda b
        CIf a b c->all noLambda [a,b,c]
        CMk _ _ xs->all noLambda xs
        CTagEq _ _ x->noLambda x
        CProj _ x->noLambda x
        _->True
  check "erased typed entries and generated code already contain no lambdas"
    (all (noLambda . snd) (M.elems new) && all (\(_,_,b)->noLambda b) (dLifted newState))
  let codes=concatMap (M.elems . closedCode) (M.elems (desugaredClosed lowered))
  check "both closure and join code are typed products"
    (any ((==T.ClosureCode).T.codeKind) codes && any ((==T.JoinCode).T.codeKind) codes)
  check "polymorphic capture schemes survive conversion"
    (any (\code->any (\b->case T.binderScheme b of Forall (_:_) _ _->True; _->False) (T.codeCaptures code)) codes)
  let intArg=Eval.RInt
      boolArg=Eval.rvBool
      (choiceId,yesVariant,_)=dCons env M.! "Yes"
      (_,noVariant,_)=dCons env M.! "No"
      yes n=Eval.RObj choiceId yesVariant [intArg n]
      no=Eval.RObj choiceId noVariant []
      (tupleId,tupleVariant,_)=dCons env M.! "Tup2"
      pair a b=Eval.RObj tupleId tupleVariant [a,b]
      cases=[("identity",[intArg 9],intArg 9),("add",map intArg [4,7],intArg 11),
        ("captureCall",map intArg [40,2],intArg 42),("deepCall",map intArg [10,20,30],intArg 60),
        ("polyCapture",[intArg 19],intArg 19),("shadow",[intArg 8],intArg 9),
        ("classify",[yes 2,yes 3],intArg 5),("classify",[yes 2,no],intArg 0),
        ("nested",[intArg 10,pair (yes 2) (yes 3)],intArg 5),
        ("nested",[intArg 10,pair (yes 2) no],intArg 10),
        ("inverse",[boolArg True],boolArg False),("localFn",[intArg 8],intArg 10)]
  mapM_ (\(name,args,answer)->do
    check ("old evaluator covers "++name) (M.member name oldIr)
    check ("closed evaluator covers "++name) (M.member name newIr)
    check ("old evaluator answer "++name) (Eval.ocResult (Eval.evalProgram oldIr name args)==Right answer)
    check ("closed evaluator answer "++name) (Eval.ocResult (Eval.evalProgram newIr name args)==Right answer)) cases
  -- Source inference accepted these before typed closure conversion, but the
  -- old native path treated the local self name as an unknown primitive.
  let recursiveCases=[("recur",[intArg 19],intArg 19),("recAnon",[intArg 43],intArg 43),
        ("recNoCapture",[intArg 3],intArg 7),("recNested",[intArg 23],intArg 23),
        ("recEscapeCall",[intArg 29],intArg 29),("recPartial",[intArg 7],intArg 21),
        ("recPoly",[intArg 31],intArg 31),("recInner",[intArg 37],intArg 37),
        ("recShadow",[intArg 41],pair (intArg 41) (intArg 3))]
  mapM_ (\(name,args,answer)->check ("recursive evaluator answer "++name)
    (Eval.ocResult (Eval.evalProgram newIr name args)==Right answer)) recursiveCases
  -- The compatibility seam must not reuse stale annotations after a surface
  -- transformation; this is explicitly not proof of a typed transformation.
  let changed=[TBind "add" [PVar "x",PVar "y"] [] (SInt 7)]
  let (changedProduct,_)=runState (compileTopChecked plans changed) env
      changedProgram=desugaredCore changedProduct
      (changedIr,_)=Lower.lowerProgram m2Policy M.empty changedProgram changedProgram M.empty M.empty
  check "changed input does not reuse a typed plan"
    (M.notMember "add" (desugaredTyped changedProduct) && M.notMember "add" (desugaredClosed changedProduct))
  check "changed input uses its own lowering"
    (Eval.ocResult (Eval.evalProgram changedIr "add" [Eval.RInt 4,Eval.RInt 9])==Right (Eval.RInt 7))
  let independent prefix extra=
        let input=right (either (Left . errorBundlePretty) Right (parse program "unit.fpr" (extra++"unitFn x = (fn y -> x + y) 2.")))
            checked=inferTopsChecked (Namespace prefix) aotProf (sigTable input) (structTable input) input
            planned=right (prepareChecked checked)
            units=inferenceTops checked
            initial=DEnv 0 (collectCons "unit" units) (collectShapes units) [] []
            unitProgram=fst (runState (lowerToUntyped planned units >>= liftFix) initial)
        in M.filterWithKey (\name _ -> name=="unitFn" || M.notMember name (dCons initial)) unitProgram
  check "unit code is independent of inference namespaces and unrelated root constructors"
    (independent "one" ""==independent "two" "Extra = Type Int. ")
  let uid=BinderId (Namespace "test") 0
      bid=BinderId (Namespace "test") 1
      int=TC "Int";bool=TC "Bool"
      bind n v ty=T.Binder v n (Forall [] [] ty) LU
      x=bind "x" uid int
      expr ty node=T.Expr ty LU T.Generated Nothing node
      ref=expr int (T.Var (T.Local uid))
      fn=T.Function "test" [x] ref
  check "valid typed function" (not (failed (verifyFunction (T.TypeContext [] M.empty) fn)))
  check "missing local refused" (failed (verifyFunction (T.TypeContext [] M.empty) (fn {T.functionParameters=[]})))
  check "reference type refused" (failed (verifyFunction (T.TypeContext [] M.empty) (fn {T.functionBody=expr bool (T.Var (T.Local uid))})))
  check "duplicate binder identity refused" (failed (verifyFunction (T.TypeContext [] M.empty) (fn {T.functionParameters=[x,x]})))
  let owned=T.Binder uid "token" (Forall [] [] (TC "Token")) LL
      ownedRef=T.Expr (TC "Token") LL T.Generated Nothing (T.Var (T.Local uid))
      ownedFn=T.Function "owned" [owned] ownedRef
  check "owned annotations accepted" (not (failed (verifyFunction (T.TypeContext ["Token"] M.empty) ownedFn)))
  check "owned expression shape cannot be silently weakened"
    (failed (verifyFunction (T.TypeContext ["Token"] M.empty) (ownedFn {T.functionBody=ownedRef {T.exprShape=LU}})))
  check "owned binder shape cannot be silently weakened"
    (failed (verifyFunction (T.TypeContext ["Token"] M.empty) (ownedFn {T.functionParameters=[owned {T.binderShape=LU}]})))
  check "bad application refused" (failed (verifyFunction (T.TypeContext [] M.empty) (fn {T.functionBody=expr int (T.Apply ref ref)})))
  check "bad result refused" (failed (verifyFunction (T.TypeContext [] M.empty) (fn {T.functionBody=expr bool (T.Let (bind "y" bid int) ref ref)})))
  check "bad arm type refused" (failed (verifyFunction (T.TypeContext [] M.empty) (fn {T.functionBody=expr int (T.If (expr bool (T.BoolValue True)) ref (expr bool (T.BoolValue False)))})))
  check "bad lambda type refused" (failed (verifyFunction (T.TypeContext [] M.empty) (fn {T.functionBody=expr int (T.Lambda [bind "y" bid int] ref)})))
  check "strict recursive value initializer refused" (failed (verifyFunction (T.TypeContext [] M.empty)
    (fn {T.functionBody=expr int (T.LetRec (bind "cycle" bid int) (expr int (T.Var (T.Local bid))) ref)})))
  let recursiveBinder=bind "self" bid (TFn int int)
      recursiveArg=bind "arg" (BinderId (Namespace "test") 3) int
      selfRef=expr (TFn int int) (T.Var (T.Local bid))
      recursiveRhs=expr (TFn int int) (T.Lambda [recursiveArg] (expr int (T.Apply selfRef ref)))
      recursiveFn=fn {T.functionBody=expr int (T.LetRec recursiveBinder recursiveRhs ref)}
  check "recursive self is in scope in its function initializer"
    (not (failed (verifyFunction (T.TypeContext [] M.empty) recursiveFn)))
  check "ordinary let does not acquire recursive scope" (failed (verifyFunction (T.TypeContext [] M.empty)
    (fn {T.functionBody=expr int (T.Let recursiveBinder recursiveRhs ref)})))
  check "recursive initializer signature mismatch refused" (failed (verifyFunction (T.TypeContext [] M.empty)
    (fn {T.functionBody=expr int (T.LetRec (bind "self" bid (TFn bool int)) recursiveRhs ref)})))
  let runErase f = fst (runState (eraseFunction (T.TypeContext [] M.empty) (Layout fresh (const Nothing) M.empty (\_ _ _->pure ())) f) env)
  check "erasure refuses spelling capture"
    (failed (runErase (fn {T.functionBody=expr int (T.Let (bind "x" bid int) ref ref)})))
  let typed ty n=T.Expr ty (linShapeT [] ty) T.Generated Nothing n
      recordTy=TRec (RExt "x" int RNil)
      recordBinder=bind "record" uid recordTy
      recordRef=typed recordTy (T.Var (T.Local uid))
      withRecord b=T.Function "record-check" [recordBinder {T.binderShape=linShapeT [] recordTy}] b
  check "record projection type refused"
    (failed (verifyFunction (T.TypeContext [] M.empty) (withRecord (typed bool (T.RecordField recordRef ["x"])))))
  check "record update field type refused"
    (failed (verifyFunction (T.TypeContext [] M.empty) (withRecord (typed recordTy (T.RecordUpdate recordRef [(["x"],typed bool (T.BoolValue True))])))))
  let update=T.UpdatePlan ["x"] [T.UpdateBranch 42 [("x",T.ReplaceField (typed int (T.IntValue 7)))]]
      planned tree=withRecord (typed recordTy (T.PlannedUpdate recordRef tree))
      recordTypes=T.TypeContext [] M.empty
  check "planned update verifies" (not (failed (verifyFunction recordTypes (planned update))))
  check "planned update field type refused" (failed (verifyFunction recordTypes
    (planned (T.UpdatePlan ["x"] [T.UpdateBranch 42 [("x",T.ReplaceField (typed bool (T.BoolValue True)))]]))))
  check "planned update cannot omit replacements" (failed (verifyFunction recordTypes
    (planned (T.UpdatePlan ["x"] [T.UpdateBranch 42 [("x",T.KeepField)]]))))
  check "stale layout plan refused at erasure" (failed (fst (runState
    (eraseFunction recordTypes (Layout fresh (const Nothing) (M.singleton ["x"] 43) (\_ _ _->pure ())) (planned update)) env)))
  let functionTy=TFn int int
      functionRecord=TRec (RExt "f" functionTy (RV 100))
      recordParam=(bind "r" uid functionRecord) {T.binderShape=linShapeT [] functionRecord}
      lambda=typed functionTy (T.Lambda [bind "n" bid int] (typed int (T.Var (T.Local bid))))
      sourceUpdate=T.Function "layout-clone" [recordParam]
        (typed functionRecord (T.RecordUpdate (typed functionRecord (T.Var (T.Local uid))) [(["f"],lambda)]))
      layoutShapes=M.fromList [(["a","f"],41),(["b","f"],42)]
      layoutFn=plannedFunction (right (planFunction (Namespace "layout-test") layoutShapes recordTypes sourceUpdate))
      closedLayout=right (fst (runState (closeFunction (Namespace "layout-test") fresh recordTypes layoutFn) env))
  check "layout branches own distinct closed code" (M.size (closedCode closedLayout)==2)
  check "closing refuses unplanned update duplication" (failed (fst (runState
    (closeFunction (Namespace "layout-test") fresh recordTypes sourceUpdate) env)))
  check "tuple component type refused"
    (failed (verifyFunction (T.TypeContext [] M.empty) (T.Function "tuple-check" [] (typed (TTupT [int,bool]) (T.TupleValue [typed int (T.IntValue 1)])))))
  check "list component type refused"
    (failed (verifyFunction (T.TypeContext [] M.empty) (T.Function "list-check" [] (typed (TAp (TC "List") int) (T.ListValue [typed bool (T.BoolValue True)])))))
  let box=TC "Box"
      model=T.TypeContext [] (M.singleton "C" (Forall [] [] (TFn int box)))
      boxArg=bind "box" uid box
      pat=T.Pattern box "C x" (T.ConstructorPattern "C" [T.Pattern int "x" (T.Bind (bind "x" bid int))])
      matched=typed int (T.Match T.CaseMatch [typed box (T.Var (T.Local uid))] [T.Alternative [pat] [] (typed int (T.Var (T.Local bid)))])
      boxFn=T.Function "constructor-check" [boxArg] matched
  check "constructor field type accepted" (not (failed (verifyFunction model boxFn)))
  let badPat=pat {T.patNode=T.ConstructorPattern "C" [T.Pattern bool "x" (T.Bind (bind "x" bid bool))]}
  check "constructor field signature refused"
    (failed (verifyFunction model (boxFn {T.functionBody=typed int (T.Match T.CaseMatch [typed box (T.Var (T.Local uid))] [T.Alternative [badPat] [] (typed int (T.IntValue 0))])})))
  let partial=T.Pattern (TFn int box) "C" (T.ConstructorPattern "C" [])
  check "partial constructor pattern refused"
    (failed (verifyFunction model (T.Function "partial-pattern" [bind "box" uid (TFn int box)] (typed int (T.Match T.CaseMatch [typed (TFn int box) (T.Var (T.Local uid))] [T.Alternative [partial] [] (typed int (T.IntValue 0))])))))
  check "non-Bool guard refused"
    (failed (verifyFunction model (boxFn {T.functionBody=typed int (T.Match T.CaseMatch [typed box (T.Var (T.Local uid))] [T.Alternative [pat] [T.BoolGuard (typed int (T.IntValue 1))] (typed int (T.Var (T.Local bid)))])})))
  let label=T.CodeId "$test-code"
      contracts=M.singleton label (T.CodeContract T.ClosureCode ([],[]) [(Forall [] [] int,LU)] [int] int)
      closure=expr (TFn int int) (T.ClosureValue label [uid])
      closureFn=fn {T.functionBody=closure}
      verify=verifyFunctionWith contracts (T.TypeContext [] M.empty)
  check "registered closure capture accepted" (not (failed (verify closureFn)))
  check "raw global cannot bypass a code contract" (failed (verify (closureFn
    {T.functionBody=expr (TFn int int) (T.Var (T.Global "$test-code" (Forall [] [] (TFn int int))))})))
  check "unregistered closure code refused" (failed (verify (closureFn {T.functionBody=expr (TFn int int) (T.ClosureValue (T.CodeId "absent") [uid])})))
  check "capture count refused" (failed (verify (closureFn {T.functionBody=expr (TFn int int) (T.ClosureValue label [])})))
  check "capture scope refused" (failed (verify (closureFn {T.functionBody=expr (TFn int int) (T.ClosureValue label [bid])})))
  check "join cannot escape as a closure" (failed (verifyFunctionWith (M.singleton label (T.CodeContract T.JoinCode ([],[]) [] [int] int)) (T.TypeContext [] M.empty) closureFn))
  check "capture schemes cannot be weakened" (failed (verifyFunctionWith (M.singleton label (T.CodeContract T.ClosureCode ([],[]) [(Forall [] [] bool,LU)] [int] int)) (T.TypeContext [] M.empty) closureFn))
  check "join argument type refused" (failed (verifyFunctionWith (M.singleton label (T.CodeContract T.JoinCode ([],[]) [] [int] int)) (T.TypeContext [] M.empty)
    (fn {T.functionBody=expr int (T.JoinCall label [] [expr bool (T.BoolValue True)])})))
  let wideNamespace=Namespace "wide-input"
      wideParameters=[bind ("p"++show i) (BinderId wideNamespace i) int | i<-[0..63]]
      wideArgs=[expr int (T.Var (T.Local (T.binderId b))) | b<-wideParameters]
      wildcard=T.Pattern int "_" T.Wildcard
      integer n=T.Pattern int (show n) (T.IntegerPattern n)
      wide=T.Function "wide" wideParameters (expr int (T.Match (T.FunctionMatch "wide") wideArgs
        [T.Alternative ([integer 0,integer 1]++replicate 62 wildcard) [] (expr int (T.IntValue 1)),
         T.Alternative (replicate 64 wildcard) [] (expr int (T.IntValue 2))]))
      closedWide=right (fst (runState (closeFunction (Namespace "wide") fresh (T.TypeContext [] M.empty) wide) env))
  check "64 captured arguments do not acquire a 65th join argument"
    (any (\code->T.codeKind code==T.JoinCode && length (T.codeCaptures code)==64 && null (T.codeParameters code)) (M.elems (closedCode closedWide)))
  let zero=T.Function "zero" [] (expr int (T.Match (T.FunctionMatch "zero") []
        [T.Alternative [] [T.BoolGuard (expr bool (T.BoolValue False)),T.BoolGuard (expr bool (T.BoolValue True))] (expr int (T.IntValue 1)),
         T.Alternative [] [] (expr int (T.IntValue 2))]))
      closedZero=right (fst (runState (closeFunction (Namespace "zero") fresh (T.TypeContext [] M.empty) zero) env))
  check "capture-free joins are nonnullary"
    (any (\code->T.codeKind code==T.JoinCode && null (T.codeCaptures code) && length (T.codeParameters code)==1) (M.elems (closedCode closedZero)))
  let lambdaOne=expr (TFn int int) (T.Lambda [bind "y" bid int] ref)
      lambdaTwo=expr (TFn int int) (T.Lambda [bind "z" (BinderId (Namespace "test") 2) int] ref)
      duplicateLabels=fn {T.functionBody=expr (TTupT [TFn int int,TFn int int]) (T.TupleValue [lambdaOne,lambdaTwo])}
  check "duplicate generated code labels refused" (failed (fst (runState
    (closeFunction (Namespace "duplicate-labels") (\prefix->pure (prefix++"_0")) recordTypes duplicateLabels) env)))
  let poly=Forall [1] [] (TFn (TV 1) (TV 1))
  check "scheme instantiation accepts coherent use" (instanceOf poly (TFn int int))
  check "scheme instantiation refuses inconsistent use" (not (instanceOf poly (TFn int bool)))
  let row=Forall [1] [2] (TFn (TRec (RExt "value" (TV 1) (RV 2))) (TV 1))
  check "row scheme preserves residual fields"
    (instanceOf row (TFn (TRec (RExt "extra" bool (RExt "value" int RNil))) int))
  check "free variables stay rigid" (not (instanceOf (Forall [] [] (TV 1)) int))
  putStrLn "Typed Core: checked lowering, lexical identities, annotation/scope refusals, typed closure/join conversion, polymorphic capture contracts and differential evaluator answers passed"
