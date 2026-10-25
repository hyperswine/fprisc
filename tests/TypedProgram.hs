import qualified Core.Typed.Syntax as T
import qualified Core.Typed.Program as P
import Core.Typed.Pipeline
import Core.Typed.Callback
import Core.Typed.Close
import Core.Typed.Walk (mapChildrenM)
import Control.Monad.Identity (runIdentity)
import Core.Identity
import Core.Syntax
import qualified Compiler.Native.Core as Native
import qualified Compiler.Native.Linked as Linked
import Compiler.DataLayout
import Frontend.Desugar.Typed
import Frontend.Desugar (collectCons,collectShapes,DEnv(..))
import qualified Frontend.Desugar.Checked as Compat
import Control.Monad.State.Strict (evalState)
import Frontend.Parser (program)
import Frontend.Syntax
import Struct (sigTable,structTable,expandStructs)
import Infer
import Infer.Result
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import qualified Codegen.Lower as Lower
import qualified Codegen.Eval as Eval
import Codegen.Policy (m2Policy)
import Control.Monad (unless)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Text.Megaparsec (parse,errorBundlePretty)

check label ok=unless ok (error label)
right=either error id
failed (Left _)=True
failed _=False
int=TC "Int"
expr ty node=T.Expr ty (linShapeT [] ty) T.Generated Nothing node
binder ns i name ty=T.Binder (BinderId (Namespace ns) i) name (Forall [] [] ty) (linShapeT [] ty)
ref b=expr (T.binderType b) (T.Var (T.Local (T.binderId b)))
prepare ns source=
  let raw=right (either (Left . errorBundlePretty) Right (parse program "typed-program" source))
      (expansionErrors,tops)=expandStructs (sigTable raw) raw
      checked=inferTopsChecked (Namespace ns) aotProf (sigTable raw) (structTable raw) tops
  in if null expansionErrors && null (inferenceErrors checked) then (right (prepareChecked checked),inferenceTops checked)
     else error (show (inferenceErrors checked))
compile ns source names=
  let (plans,tops)=prepare ns source
      cons=collectCons "unit" tops
      selected=right (selectUnit (M.keysSet cons) (right (selectCheckedUnit plans names)))
      output=right (Native.compileSelection PreserveCallbacks (Layouts cons (collectShapes tops)) selected)
  in (selected,output)
answer p name args=let (ir,_)=Lower.lowerProgram m2Policy M.empty p p M.empty M.empty
                   in Eval.ocResult (Eval.evalProgram ir name args)

main=do
  let source="provider x = x. client n = local x = provider (n + x); local 2. factory x = fn y -> x + y. call n = (factory n) 1."
      names=S.fromList ["provider","client","factory","call"]
      (selected,output)=compile "unit" source names
      semantic=selectionProgram selected
      closed=Native.nativeClosed output
      erased=Native.nativeProgram output
  check "fully checked selections have no compatibility clauses"
    (M.null (selectionCompatibility selected) && M.null (Native.nativeCompatibility output))
  check "the source product verifies across definitions" (P.verifyProgram semantic==Right ())
  check "every semantic owner survives the native closed stage"
    (M.keysSet (closedDefinitions closed)==M.keysSet (P.programFunctions semantic)
      && verifyClosedProgram closed==Right ())
  check "all explicit code targets are emitted"
    (all (\code->let T.CodeId name=T.codeId code in name `M.member` erased)
      [c | f<-M.elems (closedDefinitions closed),c<-M.elems (closedCode f)])
  check "independent machine-IR evaluation crosses typed global and lexical calls"
    (answer erased "client" [Eval.RInt 10]==Right (Eval.RInt 12)
      && answer erased "call" [Eval.RInt 41]==Right (Eval.RInt 42))
  check "join metadata is owned by the emitted program" (Native.nativeJoins output `S.isSubsetOf` M.keysSet erased)
  let (consumerSelection,consumer)=compile "linked" source (S.fromList ["client","call"])
      (_,provider)=compile "linked" source (S.fromList ["provider","factory"])
      rootArtifact=right (Linked.artifact Linked.RootArtifact (S.fromList ["client","call"]<>Native.nativeConstructors consumer) S.empty consumer)
      providerId=Linked.DependencyArtifact "provider"
      providerArtifact=right (Linked.artifact providerId (S.fromList ["provider","factory"]) (Native.nativeConstructors provider) provider)
      linked=right (Linked.linkArtifacts [rootArtifact,providerArtifact])
      linkedProjection=M.unions [M.withoutKeys (Native.nativeProgram (Linked.artifactCore a)) (Linked.artifactElided a)
        | a<-M.elems (Linked.linkedArtifacts linked)]
      rejects needle (Left reason)=needle `isInfixOf` reason
      rejects _ _=False
  check "linked artifacts retain actual typed code owners/contracts"
    (M.size (Linked.linkedArtifacts linked)==2
      && case M.lookup (Linked.ExportedSymbol "provider") (Linked.linkedSymbols linked) of
        Just (Linked.SymbolOwner home (Linked.SourceDefinition "provider" _ 1))->home==providerId
        _->False)
  check "private code remains with its source artifact"
    (not (null [() | (Linked.ArtifactSymbol home _,Linked.SymbolOwner _ (Linked.PrivateDefinition "factory" _ _))
      <-M.toList (Linked.linkedSymbols linked),home==providerId]))
  check "independent machine evaluation links checked artifact projections"
    (answer linkedProjection "client" [Eval.RInt 10]==Right (Eval.RInt 12)
      && answer linkedProjection "call" [Eval.RInt 41]==Right (Eval.RInt 42))
  check "duplicate artifacts cannot be silently unioned"
    (rejects "duplicate artifact identity" (Linked.linkArtifacts [rootArtifact,rootArtifact]))
  check "elided constructor stubs require an emitted home"
    (rejects "elided definition has no emitting owner" (Linked.linkArtifacts [providerArtifact]))
  let hidden=right (Linked.artifact providerId S.empty (Native.nativeConstructors provider) provider)
  check "a caller cannot reach another artifact's unexported source definition"
    (rejects "cross-artifact reference to private symbol" (Linked.linkArtifacts [rootArtifact,hidden]))
  let duplicate=right (Linked.artifact (Linked.DependencyArtifact "duplicate") (S.fromList ["provider","factory"])
        (Native.nativeConstructors provider) provider)
      duplicatePrivate=right (Linked.artifact (Linked.DependencyArtifact "duplicate") S.empty
        (Native.nativeConstructors provider) provider)
  check "exported symbols cannot acquire two emitting owners"
    (rejects "symbol has more than one emitting artifact" (Linked.linkArtifacts [rootArtifact,providerArtifact,duplicate]))
  check "local symbol scope cannot hide duplicated typed binder identities"
    (rejects "binder identity shared by artifacts" (Linked.linkArtifacts [rootArtifact,providerArtifact,duplicatePrivate]))
  let (_,otherNamespace)=compile "another-run" source (S.fromList ["provider","factory"])
      otherArtifact=right (Linked.artifact providerId (S.fromList ["provider","factory"])
        (Native.nativeConstructors otherNamespace) otherNamespace)
      changedLayouts=(closedLayouts (Native.nativeClosed consumer)) {shapeLayouts=M.singleton ["unrelated"] 17}
      changedNative=right (Native.compileSelection PreserveCallbacks changedLayouts consumerSelection)
      changedArtifact=right (Linked.artifact Linked.RootArtifact (Linked.artifactExports rootArtifact) S.empty changedNative)
  check "linked artifacts must share the checking namespace"
    (rejects "different checking namespaces" (Linked.linkArtifacts [rootArtifact,otherArtifact]))
  check "layout authority remains attached across artifacts"
    (rejects "disagree on layout authority" (Linked.linkArtifacts [changedArtifact,providerArtifact]))
  check "exports cannot claim absent definitions"
    (rejects "export lacks an emitted definition" (Linked.artifact Linked.RootArtifact (S.singleton "absent") S.empty consumer))
  check "source functions cannot borrow constructor elision authority"
    (rejects "elision lacks generated constructor authority"
      (Linked.artifact Linked.RootArtifact S.empty (S.singleton "client") consumer))
  let (_,shadow)=compile "elision" "Box = Type Int. Box = Struct { value = 7 }." (S.fromList ["Box","Box.value"])
  check "a shadowing source value cannot be elided using its constructor's layout"
    (rejects "elision lacks generated constructor authority"
      (Linked.artifact Linked.RootArtifact S.empty (S.singleton "Box") shadow))
  let mismatch left rightSource=
        let (_,p)=compile "mismatch" left (S.singleton "provider")
            (_,c)=compile "mismatch" rightSource (S.singleton "client")
            a=right (Linked.artifact Linked.RootArtifact (S.insert "client" (Native.nativeConstructors c)) S.empty c)
            b=right (Linked.artifact providerId (S.singleton "provider") (Native.nativeConstructors p) p)
        in Linked.linkArtifacts [a,b]
  check "linking compares the provider's checked scheme with the imported declaration"
    (rejects "imported calling scheme disagrees at provider"
      (mismatch "provider = True." "provider = 1. client u = provider + u."))
  check "equal logical arrows cannot conceal a cross-artifact physical-arity mismatch"
    (rejects "imported physical arity disagrees at provider"
      (mismatch "provider x = fn y -> x + y." "provider x y = x + y. client u = provider u 1."))
  let (_,publicLocal)=compile "local-scope" "localValue = 1. result = localValue." (S.fromList ["localValue","result"])
      (_,privateLocal)=compile "local-scope" "localValue = 2." (S.singleton "localValue")
      publicArtifact=right (Linked.artifact Linked.RootArtifact (S.fromList ["localValue","result"]<>Native.nativeConstructors publicLocal) S.empty publicLocal)
      privateArtifact=right (Linked.artifact providerId S.empty (Native.nativeConstructors privateLocal) privateLocal)
      scopedSymbols=Linked.linkedSymbols (right (Linked.linkArtifacts [publicArtifact,privateArtifact]))
  check "artifact-local spellings do not shadow an exported symbol in another artifact"
    (M.member (Linked.ExportedSymbol "localValue") scopedSymbols
      && M.member (Linked.ArtifactSymbol providerId "localValue") scopedSymbols)
  let make functions schemas arities=P.program (Namespace "invalid") (T.TypeContext [] M.empty) schemas arities functions
      x=binder "x" 0 "x" int
      identity=T.Function "id" [x] (ref x)
      identitySchema=Forall [] [] (TFn int int)
      schemas=M.singleton "id" identitySchema
      arities=M.singleton "id" 1
      functions=M.singleton "id" identity
  check "a function cannot borrow another definition key"
    (failed (make (M.singleton "wrong" identity) schemas arities))
  check "an owned function cannot borrow a different physical arity"
    (failed (make functions schemas (M.singleton "id" 2)))
  check "an owned function requires its actual calling scheme"
    (failed (make functions M.empty arities)
      && failed (make functions (M.singleton "id" (Forall [] [] (TFn int (TC "Bool")))) arities))
  let second=identity {T.functionName="second"}
  check "distinct definitions cannot reuse a local binder identity"
    (failed (make (M.insert "second" second functions) (M.insert "second" identitySchema schemas) (M.insert "second" 1 arities)))
  let foreignType=TFn int int
      foreignRef=expr foreignType (T.Var (T.Global "foreign" (Forall [] [] foreignType)))
      caller=identity {T.functionBody=expr int (T.Apply foreignRef (ref x))}
  check "registered calling evidence must agree at a global reference"
    (failed (make (M.singleton "id" caller)
      (M.insert "foreign" (Forall [] [] (TFn (TC "Bool") (TC "Bool"))) schemas) arities))
  let y=binder "returning" 1 "y" int
      returning=T.Function "returning" [x] (expr (TFn int int) (T.Lambda [y] (ref x)))
      registry=M.fromList [("returning",Forall [] [] (TFn int (TFn int int))),("opaque-foreign",Forall [] [] (TFn int (TFn int int)))]
      returns=P.program (Namespace "returning") (T.TypeContext [] M.empty) registry
        (M.fromList [("returning",1),("opaque-foreign",0)]) (M.singleton "returning" returning)
  check "logical arrows cannot invent physical parameters or foreign arities"
    (not (failed returns) && verifyClosedProgram (right (closeProgram PreserveCallbacks (Layouts M.empty M.empty) (right returns)))==Right ())
  let stable ns extra=
        let (_,result)=compile ns (extra++"captured n = (fn x -> n + x) 2.") (S.singleton "captured")
            definition=closedDefinitions (Native.nativeClosed result) M.! "captured"
            own=S.fromList ("captured":[n | T.CodeId n<-M.keys (closedCode definition)])
        in M.restrictKeys (Native.nativeProgram result) own
  check "private code identity is independent of inference namespace and unrelated declarations"
    (stable "one" ""==stable "two" "Extra = Type Int. unrelated x = (x,True). ")
  let (plans,tops)=prepare "changed" "entry x = x + 1."
      cons=collectCons "unit" tops
      changed=right (selectClauses (M.keysSet cons) plans [TBind "entry" [PVar "x"] [] (SInt 7)])
      changedOutput=right (Native.compileSelection PreserveCallbacks (Layouts cons (collectShapes tops)) changed)
  check "changed compatibility clauses cannot reuse checked annotations"
    ("entry" `M.notMember` P.programFunctions (selectionProgram changed)
      && "entry" `M.member` Native.nativeCompatibility changedOutput
      && answer (Native.nativeProgram changedOutput) "entry" [Eval.RInt 99]==Right (Eval.RInt 7))
  let recursive="left : unsafe Int -> Int. right : unsafe Bool -> Int. left n = if n == 0 then 0 else right n. right b = left 0."
      (recSelected,recOutput)=compile "recursive" recursive (S.fromList ["left","right"])
      recProgram=selectionProgram recSelected
      assumptions=P.programAssumptions recProgram
      rebuild fs ledger=P.programWithAssumptions (P.programNamespace recProgram) (P.programTypes recProgram)
        (P.programSchemas recProgram) (P.programArities recProgram) fs ledger
      withoutOrigin e=let child=runIdentity (mapChildrenM (pure . withoutOrigin) e)
                      in case T.exprNode child of
                        T.Var (T.Global "right" _)->child {T.exprOrigin=T.Generated}
                        _->child
      noOrigin=M.adjust (\f->f {T.functionBody=withoutOrigin (T.functionBody f)}) "left" (P.programFunctions recProgram)
  check "signed recursive assumptions have an explicit source owner"
    (not (M.null assumptions) && verifyClosedProgram (Native.nativeClosed recOutput)==Right ()
      && answer (Native.nativeProgram recOutput) "left" [Eval.RInt 1]==Right (Eval.RInt 0))
  check "a recursive assumption cannot be replaced by ordinary global evidence"
    (failed (rebuild (P.programFunctions recProgram) M.empty))
  check "a generated reference cannot borrow a source recursion assumption"
    (failed (rebuild noOrigin assumptions))
  let brokenLedger=M.map (\entry->entry {P.assumptionExpression=ExprId (Namespace "wrong") 0}) assumptions
  check "an assumption cannot borrow another expression identity"
    (failed (rebuild (P.programFunctions recProgram) brokenLedger))
  let (compatPlans,compatTops)=prepare "shared" "first n = n + 1. second n = n + 2."
      compatCons=collectCons "unit" compatTops
      changed name op=[TBind name [PVar "n"] [] (SLam ["z"] (SBin op (SVar "n") (SVar "z")))]
      combined=evalState (do
        first<-Compat.compileTopChecked compatPlans (changed "first" "+")
        second<-Compat.compileTopChecked compatPlans (changed "second" "*")
        pure (Compat.desugaredCore first `M.union` Compat.desugaredCore second))
        (DEnv 0 compatCons (collectShapes compatTops) [] [])
      client name=([],CApp (CApp (CVar name) (CInt 3)) (CInt 4))
      clients=M.insert "callFirst" (client "first") (M.insert "callSecond" (client "second") combined)
  check "stateful compatibility calls cannot collide on private lifted code"
    (answer clients "callFirst" []==Right (Eval.RInt 7)
      && answer clients "callSecond" []==Right (Eval.RInt 12))
  let (_,shadow)=compile "shadow" "Box = Type Int. Box = Struct { value = 7 }. result u = Box.value + 1." (S.fromList ["Box","Box.value","result"])
  check "source values retain priority over constructor value stubs"
    (answer (Native.nativeProgram shadow) "result" [Eval.rvUnit]==Right (Eval.RInt 8))
  preludeSource<-readFile "core/prelude.fpr"
  let (preludePlans,preludeTops)=prepare "prelude-contracts" preludeSource
      preludeCons=collectCons "prelude" preludeTops
      preludeNames=S.fromList [n | TBind n _ _ _<-preludeTops]
      preludeSelection=right (selectUnit (M.keysSet preludeCons) (right (selectCheckedUnit preludePlans preludeNames)))
      preludeNative=right (Native.compileSelection SpecializeCallbacks (Layouts preludeCons (collectShapes preludeTops)) preludeSelection)
  check "the complete prelude closes and erases without compatibility lowering"
    (not (S.null preludeNames) && preludeNames `S.isSubsetOf` M.keysSet (P.programFunctions (selectionProgram preludeSelection))
      && M.null (Native.nativeCompatibility preludeNative)
      && verifyClosedProgram (Native.nativeClosed preludeNative)==Right ())
  let badLayouts=Layouts (M.adjust (\(tid,var,_)->(tid,var,1)) "Cons" (collectCons "unit" tops)) (collectShapes tops)
      ordinary=right (selectUnit (M.keysSet cons) (right (selectCheckedUnit plans (S.singleton "entry"))))
  check "erasure cannot accept a contradictory constructor layout"
    (failed (Native.compileSelection PreserveCallbacks badLayouts ordinary))
  putStrLn "Typed programs: owned schemas/physical arities, cross-definition identities, explicit compatibility, stable private code and independent native-IR answers passed"
