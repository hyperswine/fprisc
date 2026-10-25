import Infer
import Infer.Result
import Core.Identity
import qualified Core.Typed.Syntax as T
import Core.Typed.Verify
import Core.Typed.Erase
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
      expected=S.fromList ["identity","add","fp","cmp","capture","shadow","local","choose","inverse","pipeline","sequence","text","take","aggregate","classify","nested","wild","tupleArg","recordArg","record","other","outer","project","change","deep","bindShadow","guarded","guardShadow","ints","atom","render","bare","boolSyntax","chain","localFn","ProbeOps.ofInt","ProbeOps.+","ProbeOps","carrier","carrierLeft","carrierRight"]
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
  check "typed lowering preserves raw Core exactly" (old==new)
  check "typed lowering preserves fresh-name supply" (dFresh oldState==dFresh newState)
  let oldLift=runState (compileTop ts >>= liftFix) env
      newLift=runState (lowerToUntyped plans ts >>= liftFix) env
  check "typed lowering preserves closure/join lifting" (fst oldLift==fst newLift && dJoins (snd oldLift)==dJoins (snd newLift))
  -- The compatibility seam must not reuse stale annotations after a surface
  -- transformation; this is explicitly not proof of a typed transformation.
  let changed=[TBind "add" [PVar "x",PVar "y"] [] (SInt 7)]
  check "changed input uses its own lowering"
    (fst (runState (lowerToUntyped plans changed) env)==fst (runState (compileTop changed) env))
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
  let poly=Forall [1] [] (TFn (TV 1) (TV 1))
  check "scheme instantiation accepts coherent use" (instanceOf poly (TFn int int))
  check "scheme instantiation refuses inconsistent use" (not (instanceOf poly (TFn int bool)))
  let row=Forall [1] [2] (TFn (TRec (RExt "value" (TV 1) (RV 2))) (TV 1))
  check "row scheme preserves residual fields"
    (instanceOf row (TFn (TRec (RExt "extra" bool (RExt "value" int RNil))) int))
  check "free variables stay rigid" (not (instanceOf (Forall [] [] (TV 1)) int))
  putStrLn "Typed Core: checked lowering, lexical identities, annotation/scope refusals, exact erasure and closure lifting passed"
