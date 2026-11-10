import qualified Core.Typed.Syntax as T
import TypedInline (checkInlining)
import TypedVectorRead (checkVectorReads)
import TypedNormalize (checkNormalization)
import TypedFusion (checkFusion)
import qualified Core.Typed.Program as P
import qualified Core.Typed.Erase as Erase
import Core.Typed.Pipeline
import Core.Typed.Callback
import Core.Typed.Close
import Core.Typed.Walk (mapChildrenM)
import Control.Monad.Identity (runIdentity)
import Core.Identity
import Core.Syntax
import qualified Compiler.Native.Core as Native
import qualified Compiler.Native.Linked as Linked
import qualified Compiler.Native.Imports as Imports
import qualified Compiler.Native.Regions as Regions
import Core.Region.Interface (interfaceCloneOrigin)
import Codegen.Target.Common (visibilityFor,Visibility(..))
import Compiler.DataLayout
import Frontend.Desugar.Typed
import Frontend.Desugar (collectCons,collectShapes,DEnv(..))
import qualified Frontend.Desugar.Checked as Compat
import Control.Monad.State.Strict (evalState,get,put)
import Frontend.Parser (program)
import Frontend.Syntax
import Struct (sigTable,structTable,expandStructs)
import Infer
import Infer.Result
import qualified Compiler.Native.Representation as NativeRep
import qualified Representation.Types as Rep
import qualified Arc
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import qualified Codegen.Lower as Lower
import qualified Codegen.Eval as Eval
import qualified Cost
import ResourceCosts (checkResourceCosts)
import qualified Resource.ResultSize as Sizes
import qualified Safety
import Codegen.Policy (m2Policy)
import Control.Monad (unless)
import Data.List (isInfixOf)
import Data.Functor.Const (Const(..))
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

checkTypeInstanceContracts=do
  let keeping admitted ns src names=
        let (selection,plain)=compile ns src names
        in right (Native.compileSelectionTypeSpecializedKeepingEntries admitted S.empty PreserveCallbacks
          (closedLayouts (Native.nativeClosed plain)) selection)
      scalarSource="identity x = x. integer : Int -> Int. integer x = identity x. boolean : Bool -> Bool. boolean x = identity x."
      scalarNames=S.fromList ["identity","integer","boolean"]
      (_,plain)=compile "admission" scalarSource scalarNames
      declined=keeping (const False) "admission" scalarSource scalarNames
      selected=keeping (==TFn int int) "admission" scalarSource scalarNames
  check "representation admission can retain the exact generic program without clones"
    (Native.nativeProgram declined==Native.nativeProgram plain && M.null (Native.nativeTypeInstances declined))
  check "representation admission selects complete types independently and keeps other callers generic"
    (M.elems (Native.nativeTypeInstances selected)==["identity"]
      && answer (Native.nativeProgram selected) "integer" [Eval.RInt 17]==Right (Eval.RInt 17)
      && answer (Native.nativeProgram selected) "boolean" [Eval.RObj 1 1 []]==Right (Eval.RObj 1 1 []))
  let source identity=identity++" inc x = x + 1. produce : (Int -> Int) -> Int -> Int. produce f x = identity (f x). caller n = produce inc n."
      src=source "identity x = x."
      providerNames=S.fromList ["identity","produce"]
      consumerNames=S.fromList ["inc","caller"]
      provider=keeping (const True) "type-instance-import" src providerNames
      consumer=keeping (const True) "type-instance-import" src consumerNames
      home=Linked.DependencyArtifact "type-instance-home"
      makeHome core=right (Linked.artifact home providerNames (Native.nativeConstructors core) core)
      rootNames=consumerNames<>Native.nativeConstructors consumer
      root=right (Linked.artifact Linked.RootArtifact rootNames S.empty consumer)
      firstLinked=right (Linked.linkArtifacts [root,makeHome provider])
      linked=either (error . ("type-instance callback link: "++)) id (Linked.specializeLinked SpecializeCallbacks firstLinked)
      rootArtifact=Linked.linkedArtifacts linked M.! Linked.RootArtifact
      rootCore=Linked.artifactCore rootArtifact
      instanceName=head (M.keys (Native.nativeTypeInstances provider))
      declarations=right (Imports.codeDeclarations linked)
      prepared=right (Imports.prepareEmission declarations Linked.RootArtifact consumerNames (Native.nativeProgram rootCore))
      homeProgram=M.withoutKeys (Native.nativeProgram provider) (Native.nativeConstructors provider)
      homeReady=right (Imports.prepareEmission declarations home providerNames homeProgram)
      rejects needle (Left why)=needle `isInfixOf` why
      rejects _ _=False
  check "callback clones keep a private type instance at its home with its checked import contract"
    (case M.lookup instanceName (Imports.readyImports prepared) of
      Just d->Imports.declarationHome d==home && Imports.declarationSource d=="identity"
        && Imports.declarationArity d==1
        && M.lookup instanceName (Native.nativeTypeInstances rootCore)==Just "identity"
        && instanceName `M.notMember` Imports.readyProgram prepared
      _->False)
  check "private typed instances have hidden home visibility and execute through copied callbacks"
    (visibilityFor True (Imports.readySymbols homeReady) instanceName==HiddenSymbol
      && answer (Imports.readyProgram prepared `M.union` homeProgram) "caller" [Eval.RInt 41]==Right (Eval.RInt 42))
  check "emission refuses missing, copied and wrong-arity type instances"
    (rejects "home private definition is absent" (Imports.prepareEmission declarations home providerNames (M.delete instanceName homeProgram))
      && rejects "copied away from its home" (Imports.prepareEmission declarations Linked.RootArtifact consumerNames
          (M.insert instanceName (homeProgram M.! instanceName) (Native.nativeProgram rootCore)))
      && rejects "private physical arity changed" (Imports.prepareEmission declarations home providerNames
          (M.adjust (\(ps,b)->(drop 1 ps,b)) instanceName homeProgram)))
  let (_,withoutInstance)=compile "type-instance-import" src providerNames
      changedArity=keeping (const True) "type-instance-import" (source "identity = fn x -> x.") providerNames
  check "a copied type-instance reference cannot silently become a runtime external when its home disappears"
    (rejects "type instance has no unique emitting home" (Linked.linkArtifacts [rootArtifact,makeHome withoutInstance]))
  check "the same complete type does not excuse a changed physical home arity"
    (rejects "imported type-instance arity disagrees" (Linked.linkArtifacts [rootArtifact,makeHome changedArity]))
  let measuredSource="down : (n : Int | measure n) -> a -> a. down n x = if n <= 0 then x else down (n - 1) x. run : Int -> Int. run n = down n 7."
      (_,measuredTops)=prepare "type-measure" measuredSource
      (measures,errors)=Safety.measureCheck measuredTops
      measured=keeping (const True) "type-measure" measuredSource (S.fromList ["down","run"])
      program=right (Regions.prepare measured)
      result ms=right (Regions.place (Regions.Options False False False)
        (Regions.context (Regions.typeInstanceMeasures ms [program]) program) program)
      view ms=case Regions.resultAnalysis (result ms) of Just a->a;_->error "missing region cost view"
      derived=view measures
      independent=measures `M.union` M.fromList
        [(n,m {Safety.mFn=n}) | (n,origin)<-M.toList (Native.nativeTypeInstances measured),Just m<-[M.lookup origin measures]]
      expected=Cost.costProgram independent M.empty (Regions.analysisProgram derived)
      instanceOfDown=head [n | (n,"down")<-M.toList (Native.nativeTypeInstances measured)]
      work ms=Cost.ceWork (fst (Regions.analysisCosts (view ms) M.! instanceOfDown))
  check "verified source descent survives typed instantiation in region costing"
    (null errors && not (M.null measures) && Regions.analysisCosts derived==expected
      && not (Cost.hasOmega (work measures)) && Cost.hasOmega (work M.empty))
  let batch=right (Regions.placePrograms (Regions.Options False False False)
        (Regions.typeInstanceMeasures measures [program]) (M.singleton (0::Int) program))
  check "batch region placement uses the same inherited verified measure"
    (case Regions.resultAnalysis (batch M.! 0) of Just a->Regions.analysisCosts a==expected;_->False)

checkResultSizes=do
  let source=unlines
        [ "rev : (xs : List a | measure xs) -> List a -> List a."
        , "rev xs acc = case xs of [] -> acc | x :: r -> rev r (x :: acc)."
        , "reverse xs = rev xs []."
        , "mapGo : (a -> b) -> (xs : List a | measure xs) -> List b -> List b."
        , "mapGo f xs acc = case xs of [] -> reverse acc | x :: r -> mapGo f r (f x :: acc)."
        , "map f xs = mapGo f xs []."
        , "direct : (a -> b) -> (xs : List a | measure xs) -> List b."
        , "direct f xs = case xs of [] -> [] | x :: r -> f x :: direct f r."
        , "repeatGo : (n : Int | measure n) -> a -> List a -> List a."
        , "repeatGo n x acc = if n <= 0 then acc else repeatGo (n - 1) x (x :: acc)."
        , "repeat n x = repeatGo n x []."
        , "rangeGo : (a : Int) -> (b : Int | measure (b - a)) -> List Int -> List Int."
        , "rangeGo a b acc = if b < a then acc else rangeGo a (b - 1) (b :: acc)."
        , "range a b = rangeGo a b []."
        , "duplicate : (xs : List a | measure xs) -> List a."
        , "duplicate xs = case xs of [] -> [] | x :: r -> x :: x :: duplicate r."
        , "inner : List (List Int) -> List Int."
        , "inner xs = case xs of [] -> [] | x :: _ -> x."
        , "unicode = \"éλ🙂\"."
        , "cat x = strcat x \"éλ🙂\"."
        , "sorted : (a -> a -> b) -> List a -> List a."
        , "sorted cmp xs = sortListWith cmp xs."
        ]
      names=S.fromList ["rev","reverse","mapGo","map","direct","repeatGo","repeat","rangeGo","range","duplicate","inner","unicode","cat","sorted"]
      (_,native)=compile "result-sizes" source names
      (_,tops)=prepare "result-sizes" source
      (measures,errors)=Safety.measureCheck tops
      defs=M.map Native.checkedFunction (Native.nativeDefinitions native)
      prog=Native.nativeProgram native
      firstParam n=T.binderName (head (T.functionParameters (defs M.! n)))
      badCandidate=M.singleton "duplicate" (Cost.CLen (firstParam "duplicate"))
      bounds=Sizes.verifiedBounds (Sizes.proveSizes measures badCandidate native)
      at name values lengths=do
        bound<-M.lookup name bounds
        (ps,_)<-M.lookup name prog
        Cost.evalConst (Cost.substituteCost (M.fromList (zip ps (map Cost.CN values)))
          (M.fromList (zip ps (map Cost.CN lengths))) bound)
      require name=check ("missing result size: "++name++"; "++show bounds) (M.member name bounds)
  check "result-size fixture measures verified" (null errors)
  mapM_ require ["rev","reverse","mapGo","map","direct","repeatGo","repeat","rangeGo","range","unicode","cat","sorted"]
  check "accumulator and direct maps preserve structural size"
    (at "rev" [] [4,3]==Just 7 && at "map" [] [0,4]==Just 4 && at "direct" [] [0,4]==Just 4)
  check "repeat size clamps negative inputs and retains accumulator size"
    (at "repeatGo" [-4,0,0] [0,0,3]==Just 3 && at "repeat" [5,0] []==Just 5)
  check "inclusive range size preserves empty and singleton endpoints"
    (at "range" [4,2] []==Just 0 && at "range" [3,3] []==Just 1 && at "range" [2,6] []==Just 5)
  check "candidate invariant is not assumed for a doubling traversal"
    (M.notMember "duplicate" bounds)
  check "outer list length cannot bound its unknown element list"
    (M.notMember "inner" bounds)
  check "String sizes count UTF-8 bytes"
    (at "unicode" [] []==Just 8 && at "cat" [] [5]==Just 13)
  check "the runtime sort returns a permutation of its list"
    (at "sorted" [] [0,0]==Just 0 && at "sorted" [] [0,7]==Just 7)
  let twice=M.singleton "duplicate" (Cost.CMul [Cost.CN 2,Cost.CLen (firstParam "duplicate")])
      twiceBounds=Sizes.verifiedBounds (Sizes.proveSizes measures twice native)
  check "independently preserved non-unit slope can be proved"
    (M.member "duplicate" twiceBounds)
  putStrLn "Result sizes: typed list patterns, accumulator/direct induction, signed repeat/range, UTF-8 bytes, the runtime sort and false-invariant refusals passed"

checkRecordUpdateLayouts=do
  let source="set : Int -> {x : Int} -> {x : Int}. set n p = {p | x = n}. "
        ++"nested : Int -> {inner : {x : Int}} -> {inner : {x : Int}}. nested n p = {p | inner.x = n}. "
        ++"openSet : Int -> {x : Int | r} -> {x : Int | r}. openSet n p = {p | x = n}. "
        ++"other = {inner={tag=3,x=2},keep=4}. run n = a=set n {x=1}; b=nested n {inner={x=2}}; a.x+b.inner.x. "
        ++"runOpen n = a=openSet n {x=1}; b=openSet n {tag=4,x=2}; a.x+b.x."
      (_,native)=compile "record-update-layouts" source (S.fromList ["set","nested","openSet","other","run","runOpen"])
      plans e=(case T.exprNode e of T.PlannedUpdate _ p->widths p;_->[])
        ++getConst (mapChildrenM (Const . plans) e)
      widths (T.UpdatePlan _ alternatives)=length alternatives:
        concat [widths child | T.UpdateBranch _ fields<-alternatives,(_,T.NestedUpdate child)<-fields]
      selected name=plans (T.functionBody (Native.checkedFunction (Native.nativeDefinitions native M.! name)))
  check "closed record updates choose their checked shape, including nested fields"
    (selected "set"==[1] && selected "nested"==[1,1])
  check "open record updates retain every extending shape"
    (selected "openSet"==[2])
  check "checked update planning preserves independently evaluated values"
    (answer (Native.nativeProgram native) "run" [Eval.RInt 17]==Right (Eval.RInt 34))
  let inlined=right (Native.inlineNativePrograms 3 24 64 (M.singleton () (S.empty,S.empty,native))) M.! ()
  check "inlined open-row updates retain coverage after their types close"
    (answer (Native.nativeProgram inlined) "runOpen" [Eval.RInt 17]==Right (Eval.RInt 34))
  let physical=closedLayouts (Native.nativeClosed native)
      types=P.programTypes (closedInput (Native.nativeClosed native))
      fresh prefix=do n<-get;put (n+1);pure (prefix++show (n::Int))
      layout=Erase.Layout fresh (`M.lookup` constructorLayouts physical) (shapeLayouts physical) (\_ _ _->pure ())
      modifyPlan change e=let child=runIdentity (mapChildrenM (pure . modifyPlan change) e) in
        child {T.exprNode=case T.exprNode child of
          T.PlannedUpdate base plan->T.PlannedUpdate base (change plan)
          node->node}
      refusedPlan name change=
        let fn=Native.checkedFunction (Native.nativeDefinitions native M.! name)
            corrupted=fn {T.functionBody=modifyPlan change (T.functionBody fn)}
        in case evalState (Erase.eraseFunction types layout corrupted) 0 of
          Left why->"stale record update plan" `isInfixOf` why
          _->False
  check "erasure refuses a missing admissible row shape or foreign nominal layout"
    (refusedPlan "openSet" (\(T.UpdatePlan roots branches)->T.UpdatePlan roots (drop 1 branches))
      && refusedPlan "set" (\(T.UpdatePlan roots branches)->T.UpdatePlan roots
        [T.UpdateBranch (tid+1) fields | T.UpdateBranch tid fields<-branches]))

main=do
  checkRecordUpdateLayouts
  checkResourceCosts
  checkResultSizes
  checkTypeInstanceContracts
  let (baseSelection,basePlain)=compile "base-type-specialization"
        "identity x = x. integer : Int -> Int. integer n = identity n. boolean : Bool -> Bool. boolean b = identity b."
        (S.fromList ["identity","integer","boolean"])
      specialized=right (Native.compileSelectionTypeSpecializedKeepingEntries (const True) S.empty PreserveCallbacks
        (closedLayouts (Native.nativeClosed basePlain)) baseSelection)
      original=Native.nativeProgram basePlain
      result=Native.nativeProgram specialized
      instances=[n | n<-M.keys result,"identity$typespec$type$" `isInfixOf` n]
  check "Base type specialization retains every original entry and arity"
    (all (\(n,(ps,_))->fmap (length . fst) (M.lookup n result)==Just (length ps)) (M.toList original))
  check "Base private instances have stable complete type identities"
    (S.fromList instances==S.fromList ["identity$typespec$type$fc3_Intc3_Int","identity$typespec$type$fc4_Boolc4_Bool"])
  check "retained and instantiated Base calls preserve scalar results"
    (answer result "integer" [Eval.RInt 71]==Right (Eval.RInt 71)
      && answer result "boolean" [Eval.RObj 1 1 []]==Right (Eval.RObj 1 1 [])
      && answer result "identity" [Eval.RInt 89]==Right (Eval.RInt 89))
  let (_,localNative)=compile "local-layout" "Cell a = Type (Cell a). probe : Int -> Int. probe n = box = Cell n; case box of Cell x -> x." (S.singleton "probe")
  mapM_ (\uniform->do
    let (signatures,layouts,evidence,annotated)=right (NativeRep.prepareFor uniform localNative)
        clear e=case e of
          CApp (CVar n) x | M.member n evidence->clear x
          CApp a b->CApp (clear a) (clear b)
          CLet n a b->CLet n (clear a) (clear b)
          CIf c a b->CIf (clear c) (clear a) (clear b)
          CMk t v xs->CMk t v (map clear xs)
          CProj i x->CProj i (clear x)
          CTagEq t v x->CTagEq t v (clear x)
          CLam ps b->CLam ps (clear b)
          _->e
    check "local checked evidence preserves the exact ordinary erasure"
      (M.map (\(ps,b)->(ps,clear b)) annotated==Native.nativeProgram localNative)
    check "a local-only closed wrapper gets scalar authority"
      (any (\d->case d of Rep.ScalarLayoutDef _ _ (Rep.ScalarRep Rep.Managed)->True;_->False) (M.elems layouts))
    mapM_ (\enabled->do
      let (lowered,_)=right ((if uniform then Arc.lowerArcWithEvidence else Arc.lowerRawWithEvidence)
            evidence layouts enabled S.empty signatures M.empty annotated)
          body=show (lowered M.! "probe")
      check "local wrapper construction/projection erases under rollback and raw lowering"
        (not ("CProj" `isInfixOf` body || "$arc.setLayout" `isInfixOf` body || "$representation.local" `isInfixOf` body))) [False,True]) [False,True]
  checkInlining compile
  checkVectorReads compile
  checkNormalization compile
  checkFusion compile
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
  let declarations=right (Imports.codeDeclarations linked)
      privateFactory=head [name | (Linked.ArtifactSymbol home name,Linked.SymbolOwner _ (Linked.PrivateDefinition "factory" _ _))
        <-M.toList (Linked.linkedSymbols linked),home==providerId]
      importedBody=CApp (CApp (CVar privateFactory) (CInt 41)) (CInt 1)
      importer=M.insert "usePrivate" ([],importedBody) (Native.nativeProgram consumer)
      public=Linked.artifactExports rootArtifact
      prepared=right (Imports.prepareEmission declarations Linked.RootArtifact public importer)
      declaration=Imports.readyImports prepared M.! privateFactory
      homeReady=right (Imports.prepareEmission declarations providerId (Linked.artifactExports providerArtifact) (Native.nativeProgram provider))
  check "private imports retain home/source/code contracts and physical capture arity"
    (Imports.declarationHome declaration==providerId && Imports.declarationSource declaration=="factory"
      && Imports.importArities prepared M.! privateFactory==2
      && privateFactory `M.notMember` Imports.readyProgram prepared)
  check "home code and PAP visibility is strong/hidden even in a weak unit"
    (visibilityFor True (Imports.readySymbols homeReady) privateFactory==HiddenSymbol)
  check "declared imports execute the home implementation under independent machine evaluation"
    (answer (Imports.readyProgram prepared `M.union` linkedProjection) "usePrivate" []==Right (Eval.RInt 42))
  check "a checked private definition cannot be copied to an importing artifact"
    (rejects "copied away from its home" (Imports.prepareEmission declarations Linked.RootArtifact public
      (M.insert privateFactory (Native.nativeProgram provider M.! privateFactory) importer)))
  let ownedPrivate=S.findMin (Imports.preservedCode declarations Linked.RootArtifact)
      wrongArity=M.adjust (\(ps,b)->(drop 1 ps,b)) ownedPrivate importer
  check "private emission contracts reject lost definitions and changed capture arities"
    (rejects "home private definition is absent" (Imports.prepareEmission declarations Linked.RootArtifact public (M.delete ownedPrivate importer))
      && rejects "private physical arity changed" (Imports.prepareEmission declarations Linked.RootArtifact public wrongArity))
  let shadowed=M.insert "shadowPrivate" ([],CLet privateFactory (CInt 7) (CVar privateFactory)) (Native.nativeProgram consumer)
  check "lexical names cannot accidentally acquire private import declarations"
    (M.null (Imports.readyImports (right (Imports.prepareEmission declarations Linked.RootArtifact public shadowed))))
  let templates=M.singleton privateFactory (Native.nativeProgram provider M.! privateFactory)
      preparedTemplates=right (Imports.prepareEmissionWithImports templates declarations Linked.RootArtifact public importer)
  check "read-only templates retain contracts without becoming owned code"
    (M.keysSet (Imports.readyTemplates preparedTemplates)==S.singleton privateFactory
      && privateFactory `M.notMember` Imports.readyProgram preparedTemplates)
  check "a read-only template cannot invent a calling arity"
    (rejects "template lacks an imported calling contract"
      (Imports.prepareEmissionWithImports (M.map (\(ps,b)->(drop 1 ps,b)) templates) declarations Linked.RootArtifact public importer))
  check "independent machine evaluation links checked artifact projections"
    (answer linkedProjection "client" [Eval.RInt 10]==Right (Eval.RInt 12)
      && answer linkedProjection "call" [Eval.RInt 41]==Right (Eval.RInt 42))
  let globalSource="apply f x = f x. inc x = x + 1. produce f x = _ = f x; fn y -> y. home n = produce inc n. caller n = produce inc n. useApply n = apply inc n."
      (_,globalConsumer)=compile "global-clones" globalSource (S.fromList ["caller","useApply"])
      (_,globalProvider)=compile "global-clones" globalSource (S.fromList ["apply","inc","produce","home"])
      ga=right (Linked.artifact Linked.RootArtifact (S.fromList ["caller","useApply"]<>Native.nativeConstructors globalConsumer) S.empty globalConsumer)
      gb=right (Linked.artifact providerId (S.fromList ["apply","inc","produce","home"]) (Native.nativeConstructors globalProvider) globalProvider)
      generic=right (Linked.linkArtifacts [ga,gb])
      specialized=right (Linked.specializeLinked SpecializeCallbacks generic)
      rootCore=Linked.artifactCore (Linked.linkedArtifacts specialized M.! Linked.RootArtifact)
      rootClosed=Native.nativeClosed rootCore
      cloned=M.unions (map closedOrigins (M.elems (closedDefinitions rootClosed)))
      imports=M.unions (map closedImports (M.elems (closedDefinitions rootClosed)))
      projection=M.unions [M.withoutKeys (Native.nativeProgram (Linked.artifactCore a)) (Linked.artifactElided a)
        | a<-M.elems (Linked.linkedArtifacts specialized)]
      faces=Regions.programInterfaces (right (Regions.prepare rootCore))
      originalArtifacts=Linked.linkedArtifacts generic
      providers=map Linked.artifactCore (M.elems originalArtifacts)
      separate=M.map (right . Native.specializeNativeWith SpecializeCallbacks providers . Linked.artifactCore) originalArtifacts
  check "shared callback snapshot matches separate artifact catalogs including elided stubs"
    (M.map (Native.nativeProgram . Linked.artifactCore) (Linked.linkedArtifacts specialized)==M.map Native.nativeProgram separate)
  check "linked checked globals are cloned before erasure with source and parameter provenance"
    (not (M.null cloned) && any ((=="produce") . cloneSource) (M.elems cloned)
      && any (any ((==Nothing) . snd) . cloneBindings) (M.elems cloned)
      && all (\(T.CodeId n)->maybe False (maybe False (const True) . interfaceCloneOrigin) (M.lookup n faces)) (M.keys cloned))
  check "a global clone imports the original provider closure instead of copying its PAP/code"
    (not (M.null imports) && all (\(T.CodeId n)->n `M.notMember` Native.nativeProgram rootCore) (M.keys imports)
      && verifyClosedProgram rootClosed==Right ())
  check "typed global clones agree with independent machine evaluation across artifacts"
    (answer projection "useApply" [Eval.RInt 41]==Right (Eval.RInt 42)
      && answer projection "caller" [Eval.RInt 7]==answer projection "home" [Eval.RInt 7])
  let badGlobalSource="apply f x = f x. inc x = x + 1. produce f x = _ = f x; fn y -> x. home n = produce inc n. caller n = produce inc n. useApply n = apply inc n."
      (_,changedProvider)=compile "global-clones" badGlobalSource (S.fromList ["apply","inc","produce","home"])
      changedHome=right (Linked.artifact providerId (S.fromList ["apply","inc","produce","home"]) (Native.nativeConstructors changedProvider) changedProvider)
      clonedRoot=Linked.linkedArtifacts specialized M.! Linked.RootArtifact
  check "an imported clone declaration cannot borrow a changed home's private contract"
    (rejects "imported private contract disagrees with its home" (Linked.linkArtifacts [clonedRoot,changedHome]))
  let cloneOwner=head [f | f<-M.elems (closedDefinitions rootClosed),not (M.null (closedOrigins f))]
      wrongOrigin origin=origin {cloneBindings=[(old,Just old) | (old,_)<-cloneBindings origin]}
  check "clone provenance cannot point to template binders as if they were cloned physical parameters"
    (failed (rewriteClosedWithOrigins (P.programTypes (closedInput rootClosed))
      (\root codes origins->Right (root,codes,M.map wrongOrigin origins)) cloneOwner))
  let unmodified=right (Linked.specializeLinked PreserveCallbacks generic)
  check "disabled linked specialization retains exact native programs"
    (all (\a->Native.nativeProgram (Linked.artifactCore a)==Native.nativeProgram
      (Linked.artifactCore (Linked.linkedArtifacts unmodified M.! Linked.artifactId a))) (M.elems (Linked.linkedArtifacts generic)))
  let equalitySource="same f x y = if x == y then f x else f y. outer f x y = same f x y. ident x = x. entry x y = outer ident x y."
      (_,equalityInput)=compile "generic-intrinsics" equalitySource (S.fromList ["same","outer","ident","entry"])
      equalityOutput=right (Native.specializeNativeWith SpecializeCallbacks [] equalityInput)
      equalityDefinitions=M.elems (closedDefinitions (Native.nativeClosed equalityOutput))
      equalityClones=[contract | f<-equalityDefinitions,(key,origin)<-M.toList (closedOrigins f),cloneSource origin=="same",
        Just contract<-[M.lookup key (closedOwnedContracts f)]]
  check "generated intrinsic instances do not pin a forwarded clone's generic operand type"
    (not (null equalityClones) && all ((/=([],[])) . T.contractQuantifiers) equalityClones
      && answer (Native.nativeProgram equalityOutput) "entry" [Eval.RInt 7,Eval.RInt 9]==Right (Eval.RInt 9)
      && answer (Native.nativeProgram equalityOutput) "entry" [Eval.RObj 1 1 [],Eval.RObj 1 0 []]==Right (Eval.RObj 1 0 []))
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
