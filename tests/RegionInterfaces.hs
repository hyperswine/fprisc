import qualified Core.Region.CallSites as Sites
import qualified Core.Typed.Syntax as T
import Core.Typed.Callback (CallbackMode(..))
import qualified Core.Region.Types as V
import Core.Region.Interface
import qualified Core.Calling as Calling
import qualified Compiler.Native.Core as Native
import qualified Compiler.Native.Regions as R
import qualified Compiler.Native.Regions.Typed as Typed
import qualified Core.Region.Syntax as IR
import qualified Core.Typed.Verify as Verify
import Core.Typed.Walk (mapChildrenM)
import qualified Core.Typed.Erase as Erase
import Control.Monad.State.Strict (State,evalState,get,put)
import Ownership.Shape (LShape(..))
import Data.Functor.Const (Const(..))
import Data.Monoid (Sum(..))
import Core.Typed.Pipeline (closedInput)
import qualified Core.Typed.Program as Source
import qualified Compiler.Native.Linked as Linked
import qualified Compiler.Native.Imports as Imports
import Codegen.Target.Common (visibilityFor,Visibility(..))
import qualified Cost
import qualified ReceiveTurns as Turns
import Core.Analysis.Scope
import Core.Analysis.Alpha (sameFunction)
import qualified Core.Region.Receive as Receive
import qualified Core.Region.Flow as Flow
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
place input=right (R.place (R.Options True True True) (R.context M.empty input) input)
-- a QOS process image: receive loops keep the $receiveLoop trampoline
placeQos input=right (R.place (R.Options True True False) (R.context M.empty input) input)
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
  let typed=maybe (error "missing typed region product") id (R.resultTyped result)
      loopHelpers=M.restrictKeys (Typed.programFunctions typed) (M.keysSet (Typed.programHelpers typed))
  check "loop helpers own checked source bodies, fresh identities and internal control sorts"
    (not (M.null loopHelpers) && Typed.verifyProgram typed==Right () && all (\f->
      not (null (IR.functionBinderOrigins f)) && all (uncurry (/=)) (IR.functionBinderOrigins f)
      && case reverse (IR.functionParameters f) of
        IR.ControlParameter seqn:IR.ControlParameter mark:_->case (IR.controlType mark,IR.controlType seqn,IR.functionResult f) of
          (IR.Mark,IR.Sequence,IR.ValueResult t)->t==int
          _->False
        _->False) (M.elems loopHelpers))
  check "a source result cannot be relabeled as an existential receive step"
    (failed (Typed.rewriteHelpers (\f->Right f {IR.functionResult=IR.ReceiveStep int}) typed))
  check "a loop helper cannot replace its mark by a sequence cell"
    (failed (Typed.rewriteHelpers (\f->Right f {IR.functionParameters=map (\p->case p of
      IR.ControlParameter c->case IR.controlType c of
        IR.Mark->IR.ControlParameter (c {IR.controlType=IR.Sequence})
        _->p
      _->p) (IR.functionParameters f)}) typed))
  let artifact=right (Linked.artifact Linked.RootArtifact (S.insert "counter" (Native.nativeConstructors compiled)) S.empty compiled)
      linked=right (Linked.linkArtifacts [artifact])
      declarations=right (Imports.withRegions (M.singleton Linked.RootArtifact typed) (right (Imports.codeDeclarations linked)))
      ready=right (Imports.prepareEmission declarations Linked.RootArtifact (Linked.artifactExports artifact) (R.resultProgram result))
  check "typed protocol helpers publish strong hidden code/PAP home declarations"
    (all (\name->name `S.member` Imports.preservedCode declarations Linked.RootArtifact
      && visibilityFor True (Imports.readySymbols ready) name==HiddenSymbol) (M.keys loopHelpers))
  let receiveNative=native "receive-protocol" "turn me unused n = _ = receiveFrom me me; if n == 0 then 0 else turn me unused (n - 1)." (S.singleton "turn")
      receiveResult=placeQos (right (R.prepare receiveNative))
      receiveTyped=maybe (error "missing typed receive product") id (R.resultTyped receiveResult)
      thunks=[f | f<-M.elems (Typed.programFunctions receiveTyped),IR.ReceiveThunk {}<-[IR.functionBody f]]
  check "receive helpers distinguish state/tick cells and dead polymorphic logical slots"
    (not (null thunks) && all (\f->length (IR.functionParameters f)==2
      && case (IR.functionResult f,IR.functionBody f) of
        (IR.ReceiveStep t,IR.ReceiveThunk state tick slots _)->t==int
          && (case (IR.controlType state,IR.controlType tick) of (IR.State fields,IR.Tick)->length fields==2;_->False)
          && any (\s->case s of
            IR.DeadSlot b->case T.binderType b of TV _->True;_->False
            _->False) slots
        _->False) thunks)
  -- hosted: the same loop takes the loop form, its region opened at entry
  -- (docs/2026-10-26-RECEIVE-TURNS-PER-SLAB.md)
  let hostedTyped=maybe (error "missing hosted receive product") id (R.resultTyped (place (right (R.prepare receiveNative))))
      hostedBodies=map IR.functionBody (M.elems (Typed.programFunctions hostedTyped))
  check "a hosted receive loop opens its region at entry and has no trampoline helper"
    (not (null [() | IR.LoopEntry True _ _ _ _<-hostedBodies])
      && null [() | IR.LoopEntry False _ _ _ _<-hostedBodies]
      && not (null [() | IR.LoopInner (Just _) _ _ _ _<-hostedBodies])
      && null [() | IR.ReceiveThunk {}<-hostedBodies] && null [() | IR.ReceiveEntry {}<-hostedBodies])
  check "a leading selective receive records its checked sender slot"
    (not (null [() | IR.LoopInner (Just (IR.ReceiveBoundary _ (IR.SenderMessage 0))) _ _ _ _<-hostedBodies]))
  check "readiness metadata cannot be forged into a nonblocking poll"
    (failed (Typed.rewriteHelpers (\f->case IR.functionBody f of
      IR.LoopInner (Just (IR.ReceiveBoundary label _)) ps mark seqn flow->
        Right f {IR.functionBody=IR.LoopInner (Just (IR.ReceiveBoundary label IR.NonBlocking)) ps mark seqn flow}
      _->Right f) hostedTyped))
  check "a receive boundary cannot silently lose its gate"
    (failed (Typed.rewriteHelpers (\f->case IR.functionBody f of
      IR.LoopInner (Just _) ps mark seqn flow->Right f {IR.functionBody=IR.LoopInner Nothing ps mark seqn flow}
      _->Right f) hostedTyped))
  let call name args=foldl CApp (CVar name) args
  check "compatibility probes preserve selective aliases and lexical shadowing"
    (Receive.coreProbe ["me","peer"] (CLet "sender" (CVar "peer") (call "receiveFrom" [CVar "me",CVar "sender"]))==IR.SenderMessage 1
      && Receive.coreProbe ["receive","me"] (call "receive" [CVar "me"])==IR.UnknownReceive)
  check "effectful senders and prefixes are not evaluated by a readiness probe"
    (Receive.coreProbe ["me","peer"] (call "receiveFrom" [CVar "me",call "effect" [CVar "peer"]])==IR.UnknownReceive
      && Receive.coreProbe ["me"] (CLet "ignored" (call "send" [CVar "me",CInt 0]) (call "receive" [CVar "me"]))==IR.UnknownReceive)
  check "polls are distinct from blocking receive probes"
    (Receive.coreProbe ["me"] (call "receiveNow" [CVar "me"])==IR.NonBlocking
      && Receive.coreProbe ["me"] (call "receiveRes" [CVar "me"])==IR.ResultMessage
      && Receive.coreProbe ["me","peer"] (call "receiveFromRes" [CVar "me",CVar "peer"])==IR.SenderMessageOrDead 1)
  check "receive bundle declarations cannot invent a field"
    (failed (Typed.rewriteHelpers (\f->case IR.functionBody f of
      IR.ReceiveThunk state tick slots flow->let wrong=state {IR.controlType=IR.State []}
        in Right f {IR.functionBody=IR.ReceiveThunk wrong tick slots flow}
      _->Right f) receiveTyped))
  check "physical receive cells must agree with the logical bundle declaration"
    (failed (Typed.rewriteHelpers (\f->Right f {IR.functionParameters=map (\p->case p of
      IR.ControlParameter c->case IR.controlType c of
        IR.State _->IR.ControlParameter (c {IR.controlType=IR.State []})
        _->p
      _->p) (IR.functionParameters f)}) receiveTyped))
  let typedDeadNative=native "typed-dead" "turn : Int -> Int -> Int -> Int. turn me unused n = _ = receiveFrom me me; if n == 0 then 0 else turn me unused (n - 1)." (S.singleton "turn")
      typedDead=maybe (error "missing dead-slot product") id (R.resultTyped (placeQos (right (R.prepare typedDeadNative))))
      readDead f=case IR.functionBody f of
        IR.ReceiveThunk state tick slots _->case [b | IR.DeadSlot b<-slots] of
          b:_->let value=T.Expr (T.binderType b) (T.binderShape b) T.Generated Nothing (T.Var (T.Local (T.binderId b)))
               in Right f {IR.functionBody=IR.ReceiveThunk state tick slots (IR.Value value)}
          _->error "missing erased slot"
        _->Right f
  check "a later helper pass cannot make an erased logical slot observable"
    (case Typed.rewriteHelpers readDead typedDead of
      Left reason->"dead argument became observable" `isInfixOf` reason
      Right _->False)
  let invariantNative=native "invariant-proof" "spin : Int -> Int -> Int. spin n stable = _ = str n; if n == 0 then stable else spin (n - 1) stable." (S.singleton "spin")
      invariantTyped=maybe (error "missing invariant product") id (R.resultTyped (place (right (R.prepare invariantNative))))
      invalidate f=case IR.functionBody f of
        IR.LoopInner cold ps mark seqn flow->case (ps,Flow.tailCalls flow) of
          ([n,stable],old:_)->do
            let ref b=T.Expr (T.binderType b) (T.binderShape b) T.Generated Nothing (T.Var (T.Local (T.binderId b)))
                expr ty node=T.Expr ty LU T.Generated Nothing node
                apply f a=case T.exprType f of TFn _ result->expr result (T.Apply f a);_->error "test arrow"
                binary n=expr (TFn int (TFn int int)) (T.Var (T.Global n (Forall [] [] (TFn int (TFn int int)))))
                changed=apply (apply (binary "+") (ref stable)) (expr int (T.IntValue 1))
                witness=apply (apply (binary "spin") (ref n)) changed
                scratch=apply (expr (TFn int (TC "String")) (T.Var (T.Global "str" (Forall [] [] (TFn int (TC "String")))))) (ref n)
            call<-IR.makeCall (Flow.scope (IR.functionSource f)) (IR.callRoute old) witness
            Right f {IR.functionBody=IR.LoopInner cold ps mark seqn (IR.Then scratch (IR.Tail call))}
          _->error "missing invariant tail"
        _->Right f
  check "a later helper pass cannot weaken a retained invariant-state proof"
    (case Typed.rewriteHelpers invalidate invariantTyped of
      Left reason->"loop-invariant argument proof changed" `isInfixOf` reason
      Right _->False)
  let noted=right (Typed.rewriteHelpers (\f->Right f {IR.functionBody=case IR.functionBody f of
        IR.LoopInner cold ps mark seqn flow->IR.LoopInner cold ps mark seqn (IR.Note flow)
        IR.ReceiveThunk state tick slots flow->IR.ReceiveThunk state tick slots (IR.Note flow)
        IR.ReceiveLocal flow->IR.ReceiveLocal (IR.Note flow)
        body->body}) receiveTyped)
  check "a source-equivalent helper pass retains the proof and exact emission"
    (Typed.emitProgram noted==Typed.emitProgram receiveTyped)
  check "a helper control cell cannot capture a protocol symbol"
    (failed (Typed.rewriteHelpers (\f->case IR.functionBody f of
      IR.LoopInner cold ps mark seqn flow->let wrong=mark {IR.controlName=IR.functionLabel f}
        in Right f {IR.functionBody=IR.LoopInner cold ps wrong seqn flow,
          IR.functionParameters=map (\p->case p of
            IR.ControlParameter c | IR.controlId c==IR.controlId mark->IR.ControlParameter wrong
            _->p) (IR.functionParameters f)}
      _->Right f) typed))
  check "a physical tick cell cannot shadow a language-level callee"
    (failed (Typed.rewriteHelpers (\f->case IR.functionBody f of
      IR.ReceiveThunk state tick slots flow->let wrong=tick {IR.controlName="receiveFrom"}
        in Right f {IR.functionBody=IR.ReceiveThunk state wrong slots flow,
          IR.functionParameters=map (\p->case p of
            IR.ControlParameter c | IR.controlId c==IR.controlId tick->IR.ControlParameter wrong
            _->p) (IR.functionParameters f)}
      _->Right f) receiveTyped))
  let callNative=native "call-protocol" "build n = if n == 0 then \"done\" else strcat (str n) (build (n - 1)). client n = build n." (S.fromList ["build","client"])
      callResult=place (right (R.prepare callNative))
      callTyped=maybe (error "missing typed call product") id (R.resultTyped callResult)
      calls=T.functionBody (IR.functionSource (Typed.programFunctions callTyped M.! "client"))
      regionCount e=(case T.exprNode e of T.CallRegion _->1;_->0)+getSum (getConst (mapChildrenM (Const . Sum . regionCount) e))
  check "call regions retain checked operands and notes do not duplicate a saturated call"
    (regionCount calls==1 && any (isInfixOf "client: 1 call(s)") (R.resultNotes callResult))
  let badBody=T.Expr fn LU T.Generated Nothing (T.Var (T.Global "f" (Forall [] [] fn)))
      badCall=T.Expr fn LU T.Generated Nothing (T.CallRegion badBody)
  check "call region verifier refuses function-valued results"
    (failed (Verify.verifyFunction (T.TypeContext [] M.empty) (T.Function "bad-region" [] badCall)))
  let identifier=BinderId (Namespace "protocol-shadow") 0
      parameter name=T.Binder identifier name (Forall [] [] int) LU
      arg name=T.Expr int LU T.Generated Nothing (T.Var (T.Local identifier))
      code=T.CodeId "worker"
      codeContract=T.CodeContract T.EntryCode ([],[]) [] [int] int
      invocation=T.Expr int LU T.Generated Nothing (T.CodeCall code [] [arg "worker"])
      codeShadow=T.Function "code-shadow" [parameter "worker"] invocation
      fresh :: String -> State Int String
      fresh prefix=do n<-get;put (n+1);pure (prefix++show n)
      layout=Erase.Layout fresh (const Nothing) M.empty (\_ _ _->pure ())
      contracts=M.singleton code codeContract
  check "logical code identities survive even when display names would shadow them"
    (Verify.verifyFunctionWith contracts (T.TypeContext [] M.empty) codeShadow==Right ()
      && failed (evalState (Erase.eraseFunctionWith contracts (T.TypeContext [] M.empty) layout codeShadow) 0))
  let value=T.Expr int LU T.Generated Nothing (T.IntValue 7)
      regionShadow=T.Function "region-shadow" [parameter "$callPend"]
        (T.Expr int LU T.Generated Nothing (T.CallRegion value))
  check "erasure cannot shadow an internal runtime region operation"
    (failed (evalState (Erase.eraseFunction (T.TypeContext [] M.empty) layout regionShadow) 0))
  let planProg=R.programCore input
      modelInput=right (V.valueModel (Source.programTypes (closedInput (Native.nativeClosed compiled))))
      plan=right (Turns.receiveTurns True True True (Cost.costProgram M.empty M.empty planProg)
        (R.programInterfaces input) modelInput (Sites.compatibilitySites (M.keysSet planProg)) (M.keysSet (R.programInterfaces input)) planProg (Native.nativeJoins compiled) planProg)
      changedParent=native "physical" "counter n = loop = (fn k -> _ = str k; if k == 0 then 0 else loop (k - 2)); loop n." (S.singleton "counter")
      projected=right (Typed.emitProgram typed)
      legacy=Turns.rewriteProgram plan
  check "typed loop lowering agrees with the existing independent representation oracle"
    (M.keysSet projected==M.keysSet legacy && and [sameFunction row (projected M.! name) | (name,row)<-M.toList legacy])
  check "region decisions cannot borrow a different checked body's projection"
    (failed (Typed.build changedParent (M.map interfaceArity (R.programInterfaces input)) plan))
  let other=right (R.prepare (native "other" body (S.singleton "counter")))
  check "a region context cannot borrow a different checking namespace"
    (failed (R.place (R.Options True True True) (R.context M.empty input) other))
  let (physicalPlans,physicalTops)=prepareSource "physical" body
      physicalLayouts=Layouts (collectCons "unit" physicalTops) (collectShapes physicalTops)
      physicalSelection=right (selectUnit (M.keysSet (constructorLayouts physicalLayouts))
        (right (selectCheckedUnit physicalPlans (S.singleton "counter"))))
      changedLayouts=physicalLayouts {shapeLayouts=M.singleton ["unrelated"] 99}
      changedLayoutInput=right (R.prepare (right (Native.compileSelection PreserveCallbacks changedLayouts physicalSelection)))
  check "a region context cannot borrow a different physical layout authority"
    (failed (R.place (R.Options True True True) (R.context M.empty input) changedLayoutInput))
  let collisionName="$loop.in."++fst (head private)
      collisionSelection=right (selectClauses (M.keysSet (constructorLayouts physicalLayouts)) physicalPlans
        (physicalTops++[TBind collisionName [] [] (SInt 7)]))
      collisionInput=right (R.prepare (right (Native.compileSelection PreserveCallbacks physicalLayouts collisionSelection)))
  check "generated region names cannot silently overwrite an input definition"
    (case R.place (R.Options True False True) (R.context M.empty collisionInput) collisionInput of
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
      scopeResult=right (R.place (R.Options True True True) (R.context M.empty a) b)
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
      changedResult=right (R.place (R.Options True False True) (R.context M.empty original) changedInput)
  check "changed compatibility clauses cannot borrow their old interface from a context"
    (M.null (Native.nativeDeclarations changedNative) && "entry" `M.notMember` R.programInterfaces changedInput
      && M.null (R.resultGenerated changedResult)
      && any (isInfixOf "no checked physical interface") (R.resultNotes changedResult))
  let scoped=qualifyPrivate "$scope." (S.singleton "entry") (M.fromList
        [("entry",([],CLet "lifted_1" (CVar "lifted_1") (CVar "lifted_1"))),
         ("lifted_1",(["x"],CVar "x"))])
  check "analysis qualification respects lexical shadowing"
    (M.lookup "entry" scoped==Just ([],CLet "lifted_1" (CVar "$scope.lifted_1") (CVar "lifted_1")))
  let batch=right (R.placePrograms (R.Options True True True) M.empty (M.fromList [("left",a),("right",b)]))
      views=[view | result<-M.elems batch,Just view<-[R.resultAnalysis result]]
  check "post-linked artifacts share the complete scoped cost snapshot"
    (length views==2 && all (\view->length (filter (isSuffixOf "lifted_1") (M.keys (R.analysisProgram view)))==2) views
      && all (\view->R.analysisProgram view==R.analysisProgram (head views)
        && R.analysisCosts view==R.analysisCosts (head views)) views)
  check "shared equations equal an independent solve over the exact snapshot"
    (all (\view->R.analysisCosts view==Cost.costProgram M.empty M.empty (R.analysisProgram view)) views)
  check "batch analysis rejects foreign namespaces and layout authorities"
    (failed (R.placePrograms (R.Options True True True) M.empty (M.fromList [(0::Int,input),(1,other)]))
      && failed (R.placePrograms (R.Options True True True) M.empty (M.fromList [(0::Int,input),(1,changedLayoutInput)])))
  let leftBody=right (R.prepare (native "ambiguous" "entry n = n + 1." (S.singleton "entry")))
      rightBody=right (R.prepare (native "ambiguous" "entry n = n + 2." (S.singleton "entry")))
  check "conflicting public snapshots cannot silently overwrite one another"
    (case R.placePrograms (R.Options True True True) M.empty (M.fromList [(0::Int,leftBody),(1,rightBody)]) of
      Left reason->"conflicting post-linked definition entry" `isInfixOf` reason
      Right _->False)
  let duplicates=right (R.placePrograms (R.Options True True True) M.empty (M.fromList [(0::Int,input),(1,input)]))
  check "identical visible definitions and empty batches remain valid"
    (M.size duplicates==2 && case R.placePrograms (R.Options True True True) M.empty (M.empty::M.Map Int R.Program) of
      Right results->M.null results;_->False)
  putStrLn "Region interfaces/control: checked physical binders, protocol sorts, fresh identities, state proofs, source-equivalent lowering, home declarations, scope refusals and compatibility quarantine passed"
