module TypedInline (checkInlining) where
import qualified Compiler.Native.Core as Native
import qualified Compiler.Native.Linked as Linked
import Frontend.Desugar.Typed (SourceSelection)
import Core.Typed.Pipeline
import Core.Typed.Close
import Core.Typed.Callback (CallbackMode(..))
import Core.Typed.Callback.Model (Target(..),Template(..),ClonePlan(..))
import Core.Typed.Callback.Trim (trimCallbacks)
import Core.Typed.Contract (codeContracts)
import Core.Primitives (entryTickName)
import Inline (inlineCompatibilityWithImports)
import Core.Syntax (Core(..))
import qualified Cost
import qualified Core.Region.CallSites as Sites
import qualified Core.Region.Types as Region
import Core.Typed.Walk
import Core.Typed.Verify
import Core.Identity
import qualified Core.Typed.Syntax as T
import qualified Core.Typed.Program as P
import qualified Codegen.Lower as Lower
import qualified Codegen.Eval as E
import Codegen.Policy (m2Policy)
import Ownership.TypeShape (linShapeT)
import Type.Syntax
import Data.Functor.Const (Const(..))
import Control.Monad (unless,forM_)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

right=either error id
check label ok=unless ok (error ("typed inline: "++label))
failed (Left _)=True
failed _=False

checkInlining :: (String -> String -> S.Set String -> (SourceSelection,Native.NativeCore)) -> IO ()
checkInlining compile=do
  let source=unlines
        ["identity x = x.","first x y = x.","twice n = identity (identity n).",
         "apply f x = f x.","staged n = apply identity n.",
         "unused n = first n (10 / n).","shadow n = identity = 77; twice n + identity.",
         "factory n = fn x -> x + n.","closure n = (factory n) 2.",
         "poly n = ident x = x; combine y = (ident y,ident True,ident); combine n.",
         "recursive : unsafe Int -> Int.","recursive n = if n == 0 then 0 else recursive (n - 1).",
         "ping : unsafe Int -> Int.","ping n = if n == 0 then 0 else pong (n - 1).",
         "pong : unsafe Int -> Int.","pong n = if n == 0 then 0 else ping (n - 1).",
         "joined : unsafe (Int,Int) -> Int.","joined (0,0) = 0.","joined (n,x) = joined (n - 1,x).",
         "Token 1 = Type Int.","linear n = identity (Token n)."]
      names=S.fromList ["identity","first","twice","apply","staged","unused","shadow","factory","closure","poly","recursive","ping","pong","joined","linear"]
      (_,raw)=compile "typed-inline" source names
      a=right (Linked.artifact Linked.RootArtifact (names<>Native.nativeConstructors raw) S.empty raw)
      linked=right (Linked.linkArtifacts [a])
      before=Linked.artifactCore (Linked.linkedArtifacts linked M.! Linked.RootArtifact)
      after=Linked.artifactCore (Linked.linkedArtifacts (right (Linked.inlineLinked 3 24 linked)) M.! Linked.RootArtifact)
      large=Linked.artifactCore (Linked.linkedArtifacts (right (Linked.inlineLinked 3 256 linked)) M.! Linked.RootArtifact)
      defs=closedDefinitions (Native.nativeClosed after)
      bodies=map (T.functionBody . Native.checkedFunction) (M.elems (Native.nativeDefinitions after))
      ids=[T.binderId b | d<-M.elems (Native.nativeDefinitions after),let f=Native.checkedFunction d,b<-T.functionParameters f++allBinders (T.functionBody f)]
      global n e=(case T.exprNode e of T.Var (T.Global g _)->n==g;_->False)
        ||or (getConst (mapChildrenM (Const . (:[]) . global n) e))
      ticks e=(case T.exprNode e of T.EntryTick->1;_->0)
        +sum (getConst (mapChildrenM (Const . (:[]) . ticks) e))
      body name=T.functionBody (closedRoot (defs M.! name))
  check "closed program is checked after each round" (verifyClosedProgram (Native.nativeClosed after)==Right ())
  check "lexical clones do not manufacture new code entries" (M.keysSet (Native.nativeProgram before)==M.keysSet (Native.nativeProgram after))
  check "all binder identities remain unique" (length ids==S.size (S.fromList ids))
  check "ordinary root interfaces retain identities/types" (and
    [let old=closedRoot f;new=closedRoot (defs M.! name)
     in map T.binderId (T.functionParameters old)==map T.binderId (T.functionParameters new)
       && sameType (T.functionType old) (T.functionType new)
    | (name,f)<-M.toList (closedDefinitions (Native.nativeClosed before))])
  check "nested saturated identities inline" (not (global "identity" (body "twice")) && ticks (body "twice")==2)
  check "recursive entries remain calls" (global "recursive" (body "recursive"))
  let cycleDefinitions=closedDefinitions (Native.nativeClosed large)
      joined=cycleDefinitions M.! "joined"
      cycleBodies=[T.functionBody (closedRoot (cycleDefinitions M.! n)) | n<-["ping","pong","joined"]]
        ++map T.codeBody (M.elems (closedCode joined))
  check "clause regression includes a real generated join" (not (M.null (closedCode joined)))
  check "mutual and generated-join cycles are never expanded" (all ((==0).ticks) cycleBodies)
  check "typed entry tick exists" (any ((>0).ticks) bodies)
  let polyContracts=Native.checkedContracts (Native.nativeDefinitions before M.! "poly")
      hasPolyCall e=(case T.exprNode e of
        T.CodeCall label _ _->case M.lookup label polyContracts of
          Just c->any (\(Forall qs rs _,_)->not (null qs && null rs)) (T.contractCaptures c)
          _->False
        _->False)||or (getConst (mapChildrenM (Const . (:[]) . hasPolyCall) e))
  check "static closure construction authorizes the polymorphic captured call"
    (hasPolyCall (T.functionBody (Native.checkedFunction (Native.nativeDefinitions before M.! "poly"))))
  check "polymorphic captured code is actually inlined under an admitting budget"
    (ticks (T.functionBody (closedRoot (closedDefinitions (Native.nativeClosed large) M.! "poly")))>0)
  let noInline=Linked.artifactCore (Linked.linkedArtifacts (right (Linked.inlineLinked 0 24 linked)) M.! Linked.RootArtifact)
  check "zero rounds preserve the projection exactly" (Native.nativeProgram noInline==Native.nativeProgram before)
  check "negative budgets refuse" (failed (Linked.inlineLinked (-1) 24 linked) && failed (Linked.inlineLinked 3 (-1) linked))
  let protected=M.keysSet (Native.nativeDefinitions after)
      mixed=M.insert "compatEntry" (["v"],CApp (CVar "identity") (CVar "v")) (Native.nativeProgram after)
      late=inlineCompatibilityWithImports protected M.empty (const False) 3 24 mixed
  check "erased compatibility inlining cannot rewrite checked owners"
    (M.restrictKeys late protected==M.restrictKeys mixed protected)
  check "erased compatibility templates cannot copy checked callees" (late M.! "compatEntry"==mixed M.! "compatEntry")
  let oldIR=lower (Native.nativeProgram before)
      cases=[("twice",[E.RInt n]) | n<-[-9..9]]++[("unused",[E.RInt n]) | n<-[-4..4]]
        ++[("staged",[E.RInt 37]),("shadow",[E.RInt 5]),("closure",[E.RInt 11]),("poly",[E.RInt 23]),("recursive",[E.RInt 9]),("ping",[E.RInt 9]),("pong",[E.RInt 8]),("linear",[E.RInt 31])]
  forM_ [after,large] $ \output->forM_ cases $ \(name,args)->do
    let old=E.evalProgram oldIR name args;new=E.evalProgram (lower (Native.nativeProgram output)) name args
    check ("independent evaluator result/trap "++name) (E.ocResult old==E.ocResult new && not (stuck (E.ocResult new)))
    check ("entry ticks retained "++name) (length (filter safepoint (E.ocEvents old))==length (filter safepoint (E.ocEvents new)))
    check ("allocation/trap order retained "++name) (observations old==observations new)
  let context=P.programTypes (closedInput (Native.nativeClosed after))
      bad=T.Function "bad-tick" [] (T.Expr (TC "Int") (linShapeT [] (TC "Int")) T.Generated Nothing T.EntryTick)
  check "entry ticks do not make a pure loop allocate" (Cost.primAllocates entryTickName 1==Just False
    && Cost.primAllocates entryTickName 2==Nothing)
  let equations=Cost.costProgram M.empty M.empty (Native.nativeProgram after)
  check "inlined arithmetic has a nonopaque zero allocation bound" (Cost.ceAlloc (snd (equations M.! "twice"))==Cost.CN 0
    && entryTickName `notElem` Cost.omegas (Cost.ceWork (snd (equations M.! "twice"))))
  check "entry tick has Unit type" (failed (verifyFunction context bad))
  -- An inlined recursive checking assumption can leave an occurrence more
  -- general than its callee's eventual public signature. A declaration alone
  -- cannot authorize copying that occurrence's result out of a call region.
  let T.TypeContext linears _=context
      expression ty node=T.Expr ty (linShapeT linears ty) T.Generated Nothing node
      generic=Forall [700] [] (TFn (TC "Int") (TV 700))
      application ty=expression ty (T.Apply
        (expression (TFn (TC "Int") ty) (T.Var (T.Global "callee" generic)))
        (expression (TC "Int") (T.IntValue 1)))
      unknown=T.Function "unknown" [] (application (TV 701))
      known=T.Function "known" [] (application (TC "String"))
      owned=T.Function "owned" [] (application (TC "Token"))
      mixed=T.Function "mixed" [] (expression (TV 701) (T.Sequence (T.functionBody known) (T.functionBody unknown)))
      arities=M.fromList [("callee",1),("unknown",0),("known",0),("owned",0),("mixed",0),("compat",0)]
      model=right (Region.valueModel context)
      sites=right (Sites.callSites model arities (M.fromList
        [("unknown",Just unknown),("known",Just known),("owned",Just owned),("mixed",Just mixed),("compat",Nothing)]))
  check "region call-site witnesses are independently well typed"
    (all ((==Right ()).verifyFunction context) [unknown,known,owned,mixed])
  check "known copyable occurrences authorize regions" (Sites.mayCopyResult sites "known" "callee")
  check "unknown, owned, mixed or absent checked sites do not inherit ABI copyability"
    (all (\owner->not (Sites.mayCopyResult sites owner "callee")) ["unknown","owned","mixed","absent"]
      && not (Sites.mayCopyResult sites "known" "other"))
  check "compatibility retains its explicit declaration-only boundary" (Sites.mayCopyResult sites "compat" "callee")
  check "region call-site owner/arity mismatches refuse"
    (failed (Sites.callSites model (M.insert "known" 1 arities) (M.singleton "known" (Just known))))
  -- The second callback pass sees aliases introduced by inlining. A dead
  -- callback formal can still appear syntactically through an unused staged
  -- match slot; remove that slot/alias before removing the formal itself.
  let int=TC "Int";fun=TFn int int
      binding i name ty=T.Binder (BinderId (Namespace "inline-trim-regression") i) name (Forall [] [] ty) (linShapeT linears ty)
      f=binding 0 "f" fun;x=binding 1 "x" int;alias=binding 2 "alias" fun
      pf=binding 3 "pattern-f" fun;px=binding 4 "pattern-x" int;rx=binding 5 "root-x" int
      ref b=expression (T.binderType b) (T.Var (T.Local (T.binderId b)))
      match=expression int (T.MatchTail (T.FunctionMatch "helper") [ref alias,ref x]
        [T.Alternative [T.Pattern fun "f" (T.Bind pf),T.Pattern int "x" (T.Bind px)] [] (ref px)]
        (expression int (T.Fail "unreachable")))
      cloneBody=expression int (T.Let alias (ref f) match)
      label=T.CodeId "trim-clone"
      clone=T.CodeFunction label T.EntryCode [] [f,x] cloneBody
      graph=M.singleton label clone
      schemas=M.fromList [("identity",Forall [] [] fun),("helper",Forall [] [] (TFn fun fun))]
      contracts=codeContracts schemas graph
      main=T.Function "trim-root" [rx] (expression int (T.CodeCall label []
        [expression fun (T.Var (T.Global "identity" (schemas M.! "identity"))),ref rx]))
      templates=M.singleton (RootTarget "helper") (Template [] [f,x] cloneBody (contracts M.! label) T.EntryCode)
      plans=M.singleton label (ClonePlan (RootTarget "helper") (S.singleton (T.binderId f)))
      (trimmed,graph',_)=right (trimCallbacks context (M.fromList [("identity",1),("helper",2)]) schemas templates
        plans (S.singleton (T.binderId alias)) main graph)
      contracts'=codeContracts schemas graph'
  check "callback alias regression input is checked"
    (all ((==Right ()).verifyFunctionWith contracts context) [main,T.codeAsFunction clone])
  check "dead callback formal and its staged alias disappear together"
    (map T.binderId (T.codeParameters (graph' M.! label))==[T.binderId x]
      && all ((==Right ()).verifyFunctionWith contracts' context) (trimmed:map T.codeAsFunction (M.elems graph')))
  -- Elided constructor stubs are visible in both units but have one owner.
  -- Imported private code remains at home; private source globals may not be
  -- copied into the caller merely because their bodies exist in the catalog.
  let imports="secret : unsafe Int -> Int. secret n = if n <= 0 then 0 else 2 + secret (n - 1). public n = secret n + 1. factory n = fn x -> secret n + x. client n = public n + (factory n) 2."
      (_,consumer)=compile "inline-linked" imports (S.singleton "client")
      (_,provider)=compile "inline-linked" imports (S.fromList ["secret","public","factory"])
      root=right (Linked.artifact Linked.RootArtifact (S.singleton "client"<>Native.nativeConstructors consumer) S.empty consumer)
      home=Linked.DependencyArtifact "provider"
      dependency=right (Linked.artifact home (S.fromList ["public","factory"]) (Native.nativeConstructors provider) provider)
      original=right (Linked.linkArtifacts [root,dependency])
      changed=right (Linked.inlineLinked 3 24 original)
      rootCore=Linked.artifactCore (Linked.linkedArtifacts changed M.! Linked.RootArtifact)
      clientBody=T.functionBody (closedRoot (closedDefinitions (Native.nativeClosed rootCore) M.! "client"))
      projection p=M.unions [M.withoutKeys (Native.nativeProgram (Linked.artifactCore artifact)) (Linked.artifactElided artifact)
        | artifact<-M.elems (Linked.linkedArtifacts p)]
  check "private source dependency stays behind its public call" (global "public" clientBody && not (global "secret" clientBody))
  check "factory body can inline without moving its private closure home" (not (global "factory" clientBody)
    && M.keysSet (Linked.linkedSymbols changed)==M.keysSet (Linked.linkedSymbols original))
  check "imported original closure contract is retained" (any (not . M.null . closedImports)
    (M.elems (closedDefinitions (Native.nativeClosed rootCore))))
  check "imported code has the original result" (E.ocResult (E.evalProgram (lower (projection changed)) "client" [E.RInt 7])==Right (E.RInt 31))
  putStrLn "Typed inlining: checked instantiation, strict arguments/traps, fuel, fresh identities, polymorphic captures, hygiene and imported code homes passed"
  where
    lower p=let (ir,refused)=Lower.lowerProgram m2Policy M.empty p p M.empty M.empty
            in if null refused then ir else error (show refused)
    safepoint (E.EvSafepoint _)=True
    safepoint _=False
    observations outcome=[event e | e<-E.ocEvents outcome,case e of E.EvAllocate {}->True;E.EvTrap {}->True;_->False]
    event (E.EvAllocate _ tid variant fields)=show (tid,variant,fields)
    event (E.EvTrap msg)=msg
    event _=error "unselected evaluator event"
    stuck (Left (E.Stuck _))=True
    stuck _=False
