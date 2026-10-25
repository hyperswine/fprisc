import Infer
import Infer.Result
import Core.Identity
import qualified Core.Typed.Syntax as T
import Core.Typed.Close
import Core.Typed.Walk (allBinders,mapChildrenM)
import Core.Typed.Verify
import qualified Core.Typed.Specialize as Spec
import qualified Type.Substitution as U
import qualified Codegen.Lower as Lower
import qualified Codegen.Eval as Eval
import Codegen.Policy (m2Policy)
import Frontend.Parser (program)
import Frontend.Syntax
import Frontend.Desugar
import Frontend.Desugar.Checked
import Struct (sigTable,structTable,expandStructs,erasePSig)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Functor.Const (Const(..))
import Control.Monad (unless)
import Control.Monad.State.Strict (evalState)
import Text.Megaparsec (parse,errorBundlePretty)
import qualified Struct
import Frontend.Traverse (sFree)

check label ok=unless ok (error label)
right=either error id
failed (Left _)=True
failed _=False
main=do
  source<-readFile "tests/typed_core/structs.fpr"
  let raw=right (either (Left . errorBundlePretty) Right (parse program "typed-structs" source))
      sigs=sigTable raw;structs=structTable raw
      (errors,tops)=expandStructs sigs raw
      checked=inferTopsChecked (Namespace "struct-tests") aotProf sigs structs tops
  check ("source checking: "++show (errors,inferenceErrors checked)) (null errors && null (inferenceErrors checked))
  let plans=right (prepareChecked checked)
      prepared=either (error . unlines) id (specializeCheckedSource plans)
      resolved=inferenceTops checked
      initial=DEnv 0 (collectCons "struct-tests" resolved) (collectShapes (specializedTops prepared)) [] []
      selected=S.fromList [n | TBind n _ _ _<-specializedTops prepared]
      lowered=evalState (desugarSpecialized prepared selected) initial
      typed=desugaredTyped lowered
      originals=desugaredTyped (evalState (compileTopChecked plans (erasePSig resolved)) initial)
      names=S.fromList ["twice#TypedInts","twice#TypedFloats","twice#TypedOffset","forward#TypedOffset",
        "forward#TypedFloats","left#TypedInts","right#TypedInts","poly#TypedInts","capture#TypedOffset",
        "local#TypedInts","polyLocal#TypedInts","shape#TypedInts","constant#TypedInts",
        "generic#TypedIdentity","generic#TypedWide","specific#TypedIdentity","makeVec#TypedFloats","getVector#TypedVector"]
  check ("typed specialization coverage: "++show (M.keys typed)) (names `S.isSubsetOf` M.keysSet typed)
  check "closed product covers every typed clone" (names `S.isSubsetOf` M.keysSet (desugaredClosed lowered))
  check "closed products verify" (all (not . failed . verifyClosed (desugaredTypeContext lowered)) (M.elems (desugaredClosed lowered)))
  let int=TC "Int";bool=TC "Bool"
      fn n=typed M.! n
      ids f=S.fromList (map T.binderId (T.functionParameters f++allBinders (T.functionBody f)))
      sourceIds=S.unions (map ids (M.elems originals))
      cloneIds=map (ids . fn) (S.toAscList names)
  check "clones introduce new identities" (all (S.null . S.intersection sourceIds) cloneIds)
  check "clones cannot share introduced identities" (sum (map S.size cloneIds)==S.size (S.unions cloneIds))
  check "F64 carrier specialization keeps the checked result"
    (map T.binderType (T.functionParameters (fn "twice#TypedFloats"))==[int]
     && sameType (T.exprType (T.functionBody (fn "twice#TypedFloats"))) (TC "F64"))
  let poly=fn "poly#TypedInts"
      generic=fn "generic#TypedIdentity"
  check "ordinary polymorphic parameters remain linked to the result" (case map T.binderType (T.functionParameters poly) of
    [a,b]->sameType a int && sameType (T.exprType (T.functionBody poly)) (TTupT [int,b]) && b/=int && b/=bool
    _->False)
  check "a polymorphic dictionary does not pin the first use"
    (case T.functionParameters generic of [p]->sameType (T.binderType p) (T.exprType (T.functionBody generic)) && T.binderType p/=int && T.binderType p/=bool;_->False)
  check "a polymorphic provider can satisfy a rigid Int signature"
    (sameType (T.functionType (fn "specific#TypedIdentity")) (TFn int int))
  check "hidden layout evidence keeps its physical position and instantiated element"
    (map T.binderType (T.functionParameters (fn "makeVec#TypedFloats"))==[TLayout (TC "F64"),int])
  let globals e=(case T.exprNode e of T.Var (T.Global n _)->[n];_->[])++getConst (mapChildrenM (Const . globals) e)
  check "specialized methods are direct checked globals" ("TypedInts.+" `elem` globals (T.functionBody (fn "twice#TypedInts")))
  check "a layout-capturing member stays the checked record value"
    ("TypedVector" `elem` globals (T.functionBody (fn "getVector#TypedVector")) && "TypedVector.build" `notElem` globals (T.functionBody (fn "getVector#TypedVector")))
  check "local-callee shadowing does not target a global clone" ("pick#TypedInts" `notElem` globals (T.functionBody (fn "main")))
  let full=evalState (lowerSpecialized prepared selected >>= liftFix) initial
      (ir,_)=Lower.lowerProgram m2Policy M.empty full full M.empty M.empty
      answer n xs=Eval.ocResult (Eval.evalProgram ir n (map Eval.RInt xs))
  check "independent specialized evaluator answers"
    (answer "twice#TypedInts" [3]==Right (Eval.RInt 6)
     && answer "forward#TypedOffset" [2]==Right (Eval.RInt 24)
     && answer "left#TypedInts" [3]==Right (Eval.RInt 7)
     && answer "local#TypedInts" [9]==Right (Eval.RInt 9))
  check "a nullary clone still returns a function" (case answer "constant#TypedInts" [] of Right (Eval.RPap _ _)->True;_->False)
  let (sub,_)=right (U.unifyTypes (S.singleton 0,S.empty) 10 [(TV 0,TV 1)])
      scoped=U.applyScheme sub (Forall [1] [] (TFn (TV 0) (TV 1)))
  check "type substitution does not capture a free variable"
    (U.schemeVariables scoped==(S.singleton 1,S.empty) && instanceOf scoped (TFn (TV 1) bool) && not (instanceOf scoped (TFn int bool)))
  check "rigid variables cannot be solved" (failed (U.unifyTypes mempty 10 [(TV 0,int)]))
  check "recursive types cannot be constructed" (failed (U.unifyTypes (S.singleton 0,S.empty) 10 [(TV 0,TFn (TV 0) int)]))
  check "closed rows cannot silently acquire fields" (failed (U.unifyTypes mempty 10 [(TRec RNil,TRec (RExt "x" int RNil))]))
  let leftRow=TRec (RExt "x" int (RV 1));rightRow=TRec (RExt "y" bool (RV 2))
      (rows,_)=right (U.unifyTypes (S.empty,S.fromList [1,2]) 10 [(leftRow,rightRow)])
  check "open rows share one residual tail" (sameType (U.applyType rows leftRow) (U.applyType rows rightRow))
  check "recursive rows cannot be constructed" (failed (U.unifyTypes (S.empty,S.singleton 1) 10 [(TRec (RV 1),TRec (RExt "x" int (RV 1)))]))
  let (fresh,_,_)=U.freshen 0 (Forall [0] [] (TFn (TV 0) (TV 0)))
      (freshRows,_)=right (U.unifyTypes (S.empty,S.fromList [1,2]) 0 [(leftRow,rightRow)])
  check "fresh supplies cannot collide with their source variables"
    (fresh/=TFn (TV 0) (TV 0) && sameType (U.applyType freshRows leftRow) (U.applyType freshRows rightRow))
  let context=Spec.Context (T.TypeContext [] M.empty) M.empty M.empty (S.singleton "absent") M.empty S.empty
  check "malformed structure metadata is refused" (failed (Spec.specialize (Namespace "bad") context M.empty))
  let site=ExprId (Namespace "deferred") 0
      record=TRec (RExt "value" int RNil)
      ft=TFn record int
      expr ty node=T.Expr ty (linShapeT [] ty) T.Generated Nothing node
      call=T.Expr int (linShapeT [] int) (T.Checked site) Nothing (T.Apply (expr ft (T.Var (T.Global "callee" (Forall [] [] ft))))
        (expr record (T.Var (T.Global "Dict" (Forall [] [] record)))))
      partialContext=Spec.Context (T.TypeContext [] M.empty) (M.fromList [("callee",Forall [] [] ft),("Dict",Forall [] [] record)])
        (M.singleton "callee" [0]) (S.singleton "Dict") M.empty (S.singleton site)
      deferred=right (Spec.specialize (Namespace "deferred") partialContext (M.singleton "caller" (T.Function "caller" [] call)))
  check "a compatibility callee does not publish partial typed clones"
    (M.null (Spec.functions deferred) && S.null (Spec.cloneNames deferred) && not (null (Spec.declines deferred)))
  let preamble=unlines (takeWhile (/="main =") (lines source))
      scoped tailSource=let raw=right (either (Left . errorBundlePretty) Right (parse program "scope" (preamble++tailSource)))
                            (_,expanded)=expandStructs (sigTable raw) raw
                            (errors,result)=Struct.specialize (sigTable raw) (structTable raw) expanded
                        in if null errors then result else error (show errors)
      hasClone ts=any (\t->case t of TBind n _ _ _->n=="pick#TypedInts";_->False) ts
      scopes=["scope pick = pick TypedInts 2.",
        "scope = (fn pick -> pick TypedInts 2) (fn s n -> n + 100).",
        "scope = pick = fn s n -> n + 100; pick TypedInts 2.",
        "scope = (pick,other) = ((fn s n -> n + 100),0); pick TypedInts 2.",
        "FnBox a = Type (FnBox a). scope = case FnBox (fn s n -> n + 100) of FnBox pick -> pick TypedInts 2.",
        "FnBox a = Type (FnBox a). scope | FnBox pick <- FnBox (fn s n -> n + 100) = pick TypedInts 2. scope = 0.",
        "scope = pick = fn s n -> if n == 0 then 0 else pick TypedInts (n - 1); pick TypedInts 2."]
  check "compatibility/Sol specialization respects every lexical binder" (all (not . hasClone . scoped) scopes)
  let ordered=scoped "FnBox a = Type (FnBox a). scope | True <- (pick TypedInts 2 > 0), FnBox pick <- FnBox (fn s n -> n + 100) = pick TypedInts 2. scope = 0."
  check "a later pattern guard cannot shadow an earlier guard's global call"
    (hasClone ordered && all (not . elem "pick#TypedInts" . sFree) [b | TBind "scope" _ _ b<-ordered])
  putStrLn "Typed structures: checked clones, type/row instantiation, polymorphic ordinary/provider/capture schemes, fresh identities, direct members, recursion, shadowing and evaluator answers passed"
