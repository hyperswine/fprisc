import qualified Core.Typed.Syntax as T
import Core.Typed.Callback (CallbackMode(..))
import qualified Core.Region.Types as V
import Core.Region.Interface
import qualified Core.Calling as Calling
import qualified Compiler.Native.Core as Native
import qualified Compiler.Native.Regions as R
import qualified ReceiveTurns as Turns
import Core.Analysis.Scope
import Core.Identity
import Core.Syntax
import Compiler.DataLayout
import Frontend.Desugar.Typed
import Frontend.Desugar (collectCons,collectShapes)
import Frontend.Parser (program)
import Frontend.Syntax
import Struct (sigTable,structTable,expandStructs)
import Infer
import Infer.Result
import Type.Syntax
import Control.Monad (unless)
import Data.List (isInfixOf,isSuffixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Text.Megaparsec (parse,errorBundlePretty)

check label ok=unless ok (error label)
right=either error id
failed (Left _)=True
failed _=False
parseSource source=either (error . errorBundlePretty) id (parse program "regions" source)
prepareSource ns source=
  let raw=parseSource source
      (errors,tops)=expandStructs (sigTable raw) raw
      result=inferTopsChecked (Namespace ns) aotProf (sigTable raw) (structTable raw) tops
  in if null errors && null (inferenceErrors result)
     then (right (prepareChecked result),inferenceTops result) else error (show (inferenceErrors result))
native ns source names=
  let (plans,tops)=prepareSource ns source
      layouts=Layouts (collectCons "unit" tops) (collectShapes tops)
      selected=right (selectUnit (M.keysSet (constructorLayouts layouts)) (right (selectCheckedUnit plans names)))
  in right (Native.compileSelection PreserveCallbacks layouts selected)
place input=right (R.place (R.Options True True) (R.context M.empty input) input)
int=TC "Int"
fn=TFn int int
con qs fields result=Forall qs [] (foldr TFn result fields)
app n t=TAp (TC n) t

main=do
  let schemas=M.fromList
        [("Box",con [0] [TV 0] (app "Box" (TV 0))),
         ("Leaf",con [1] [TV 1] (app "Tree" (TV 1))),
         ("Branch",con [2] [app "Tree" (TV 2),app "Tree" (TV 2)] (app "Tree" (TV 2))),
         ("RecordBox",con [3] [TRec (RExt "x" (TV 3) RNil)] (app "RecordBox" (TV 3))),
         ("BadValue",con [] [fn] (TC "BadValue")),("Owned",con [] [int] (TC "Owned"))]
      model=right (V.valueModel (T.TypeContext ["Owned"] schemas))
  check "nominal fields use checked constructor schemes with variant-local quantifiers"
    (V.copyable model (app "Tree" int) && not (V.bounded model (app "Tree" int))
      && V.bounded model (app "Box" int) && V.bounded model (app "RecordBox" int))
  check "copyability cannot hide functional/owned fields or unknown rows/type variables"
    (all (not . V.copyable model) [TC "BadValue",TC "Owned",app "Box" fn,app "Box" (TV 0),TRec (RV 9)]
      && V.copyable model (TC "String") && not (V.bounded model (TC "String")))
  check "nominal constructor arities cannot disagree"
    (failed (V.valueModel (T.TypeContext [] (M.fromList [("A",con [] [] (TC "Wrong")),("B",con [1] [] (app "Wrong" (TV 1)))]))))
  let call=Calling.calling 1 (TFn int fn)
  check "physical arguments do not consume arrows belonging to the result"
    (maybe False (\c->Calling.callingArity c==1 && Calling.callingResult c==fn) call
      && maybe True (const False) (Calling.calling 3 (TFn int fn)))
  let layoutNative=native "layout" "make n = ignored = ignored; fn value -> Vec.push value (Vec.new Unit)." (S.singleton "make")
      layoutInput=right (R.prepare layoutNative)
  check "declaration-only layout arguments cannot consume a returned function's arrow"
    (case M.lookup "make" (R.programInterfaces layoutInput) of
      Just f->interfaceProvenance f==SourceDeclaration "make" && interfaceArity f==2
        && (case interfaceArguments f of TLayout _:_->True;_->False)
        && (case interfaceResult f of TFn _ _->True;_->False)
      _->False)
  let body="counter n = loop = (fn k -> _ = str k; if k == 0 then 0 else loop (k - 1)); loop n."
      compiled=native "physical" body (S.singleton "counter")
      input=right (R.prepare compiled)
      private=[(name,f) | (name,f)<-M.toList (R.programInterfaces input),PrivateEntry "counter" _ _<-[interfaceProvenance f]]
      result=place input
  check "checked private interfaces retain physical binders, result shapes and owners"
    (not (null private) && all (\(_,f)->interfaceArity f==1 && interfaceResult f==int
      && maybe False ((==1) . length) (interfaceParameters f)
      && maybe False (const True) (interfaceResultShape f)) private)
  check "a region input retains its checked native parent"
    (Native.nativeProgram (R.programNative input)==Native.nativeProgram compiled)
  check "generated loop declarations retain checked source provenance and control-slot arities"
    (not (M.null (R.resultGenerated result)) && all (\(name,g)->
      maybe False (\f->length (Turns.generatedParameters g)==interfaceArity f+2)
        (Turns.generatedSourceInterface g)
      && Just (Turns.generatedParameters g)==(fst <$> M.lookup name (R.resultProgram result)))
      (M.toList (R.resultGenerated result)))
  let other=right (R.prepare (native "other" body (S.singleton "counter")))
  check "a region context cannot borrow a different checking namespace"
    (failed (R.place (R.Options True True) (R.context M.empty input) other))
  let (physicalPlans,physicalTops)=prepareSource "physical" body
      physicalLayouts=Layouts (collectCons "unit" physicalTops) (collectShapes physicalTops)
      physicalSelection=right (selectUnit (M.keysSet (constructorLayouts physicalLayouts))
        (right (selectCheckedUnit physicalPlans (S.singleton "counter"))))
      changedLayouts=physicalLayouts {shapeLayouts=M.singleton ["unrelated"] 99}
      changedLayoutInput=right (R.prepare (right (Native.compileSelection PreserveCallbacks changedLayouts physicalSelection)))
  check "a region context cannot borrow a different physical layout authority"
    (failed (R.place (R.Options True True) (R.context M.empty input) changedLayoutInput))
  let collisionName="$loop.in."++fst (head private)
      collisionSelection=right (selectClauses (M.keysSet (constructorLayouts physicalLayouts)) physicalPlans
        (physicalTops++[TBind collisionName [] [] (SInt 7)]))
      collisionInput=right (R.prepare (right (Native.compileSelection PreserveCallbacks physicalLayouts collisionSelection)))
  check "generated region names cannot silently overwrite an input definition"
    (case R.place (R.Options True False) (R.context M.empty collisionInput) collisionInput of
      Left reason->"generated helper collides" `isInfixOf` reason
      Right _->False)
  let names=["p"++show i | i<-[0..62]]
      wide="wide "++unwords names++" = _ = str p0; if p0 == 0 then 0 else wide (p0 - 1) "++unwords (tail names)++"."
      wideResult=place (right (R.prepare (native "wide" wide (S.singleton "wide"))))
  check "loop control cells never exceed the physical argument convention"
    (M.null (R.resultGenerated wideResult) && any (isInfixOf "loop control cells exceed") (R.resultNotes wideResult))
  -- A strict recursive value is intentionally deferred by semantic lowering.
  -- Its checked declaration is not evidence that the legacy body is typed.
  let scopeSource="entry : Int -> Int -> Int. other : Int -> Int -> Int. entry n = ignored = ignored; fn x -> x + n. other n = ignored = ignored; fn x -> x - n."
      a=right (R.prepare (native "scope" scopeSource (S.singleton "entry")))
      b=right (R.prepare (native "scope" scopeSource (S.singleton "other")))
      scopeResult=right (R.place (R.Options True True) (R.context M.empty a) b)
      scopeProjection=maybe M.empty R.analysisProgram (R.resultAnalysis scopeResult)
  check "deferred source bodies retain only their exact checked declaration"
    (case M.lookup "entry" (R.programInterfaces a) of
      Just f->interfaceProvenance f==SourceDeclaration "entry" && interfaceArity f==1
        && maybe True (const False) (interfaceParameters f) && interfaceResult f==fn
      _->False)
  check "independent compatibility counters remain distinct in cost/effect analysis"
    (length (filter (isSuffixOf "lifted_1") (M.keys scopeProjection))==2)
  let (plans,tops)=prepareSource "borrow" "entry n = n + 1."
      layouts=Layouts (collectCons "unit" tops) (collectShapes tops)
      changed=right (selectClauses (M.keysSet (constructorLayouts layouts)) plans
        (parseSource "entry n = _ = str n; if n == 0 then (fn x -> x) else entry (n - 1)."))
      changedNative=right (Native.compileSelection PreserveCallbacks layouts changed)
      changedInput=right (R.prepare changedNative)
      original=right (R.prepare (native "borrow" "entry n = n + 1." (S.singleton "entry")))
      changedResult=right (R.place (R.Options True False) (R.context M.empty original) changedInput)
  check "changed compatibility clauses cannot borrow their old interface from a context"
    (M.null (Native.nativeDeclarations changedNative) && "entry" `M.notMember` R.programInterfaces changedInput
      && M.null (R.resultGenerated changedResult)
      && any (isInfixOf "no checked physical interface") (R.resultNotes changedResult))
  let scoped=qualifyPrivate "$scope." (S.singleton "entry") (M.fromList
        [("entry",([],CLet "lifted_1" (CVar "lifted_1") (CVar "lifted_1"))),
         ("lifted_1",(["x"],CVar "x"))])
  check "analysis qualification respects lexical shadowing"
    (M.lookup "entry" scoped==Just ([],CLet "lifted_1" (CVar "$scope.lifted_1") (CVar "lifted_1")))
  putStrLn "Region interfaces: checked physical binders/ownership, constructor models, generated ABI/provenance, scoped costs, declaration quarantine and argument limits passed"
