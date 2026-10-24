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
import Struct (sigTable,structTable)
import Ownership.Shape (LShape(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Monad.State.Strict (runState)
import Control.Monad (unless)
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
  ]
main = do
  let tops=right (either (Left . errorBundlePretty) Right (parse program "typed-core.fpr" source))
      result=inferTopsChecked (Namespace "source") aotProf (sigTable tops) (structTable tops) tops
  check ("source typing "++show (inferenceErrors result)) (null (inferenceErrors result))
  let plans=right (prepareChecked result)
      expected=S.fromList ["identity","add","fp","cmp","capture","shadow","local","choose","inverse","pipeline","sequence","text","take"]
  check ("coverage "++show (checkedDeclines plans)) (checkedNames plans==expected)
  let ts=inferenceTops result
      env=DEnv 0 (collectCons "unit" ts) (collectShapes ts) [] []
      (old,oldState)=runState (compileTop ts) env
      (lowered,newState)=runState (compileTopChecked plans ts) env
      new=desugaredCore lowered
  check "typed path is used for covered entries" (M.keysSet (desugaredTyped lowered)==expected)
  check "typed lowering preserves raw Core exactly" (old==new)
  check "typed lowering preserves fresh-name supply" (dFresh oldState==dFresh newState)
  let oldLift=runState (compileTop ts >>= liftFix) env
      newLift=runState (lowerToLegacy plans ts >>= liftFix) env
  check "typed lowering preserves closure/join lifting" (fst oldLift==fst newLift && dJoins (snd oldLift)==dJoins (snd newLift))
  -- The compatibility seam must not reuse stale annotations after a surface
  -- transformation; this is explicitly not proof of a typed transformation.
  let changed=[TBind "add" [PVar "x",PVar "y"] [] (SInt 7)]
  check "changed input uses its own lowering"
    (fst (runState (lowerToLegacy plans changed) env)==fst (runState (compileTop changed) env))
  let uid=BinderId (Namespace "test") 0
      bid=BinderId (Namespace "test") 1
      int=TC "Int";bool=TC "Bool"
      bind n v ty=T.Binder v n (Forall [] [] ty) LU
      x=bind "x" uid int
      expr ty node=T.Expr ty LU T.Generated Nothing node
      ref=expr int (T.Var (T.Local uid))
      fn=T.Function "test" [x] ref
  check "valid typed function" (not (failed (verifyFunction (T.TypeContext []) fn)))
  check "missing local refused" (failed (verifyFunction (T.TypeContext []) (fn {T.functionParameters=[]})))
  check "reference type refused" (failed (verifyFunction (T.TypeContext []) (fn {T.functionBody=expr bool (T.Var (T.Local uid))})))
  check "duplicate binder identity refused" (failed (verifyFunction (T.TypeContext []) (fn {T.functionParameters=[x,x]})))
  let owned=T.Binder uid "token" (Forall [] [] (TC "Token")) LL
      ownedRef=T.Expr (TC "Token") LL T.Generated Nothing (T.Var (T.Local uid))
      ownedFn=T.Function "owned" [owned] ownedRef
  check "owned annotations accepted" (not (failed (verifyFunction (T.TypeContext ["Token"]) ownedFn)))
  check "owned expression shape cannot be silently weakened"
    (failed (verifyFunction (T.TypeContext ["Token"]) (ownedFn {T.functionBody=ownedRef {T.exprShape=LU}})))
  check "owned binder shape cannot be silently weakened"
    (failed (verifyFunction (T.TypeContext ["Token"]) (ownedFn {T.functionParameters=[owned {T.binderShape=LU}]})))
  check "bad application refused" (failed (verifyFunction (T.TypeContext []) (fn {T.functionBody=expr int (T.Apply ref ref)})))
  check "bad result refused" (failed (verifyFunction (T.TypeContext []) (fn {T.functionBody=expr bool (T.Let (bind "y" bid int) ref ref)})))
  check "bad arm type refused" (failed (verifyFunction (T.TypeContext []) (fn {T.functionBody=expr int (T.If (expr bool (T.BoolValue True)) ref (expr bool (T.BoolValue False)))})))
  check "bad lambda type refused" (failed (verifyFunction (T.TypeContext []) (fn {T.functionBody=expr int (T.Lambda [bind "y" bid int] ref)})))
  check "erasure refuses spelling capture"
    (failed (eraseFunction (T.TypeContext []) (fn {T.functionBody=expr int (T.Let (bind "x" bid int) ref ref)})))
  let poly=Forall [1] [] (TFn (TV 1) (TV 1))
  check "scheme instantiation accepts coherent use" (instanceOf poly (TFn int int))
  check "scheme instantiation refuses inconsistent use" (not (instanceOf poly (TFn int bool)))
  let row=Forall [1] [2] (TFn (TRec (RExt "value" (TV 1) (RV 2))) (TV 1))
  check "row scheme preserves residual fields"
    (instanceOf row (TFn (TRec (RExt "extra" bool (RExt "value" int RNil))) int))
  check "free variables stay rigid" (not (instanceOf (Forall [] [] (TV 1)) int))
  putStrLn "Typed Core: checked lowering, lexical identities, annotation/scope refusals, exact erasure and closure lifting passed"
