{-# LANGUAGE LambdaCase, TupleSections #-}
-- Inference-guided semantic Core construction. This frontend owns source
-- evidence and selection, without performing native layout, closing or erasure.
module Frontend.Desugar.Typed
  (CheckedPlans,prepareChecked,checkedNames,checkedDeclines,checkedCallArities,
   CheckedUnit,selectCheckedUnit,checkedUnitTops,checkedUnitNames,
   SpecializedSource,specializeCheckedSource,specializedTops,
   SourceSelection,selectionProgram,selectionCompatibility,Compatibility,
   compatibilityClauses,compatibilityReason,selectUnit,selectSpecialized,selectClauses) where
import Core.Identity
import qualified Core.Typed.Syntax as T
import qualified Core.Typed.Program as Program
import Core.Primitives (primArities)
import qualified Core.Typed.Walk as Walk
import Core.Typed.Verify (instanceOf,sameType)
import qualified Core.Typed.Specialize as Specialize
import Compiler.VectorLayout
import Compiler.Trap
import Type.Syntax (Type(..),Scheme(..))
import Ownership.Shape (LShape(..))
import Ownership.TypeShape (linShapeT)
import Frontend.Syntax
import Frontend.Traverse (sFree,sourceGroups)
import Infer.Result
import Infer.Pattern
import qualified Infer.Evidence as E
import Infer.Elaboration
import Precond (checkedName)
import qualified Struct
import Control.Monad (forM,unless)
import Data.Binary (encode)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.Set as S

data PlanningProblem = Deferred String | Corrupt String

globalReference reference=case reference of
  E.GlobalReference name sc->Just (name,sc)
  E.RecursiveReference name scoped _->Just (name,scoped)
  _->Nothing

data CheckedPlans = Plans
  { planNamespace :: Namespace, planTypes :: T.TypeContext,
    planEntries :: M.Map String Plan, planDeclines :: [(String,String)],
    planSource :: [STop], planSpecialization :: Specialize.Context,
    planSignatures :: Struct.Sigs, planStructures :: Struct.Structs,
    planAssumptions :: M.Map ExprId Program.RecursiveAssumption }
data SpecializedSource=SpecializedSource CheckedPlans [STop] Specialize.Specialized
specializeCheckedSource :: CheckedPlans -> Either [String] SpecializedSource
specializeCheckedSource plans=case Struct.specialize (planSignatures plans) (planStructures plans) (planSource plans) of
  ([],tops)->do
    let templates=M.fromList [(name,f) | group@(name,_)<-sourceGroups (Struct.erasePSig (planSource plans)),Just f<-[typedFunction plans group]]
    typed<-either (Left . (:[])) Right (Specialize.specialize (planNamespace plans) (planSpecialization plans) templates)
    Right (SpecializedSource plans (Struct.erasePSig tops) typed)
  (errors,_)->Left errors
specializedTops :: SpecializedSource -> [STop]
specializedTops (SpecializedSource _ tops _)=tops
-- An owned projection of one checking run, including the exact elaborated
-- clauses its plans describe. Clients cannot pair it with rewritten bodies.
data CheckedUnit = CheckedUnit CheckedPlans [STop] (S.Set String)
selectCheckedUnit :: CheckedPlans -> S.Set String -> Either String CheckedUnit
selectCheckedUnit plans names = do
  let source=planSource plans
  let available=S.fromList [n | TBind n _ _ _<-source]
      missing=names S.\\ available
  unless (S.null missing) (Left ("checked unit: absent definitions: "++unwords (S.toAscList missing)))
  pure (CheckedUnit plans (Struct.erasePSig [t | t@(TBind n _ _ _)<-source,n `S.member` names]) names)
checkedUnitTops :: CheckedUnit -> [STop]
checkedUnitTops (CheckedUnit _ tops _)=tops
checkedUnitNames :: CheckedUnit -> S.Set String
checkedUnitNames (CheckedUnit _ _ names)=names
checkedCallArities :: CheckedPlans -> M.Map String Int
checkedCallArities plans=M.fromList [(n,length ps) | TBind n ps _ _<-planSource plans]
callingArities :: CheckedPlans -> M.Map String Int
-- Foreign signatures can intentionally hide the runtime callable's arity.
-- Source definitions and canonical core entries supply physical evidence.
callingArities plans=checkedCallArities plans `M.union` M.fromList primArities
data Plan = Plan [T.Binder] [Clause] [([SPat],[SGuard],SExpr)]
data Clause = Clause [T.Pattern] [GuardPlan] EPlan
data GuardPlan = Boolean EPlan | Matching T.Pattern EPlan
data EPlan = EP E.ExprFact PNode
data PNode = Ref T.Reference | LitInt Integer | LitString String | LitAtom String
  | Application EPlan EPlan | Lambda [T.Binder] EPlan
  | HiddenReference T.Reference [T.Expr] | VectorConstructor VectorBuilder T.Expr
  | GeneratedTrap TrapPlan
  | Binding T.Binder [T.Binder] EPlan EPlan | PatternBinding T.Pattern EPlan EPlan
  | RecursiveBinding T.Binder [T.Binder] EPlan EPlan
  | Pipe EPlan EPlan | Sequencing EPlan EPlan | Call2 String EPlan EPlan
  | OperatorCall EPlan EPlan EPlan | ProjectCall T.Binder String EPlan EPlan
  | ShortCircuit Bool EPlan EPlan | ResultPipe EPlan EPlan | Cons EPlan EPlan
  | Case EPlan [(T.Pattern,EPlan)] | Note EPlan
  | Tuple [EPlan] | List [EPlan] | Record [(String,EPlan)]
  | Projection EPlan [String] | Update EPlan [([String],EPlan)]
  | Interpolation [Either String (Maybe String,EPlan)] | RenderApplication EPlan String EPlan

checkedNames :: CheckedPlans -> S.Set String
checkedNames = M.keysSet . planEntries
checkedDeclines :: CheckedPlans -> [(String,String)]
checkedDeclines = planDeclines

prepareChecked :: InferenceResult -> Either String CheckedPlans
prepareChecked result = do
  evidence<-case inferenceEvidence result of
    Right (Just e)->Right e
    Left reason->Left reason
    _->Left "typed Core requires a checked inference result"
  let facts=M.fromList [(E.expressionIdentity e,e) | e<-E.evidenceExpressions evidence]
      binders=M.fromList [(E.binderIdentity b,b) | b<-E.evidenceBinders evidence]
      globals=S.fromList ([n | TBind n _ _ _<-inferenceTops result]++[n | TSig n _ _<-inferenceTops result])
      targets=IM.fromList [(elaborationSite e,elaborationTarget e) | e<-inferenceElaborations result]
      at=M.fromListWith (flip (++)) [(uid,[e]) | e<-inferenceElaborations result,Just uid<-[elaborationExpression e]]
      roots=M.fromListWith (flip (++)) [(owner,[e]) | uid<-E.evidenceRoots evidence,Just e<-[M.lookup uid facts],Just owner<-[E.expressionOwner e]]
      groups=M.fromListWith (flip (++)) [(n,[(ps,gs,b)]) | TBind n ps gs b<-Struct.erasePSig (inferenceTops result)]
      site key=maybe (corrupt ("missing checked pattern at "++show key)) Right (M.lookup key (inferencePatterns result))
      layoutContracts=inferenceLayoutContracts result
      namespace=case E.evidenceNamespace evidence of Namespace ns->ns
      hiddenFor name=case M.lookup name layoutContracts of
        Nothing->[]
        Just contract->[T.Binder (BinderId (Namespace (namespace++"/layout-parameters/"++name)) index)
          (layoutParameterName (LayoutSlot name index)) (Forall [] [] (TLayout ty)) LU
          | (index,ty)<-zip [0..] (layoutBodyRequirements contract)]
      hiddenBinders=M.fromList [(LayoutSlot name index,b) | name<-M.keys layoutContracts,(index,b)<-zip [0..] (hiddenFor name)]
      layoutArgument proof=case proof of
        StaticLayout ty spec->pure (T.Expr (TLayout ty) LU T.Generated Nothing (T.LayoutLiteral spec))
        ForwardLayout ty slot->do
          b<-maybe (corrupt "missing layout parameter identity") pure (M.lookup slot hiddenBinders)
          unless (sameType (T.binderType b) (TLayout ty)) (corrupt "forwarded layout parameter type mismatch")
          pure (T.Expr (TLayout ty) LU T.Generated Nothing (T.Var (T.Local (T.binderId b))))
      binder uid=case M.lookup uid binders of
        Nothing->corrupt "missing checked binder"
        Just b->let name=M.findWithDefault (E.binderSpelling b) uid (inferenceBinderNames result)
                    sc=case M.lookup name layoutContracts of
                      Just c | layoutContractOwner c==LocalLayout uid->layoutCallingScheme c
                      _->E.binderScheme b
                in Right (T.Binder uid name sc (E.binderTypeShape b))
      scoped scope name=maybe (corrupt ("absent checked binder "++name)) binder (M.lookup name scope)
      patternOf info=do
        node<-case matchedSource info of
          PWild->pure T.Wildcard
          PVar n->T.Bind <$> scoped (matchedBindings info) n
          PSig n _->T.Bind <$> scoped (matchedBindings info) n
          PInt n->pure (T.IntegerPattern n)
          PStr s->pure (T.StringPattern s)
          PCon n _->T.ConstructorPattern n <$> mapM patternOf (matchedChildren info)
          PTup _->T.TuplePattern <$> mapM patternOf (matchedChildren info)
          PRec ns->T.RecordPattern <$> mapM (\n -> (n,) <$> scoped (matchedBindings info) n) ns
        pure (T.Pattern (matchedType info) (show (matchedSource info)) node)
      child uid=maybe (corrupt "missing checked expression") plan (M.lookup uid facts)
      children e=mapM child (E.expressionChildren e)
      renderer e=case [elaborationTarget x | x<-M.findWithDefault [] (E.expressionIdentity e) at,elaborationOperation x=="str!"] of
        [OpPrim ""]->Right Nothing
        [OpPrim n]->Right (Just n)
        []->Right Nothing
        _->corrupt "rendering derivation is not a single checked decision"
      global name ty=case M.lookup name (inferenceSchemes result) of
        Just sc | instanceOf sc ty->Right (T.Global name sc)
        _->defer ("generated call lacks a matching checked signature: "++name)
      renderable mname p=do
        let input=planType p
        converted<-case mname of Nothing->Right input; Just n->global n (TFn input (TC "String")) >> Right (TC "String")
        _<-global "str" (TFn converted (TC "String"))
        pure ()
      plan e=do
        let make n=Right (EP e n)
        case E.expressionSource e of
          SVar name | Just arity<-M.lookup name (inferenceConstructorTraps result)->do
            case E.expressionReference e of
              Just reference | Just (actual,sc)<-globalReference reference->unless (actual==name && instanceOf sc (E.expressionType e)) (corrupt "constructor trap reference/type mismatch")
              _->corrupt "constructor trap lacks a checked global reference"
            contract<-either corrupt pure (constructorTrap name arity (E.expressionType e))
            make (GeneratedTrap contract)
          SVar _->case [elaborationTarget x | x<-M.findWithDefault [] (E.expressionIdentity e) at] of
            [OpDictionary name proofs]->do
              ref<-case E.expressionReference e of
                Just (E.LocalReference _ uid)->do
                  b<-binder uid
                  unless (name==T.binderName b) (corrupt "layout reference identity/target mismatch")
                  pure (T.Local uid)
                Just reference | Just (original,sc)<-globalReference reference->do
                  unless (name==original) (corrupt "global layout reference target mismatch")
                  case M.lookup name layoutContracts of
                    Just c->do
                      unless (layoutContractOwner c==GlobalLayout name) (corrupt "global layout reference owner mismatch")
                      pure (T.Global name (layoutCallingScheme c))
                    Nothing->pure (T.Global name sc)
                _->corrupt "layout reference lacks checked callee"
              args<-mapM layoutArgument proofs
              if null args then make (Ref ref) else make (HiddenReference ref args)
            [OpVector builder proof] | not (plainBuilder builder proof)->layoutArgument proof >>= make . VectorConstructor builder
            _->case (E.expressionReference e,applySites globals targets (E.expressionRewritten e)) of
              (Just (E.LocalReference _ uid),SVar n)->do
                b<-binder uid
                if n==T.binderName b then make (Ref (T.Local uid)) else defer "local layout reference not yet migrated"
              (Just reference,SVar n) | Just (_,sc)<-globalReference reference->make (Ref (T.Global n sc))
              _->defer "generated reference wrapper not yet migrated"
          SInt n->make (LitInt n)
          SAtom n->make (LitAtom n)
          SStrI segs->do
            cs<-children e
            let rs=[elaborationTarget x | x<-M.findWithDefault [] (E.expressionIdentity e) at,elaborationOperation x=="str!"]
                parts [] [] []=Right []
                parts (SegStr s:rest) xs choices=(Left s:) <$> parts rest xs choices
                parts (SegExpr _:rest) (x:xs) (OpPrim name:choices)=do
                  let r=if null name then Nothing else Just name
                  renderable r x
                  (Right (r,x):) <$> parts rest xs choices
                parts _ _ _=corrupt "interpolation derivation"
            ps<-parts segs cs rs
            _<-global "strcat" (TFn (TC "String") (TFn (TC "String") (TC "String")))
            make (Interpolation ps)
          SMark _ _->children e >>= \case [a]->make (Note a); _->corrupt "source mark derivation"
          SApp (SVar "?hole") (SStrI [SegStr ""])->make (GeneratedTrap (anonymousTrap (E.expressionType e)))
          SApp _ _ | [OpDeclaredVector proof]<-[elaborationTarget x | x<-M.findWithDefault [] (E.expressionIdentity e) at]->
            layoutArgument proof >>= make . VectorConstructor BuildEmpty
          SApp _ _->children e >>= \case
            [f,a]->do
              r<-renderer e
              case r of
                Nothing->make (Application f a)
                Just name->do
                  _<-global name (TFn (planType a) (TC "String"))
                  case f of
                    EP _ (Ref (T.Global fn sc)) | instanceOf sc (TFn (TC "String") (E.expressionType e))->make (RenderApplication f name a)
                    _->defer "rendering would change a non-polymorphic function contract"
            _->defer "synthesized application not yet migrated"
          SLam names _->children e >>= \case
            [b@(EP body _)]->do ps<-mapM (scoped (E.expressionScope body)) names; make (Lambda ps b)
            _->corrupt "lambda derivation"
          SBlock ss _->do
            cs<-children e
            let block _ [] [last']=Right last'
                block index (SBind n _ _:rest) (rhs:more)=do
                  info<-site (LocalOf (E.expressionIdentity e) index)
                  b<-scoped (matchedBindings info) n
                  ps0<-mapM (\p -> case matchedSource p of PVar v->scoped (matchedBindings p) v; _->corrupt "local parameter derivation") (matchedChildren info)
                  body<-block (index+1) rest more
                  let localHidden=case M.lookup (T.binderName b) layoutContracts of
                        Just c | layoutContractOwner c==LocalLayout (T.binderId b)->hiddenFor (T.binderName b)
                        _->[]
                      ps=localHidden++ps0
                      recursive=uses (T.binderId b) rhs
                      isLambda (EP _ (Note x))=isLambda x
                      isLambda (EP _ (Lambda (_:_) _))=True
                      isLambda _=False
                  unless (not recursive || not (null ps) || isLambda rhs) (defer "strict recursive value is not a function initializer")
                  pure (EP e ((if recursive then RecursiveBinding else Binding) b ps rhs body))
                block index (SBindPat _ _:rest) (rhs:more)=do
                  p<-site (BindingOf (E.expressionIdentity e) index) >>= patternOf
                  body<-block (index+1) rest more
                  pure (EP e (PatternBinding p rhs body))
                block _ _ _=corrupt "block derivation"
            block 0 ss cs
          SCase _ arms->children e >>= \case
            scrut:bs | length bs==length arms->do
              ps<-mapM (\i -> site (ArmOf (E.expressionIdentity e) i) >>= patternOf) [0..length arms-1]
              make (Case scrut (zip ps bs))
            _->corrupt "case derivation"
          SBin op _ _->do
            cs<-children e
            case (op,cs) of
              ("|>",[a,b])->make (Pipe a b)
              (">>",[a,b])->make (Sequencing a b)
              ("::",[a,b])->make (Cons a b)
              ("|>?",[a,b])->make (ResultPipe a b)
              ("and",[a,b])->make (ShortCircuit True a b)
              ("or",[a,b])->make (ShortCircuit False a b)
              (_, [f,a,b]) | EP ff _<-f, SVar n<-E.expressionSource ff,n==op->make (OperatorCall f a b)
              ("*",[a,b,_]) | SApp (SApp (SVar name) _) _<-E.expressionRewritten e,name `elem` ["mulMM","mulMV"]->make (Call2 name a b)
              (_, [a,b])->case [elaborationTarget x | x<-M.findWithDefault [] (E.expressionIdentity e) at,elaborationOperation x==op] of
                [OpPrim name]->make (Call2 name a b)
                [OpGlobal name]->make (Call2 (let checked=checkedName name 0 in if S.member checked globals then checked else name) a b)
                [OpProj name field]->do p<-scoped (E.expressionScope e) name; make (ProjectCall p field a b)
                _->corrupt "binary operator derivation"
              _->corrupt "binary operator child derivation"
          STup _->children e >>= make . Tuple
          SList _->children e >>= make . List
          SRec fs->children e >>= \xs -> make (Record (zip (map fst fs) xs))
          SProj _ path->children e >>= \case [base]->make (Projection base path); _->corrupt "projection derivation"
          SUpd _ fields->children e >>= \case
            base:xs | length xs==length fields->make (Update base (zip (map fst fields) xs))
            _->corrupt "record update derivation"
      entry name clauses=do
        case M.lookup name layoutContracts of
          Just c->unless (layoutContractOwner c==GlobalLayout name) (corrupt "layout entry owner mismatch")
          Nothing->pure ()
        let hidden=hiddenFor name
            build _ [] []=Right []
            build index ((ps,gs,_):rest) rootFacts=do
              let (here,more)=splitAt (length gs+1) rootFacts
              unless (length here==length gs+1) (corrupt "clause root derivation")
              let prefix=map (\p->case p of PVar n->Just n; _->Nothing) (take (length hidden) ps)
              unless (prefix==map (Just . T.binderName) hidden) (corrupt "layout entry parameter order")
              pats<-mapM (\i -> site (ParameterOf name index i) >>= patternOf) [0..length ps-length hidden-1]
              guardPlans<-forM (zip3 [0..] gs (take (length gs) here)) $ \(i,g,expr)->case g of
                GBool _->Boolean <$> plan expr
                GPat _ _->do p<-site (GuardOf name index i) >>= patternOf; Matching p <$> plan expr
              b<-plan (last here)
              (Clause pats guardPlans b:) <$> build (index+1) rest more
            build _ _ _=corrupt "clause count derivation"
        cls<-build 0 clauses (M.findWithDefault [] name roots)
        pure (Plan hidden cls clauses)
      answers=[(name,entry name cls) | (name,cls)<-M.toList groups]
      types=T.TypeContext [n | TType n True _ _<-inferenceTops result] (inferenceConstructors result)
  case [(name,why) | (name,Left (Corrupt why))<-answers] of
    (name,why):_->Left ("invalid checked lowering evidence for "++name++": "++why)
    []->do
      let source=inferenceTops result
          calling=M.fromList [(name,layoutCallingScheme c) | (name,c)<-M.toList layoutContracts,layoutContractOwner c==GlobalLayout name]
          schemas=calling `M.union` inferenceSchemes result `M.union` inferenceConstructors result
          entries=M.fromList [(raw,let checked=checkedName raw 0 in if checked `S.member` globals then checked else raw)
            | (name,(_,fs))<-M.toList (inferenceStructures result),field<-fs,let raw=name++"."++field]
          -- Match the existing surface pass's spine traversal: visit the
          -- arguments, not partial application prefixes or computed heads.
          spine uid=case M.lookup uid facts of
            Just e | SApp _ _<-E.expressionSource e,[f,a]<-E.expressionChildren e->let (h,args)=spine f in (h,args++[a])
            _->(uid,[])
          eligible uid=case M.lookup uid facts of
            Just e | SApp _ _<-E.expressionSource e->
              let (head,args)=spine uid
              in [uid | head `S.notMember` opaque]++concatMap eligible args
            Just e->concatMap eligible (E.expressionChildren e)
            _->[]
          recursive=M.fromList [(E.expressionIdentity e,Program.RecursiveAssumption (E.expressionIdentity e) owner target scoped published)
            | e<-E.evidenceExpressions evidence,Just owner<-[E.expressionOwner e],
              Just (E.RecursiveReference target scoped published)<-[E.expressionReference e]]
          opaque=S.fromList [E.expressionIdentity e | e<-E.evidenceExpressions evidence,
            Just (E.RecursiveReference _ _ published)<-[E.expressionReference e],not (instanceOf published (E.expressionType e))]
          context=Specialize.Context types schemas (M.map (map fst) (Struct.genericTable source))
            (M.keysSet (inferenceStructures result)) entries (S.fromList (concatMap eligible (E.evidenceRoots evidence)))
      pure (Plans (E.evidenceNamespace evidence) types (M.fromList [(n,p) | (n,Right p)<-answers])
        [(n,why) | (n,Left (Deferred why))<-answers] source context (inferenceSignatures result) (inferenceStructures result) recursive)
  where
    defer=Left . Deferred
    corrupt=Left . Corrupt
    planType (EP e _)=E.expressionType e
    uses uid (EP _ n)=case n of Ref (T.Local v)->v==uid; HiddenReference (T.Local v) _->v==uid; _->any (uses uid) (kids n)
    kids n=case n of
      Application a b->[a,b]; Lambda _ b->[b]; Binding _ _ a b->[a,b]; RecursiveBinding _ _ a b->[a,b]; PatternBinding _ a b->[a,b]
      Pipe a b->[a,b]; Sequencing a b->[a,b]; Call2 _ a b->[a,b]; OperatorCall f a b->[f,a,b]
      ProjectCall _ _ a b->[a,b]; ShortCircuit _ a b->[a,b]; ResultPipe a b->[a,b]; Cons a b->[a,b]
      Case a bs->a:map snd bs; Note a->[a]; Tuple xs->xs; List xs->xs; Record fs->map snd fs
      Projection a _->[a]; Update a fs->a:map snd fs
      Interpolation ps->[x | Right (_,x)<-ps]; RenderApplication f _ a->[f,a]
      _->[]

-- A checked semantic program and explicit compatibility-only clauses. The
-- latter have no borrowed typed annotations and never enter typed transforms.
data Compatibility=Compatibility [([SPat],[SGuard],SExpr)] String
compatibilityClauses (Compatibility cs _)=cs
compatibilityReason (Compatibility _ why)=why
data SourceSelection=SourceSelection Program.Program (M.Map String Compatibility)
selectionProgram (SourceSelection p _)=p
selectionCompatibility (SourceSelection _ cs)=cs

selectUnit :: S.Set String -> CheckedUnit -> Either String SourceSelection
selectUnit constructors (CheckedUnit plans tops _)=selectClauses constructors plans tops

-- Compatibility callers may submit changed clauses; exact evidence ownership
-- decides whether they can enter the checked program. Native owned callers use
-- selectUnit/selectSpecialized and cannot replace a checked source body.
selectClauses :: S.Set String -> CheckedPlans -> [STop] -> Either String SourceSelection
selectClauses constructors plans tops=do
  let groups=sourceGroups tops
      typed=M.fromList [(name,f) | group@(name,_)<-groups,Just f<-[typedFunction plans group]]
      declined=M.fromList (checkedDeclines plans)
      fallback=M.fromList [(name,Compatibility clauses (M.findWithDefault "clauses differ from the checked owner" name declined))
        | (name,clauses)<-groups,name `M.notMember` typed]
  assemble constructors plans (Specialize.globalSchemes (planSpecialization plans)) (callingArities plans) typed fallback

selectSpecialized :: S.Set String -> SpecializedSource -> S.Set String -> Either String SourceSelection
selectSpecialized constructors (SpecializedSource checked legacy specialized) selected=do
  let original=S.fromList [n | TBind n _ _ _<-planSource checked]
      legacyGroups=M.fromList (sourceGroups legacy)
      available=M.keysSet legacyGroups
  unless (selected `S.isSubsetOf` available) (Left "typed specialization: requested an absent source owner")
  let typed=Specialize.functions specialized
      arities=M.map (length . T.functionParameters) typed `M.union`
        M.fromList [(n,length ps) | TBind n ps _ _<-legacy] `M.union` callingArities checked
      cloneNames=Specialize.cloneNames specialized
      sourceNames=selected `S.intersection` original
      wanted=M.restrictKeys typed (sourceNames `S.union` cloneNames)
      fallbackSource=sourceNames S.\\ M.keysSet typed
      legacyOnly=available S.\\ original S.\\ M.keysSet typed
      refs clauses=S.fromList (concat [sFree b++concatMap (\g->case g of GBool e->sFree e;GPat _ e->sFree e) gs | (_,gs,b)<-clauses])
      dependencies=M.map refs legacyGroups
      globalRefs e=(case T.exprNode e of T.Var (T.Global n _)->S.singleton n;_->S.empty)
        `S.union` getConst (Walk.mapChildrenM (Const . globalRefs) e)
      roots=S.unions ([M.findWithDefault S.empty n dependencies | n<-S.toList fallbackSource]
        ++map (globalRefs . T.functionBody) (M.elems wanted))
      reach names=
        let more=S.unions [M.findWithDefault S.empty n dependencies | n<-S.toList names]
            next=names `S.union` (more `S.intersection` legacyOnly)
        in if next==names then names else reach next
      fallbackNames=fallbackSource `S.union` reach (roots `S.intersection` legacyOnly)
      fallback=M.map (\cs->Compatibility cs "compatibility-only structure expansion") (M.restrictKeys legacyGroups fallbackNames)
  assemble constructors checked (Specialize.callingSchemes specialized) arities wanted fallback

assemble constructors plans schemas arities typed compatibility=do
  -- Value lookup prefers source bindings to constructors. Keep layout
  -- authority for patterns, but do not manufacture a conflicting value stub.
  let valueBindings=S.fromList [n | TBind n _ _ _<-planSource plans]
  generated<-M.fromList <$> mapM (\n->(n,) <$> constructorDefinition plans n) (S.toAscList (constructors S.\\ valueBindings))
  let functions=typed `M.union` generated
      ownArities=M.map (length . T.functionParameters) functions `M.union` arities
  input<-Program.programWithAssumptions (planNamespace plans) (planTypes plans) schemas ownArities functions (planAssumptions plans)
  unless (S.null (M.keysSet functions `S.intersection` M.keysSet compatibility)) (Left "typed source: checked/compatibility owner collision")
  pure (SourceSelection input compatibility)

constructorDefinition plans name=do
  let Namespace ns=planNamespace plans
      T.TypeContext linears schemas=planTypes plans
  Forall _ _ signature<-maybe (Left ("typed source: missing constructor schema "++name)) Right (M.lookup name schemas)
  let peel (TFn a b)=let (as,r)=peel b in (a:as,r)
      peel t=([],t)
      (fields,result)=peel signature
      ps=[T.Binder (BinderId (Namespace (ns++"/constructor/"++name)) i) ("x"++show (i+1)) (Forall [] [] ty) (linShapeT linears ty)
        | (i,ty)<-zip [0..] fields]
      value b=T.Expr (T.binderType b) (T.binderShape b) T.Generated Nothing (T.Var (T.Local (T.binderId b)))
      body=T.Expr result (linShapeT linears result) T.Generated Nothing (T.Construct name (map value ps))
  pure (T.Function name ps body)

typedFunction :: CheckedPlans -> (String,[([SPat],[SGuard],SExpr)]) -> Maybe T.Function
typedFunction checked group@(name,clauses)=case M.lookup name (planEntries checked) of
  Just (Plan hidden cls expected) | encode clauses==encode expected->
    let args=case cls of
          Clause ps _ _:_->[T.Binder (BinderId (Namespace (ns++"/core/"++name)) i) ("$typed_argument_"++show i)
            (Forall [] [] (T.patType p)) (shape (T.patType p)) | (i,p)<-zip [0..] ps]
          _->error "typed Core: empty clause plan"
        alts=[T.Alternative ps (map lowerGuard gs) (lower b) | Clause ps gs b<-cls]
        body=case cls of Clause _ _ b:_->gen (ty b) (T.Match (T.FunctionMatch name) (map ref args) alts); _->error "empty typed clauses"
        fn=T.Function name (hidden++args) body
    in Just fn
  _->Nothing
  where
    Namespace ns=planNamespace checked
    types=planTypes checked
    T.TypeContext linearTypes constructors=types
    shape=linShapeT linearTypes
    gen t n=T.Expr t (shape t) T.Generated Nothing n
    ty (EP e _)=E.expressionType e
    ref b=gen (T.binderType b) (T.Var (T.Local (T.binderId b)))
    call n t=T.Var (T.Global n (Forall [] [] t))
    apply2 f a b result=T.Apply (gen (TFn (T.exprType b) result) (T.Apply f a)) b
    lowerGuard (Boolean e)=T.BoolGuard (lower e)
    lowerGuard (Matching p e)=T.PatternGuard p (lower e)
    lower (EP e n)=T.Expr (E.expressionType e) (E.expressionTypeShape e) (T.Checked (E.expressionIdentity e)) (E.expressionOffset e) node
      where
        node=case n of
          Ref r->T.Var r
          GeneratedTrap contract->
            let ExprId (Namespace sourceNs) index=E.expressionIdentity e
                parameters=[T.Binder (BinderId (Namespace (sourceNs++"/trap/"++show index)) i)
                  ("$trap_"++show i) (Forall [] [] arg) (shape arg) | (i,arg)<-zip [0..] (trapArguments contract)]
                failure=gen (trapResult contract) (T.Fail (trapMessage (trapOrigin contract)))
                delayed=foldr (\p body->gen (TFn (T.binderType p) (T.exprType body)) (T.Lambda [p] body)) failure parameters
            in T.exprNode delayed
          HiddenReference r args->
            let physical=foldr (TFn . T.exprType) (E.expressionType e) args
                base=gen physical (T.Var r)
                applied=foldl (\f arg->case T.exprType f of
                  TFn _ rest->gen rest (T.Apply f arg)
                  _->error "invalid checked layout application") base args
            in T.exprNode applied
          VectorConstructor builder layout->case builder of
            BuildEmpty->case E.expressionType e of
              TFn unit result->
                let ExprId (Namespace sourceNs) index=E.expressionIdentity e
                    b=T.Binder (BinderId (Namespace (sourceNs++"/vector-unit/"++show index)) 0) "$vectorUnit" (Forall [] [] unit) (shape unit)
                in T.Lambda [b] (gen result (T.VectorBuild BuildEmpty layout))
              _->T.VectorBuild BuildEmpty layout
            _->T.VectorBuild builder layout
          LitInt v->T.IntValue v
          LitString s->T.StringValue s
          LitAtom s->T.AtomValue s
          Application a b->T.Apply (lower a) (lower b)
          Lambda ps b->T.Lambda ps (lower b)
          Binding p ps a b->
            let rhs=lower a
                value=if null ps then rhs else gen (foldr (TFn . T.binderType) (T.exprType rhs) ps) (T.Lambda ps rhs)
            in T.Let p value (lower b)
          RecursiveBinding p ps a b->
            let rhs=lower a
                value=if null ps then rhs else gen (foldr (TFn . T.binderType) (T.exprType rhs) ps) (T.Lambda ps rhs)
            in T.LetRec p value (lower b)
          PatternBinding p a b->T.LetPattern p (lower a) (lower b)
          Pipe a b->T.Apply (lower b) (lower a)
          Sequencing a b->T.Sequence (lower a) (lower b)
          Call2 name a b->let x=lower a;y=lower b;ft=TFn (ty a) (TFn (ty b) (E.expressionType e))
                         in apply2 (gen ft (call name ft)) x y (E.expressionType e)
          OperatorCall f a b->apply2 (lower f) (lower a) (lower b) (E.expressionType e)
          ProjectCall p field a b->let ft=TFn (ty a) (TFn (ty b) (E.expressionType e))
                                  in apply2 (gen ft (T.RecordField (ref p) [field])) (lower a) (lower b) (E.expressionType e)
          ShortCircuit andThen a b->
            let bt=TC "Bool"
                p n=T.Pattern bt ("PCon "++show n++" []") (T.ConstructorPattern n [])
                v n=gen bt (T.Var (T.Global n (Forall [] [] bt)))
                arms=if andThen then [(p "True",lower b),(p "False",v "False")] else [(p "True",v "True"),(p "False",lower b)]
            in T.Match T.CaseMatch [lower a] [T.Alternative [p'] [] x | (p',x)<-arms]
          ResultPipe a b->T.ResultPipe (lower a) (lower b)
          Cons a b->let ft=TFn (ty a) (TFn (ty b) (E.expressionType e))
                   in apply2 (gen ft (call "Cons" ft)) (lower a) (lower b) (E.expressionType e)
          Case a bs->T.Match T.CaseMatch [lower a] [T.Alternative [p] [] (lower b) | (p,b)<-bs]
          Note a->T.Note (lower a)
          Tuple xs->T.TupleValue (map lower xs)
          List xs->T.ListValue (map lower xs)
          Record fs->T.RecordValue [(n,lower x) | (n,x)<-fs]
          Projection a path->T.RecordField (lower a) path
          Update a fs->T.RecordUpdate (lower a) [(path,lower x) | (path,x)<-fs]
          Interpolation ps->let parts=map part ps
                            in case parts of []->T.StringValue ""; x:xs->T.exprNode (foldl concatString x xs)
          RenderApplication f renderer a->
            let x=render renderer (lower a)
                ft=TFn (TC "String") (E.expressionType e)
                EP ff (Ref (T.Global name sc))=f
                callee=T.Expr ft LU (T.Reinstantiated (E.expressionIdentity ff)) (E.expressionOffset ff) (T.Var (T.Global name sc))
            in T.Apply callee x
        part (Left s)=gen (TC "String") (T.StringValue s)
        part (Right (r,x))=let a=maybe (lower x) (\n->render n (lower x)) r
                          in render "str" a
        render name x=let ft=TFn (T.exprType x) (TC "String") in gen (TC "String") (T.Apply (gen ft (call name ft)) x)
        concatString a b=let st=TC "String"; ft=TFn st (TFn st st)
                         in gen st (apply2 (gen ft (call "strcat" ft)) a b st)
