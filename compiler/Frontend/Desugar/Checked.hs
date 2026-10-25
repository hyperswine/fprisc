{-# LANGUAGE LambdaCase, TupleSections #-}
-- Inference-guided typed Core construction. Source patterns keep their actual
-- inferred types and binder IDs; layout lowers only at the explicit untyped
-- compatibility boundary, before the not-yet-migrated transformation passes.
module Frontend.Desugar.Checked
  (CheckedPlans, prepareChecked, checkedNames, checkedDeclines,
   Desugared, desugaredCore, desugaredTyped, desugaredTypeContext,
   compileTopChecked, lowerToUntyped) where
import Core.Identity
import qualified Core.Typed.Syntax as T
import Core.Typed.Erase (Layout(..),eraseFunction)
import Core.Typed.Verify (instanceOf)
import Core.Syntax (Core,Prog)
import Type.Syntax (Type(..),Scheme(..))
import Ownership.Shape (LShape(..))
import Ownership.TypeShape (linShapeT)
import Frontend.Syntax
import Frontend.Desugar (D,DEnv(..),fresh,groupClauses,compileGroup,wideTup)
import Infer.Result
import Infer.Pattern
import qualified Infer.Evidence as E
import Infer.Elaboration
import Precond (checkedName)
import qualified Struct
import Control.Monad (forM,unless)
import Control.Monad.State.Strict (get,modify)
import Data.Binary (encode)
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.Set as S

data PlanningProblem = Deferred String | Corrupt String

data CheckedPlans = Plans Namespace T.TypeContext (M.Map String Plan) [(String,String)]
data Plan = Plan [Clause] [([SPat],[SGuard],SExpr)]
data Clause = Clause [T.Pattern] [GuardPlan] EPlan
data GuardPlan = Boolean EPlan | Matching T.Pattern EPlan
data EPlan = EP E.ExprFact PNode
data PNode = Ref T.Reference | LitInt Integer | LitString String | LitAtom String
  | Application EPlan EPlan | Lambda [T.Binder] EPlan
  | Binding T.Binder [T.Binder] EPlan EPlan | PatternBinding T.Pattern EPlan EPlan
  | Pipe EPlan EPlan | Sequencing EPlan EPlan | Call2 String EPlan EPlan
  | OperatorCall EPlan EPlan EPlan | ProjectCall T.Binder String EPlan EPlan
  | ShortCircuit Bool EPlan EPlan | ResultPipe EPlan EPlan | Cons EPlan EPlan
  | Case EPlan [(T.Pattern,EPlan)] | Note EPlan
  | Tuple [EPlan] | List [EPlan] | Record [(String,EPlan)]
  | Projection EPlan [String] | Update EPlan [([String],EPlan)]
  | Interpolation [Either String (Maybe String,EPlan)] | RenderApplication EPlan String EPlan

checkedNames :: CheckedPlans -> S.Set String
checkedNames (Plans _ _ ps _) = M.keysSet ps
checkedDeclines :: CheckedPlans -> [(String,String)]
checkedDeclines (Plans _ _ _ ds) = ds

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
      binder uid=case M.lookup uid binders of
        Nothing->corrupt "missing checked binder"
        Just b->Right (T.Binder uid (M.findWithDefault (E.binderSpelling b) uid (inferenceBinderNames result)) (E.binderScheme b) (E.binderTypeShape b))
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
          SVar _->case (E.expressionReference e,applySites globals targets (E.expressionRewritten e)) of
            (Just (E.LocalReference _ uid),SVar n)->do
              b<-binder uid
              if n==T.binderName b then make (Ref (T.Local uid)) else defer "local layout reference not yet migrated"
            (Just (E.GlobalReference _ sc),SVar n)->make (Ref (T.Global n sc))
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
                  unless (not (uses (T.binderId b) rhs)) (defer "recursive local awaits typed closure lifting")
                  unless (null (M.findWithDefault [] (T.binderName b) (inferenceLayoutRequirements result))) (defer "local layout parameters not yet migrated")
                  ps<-mapM (\p -> case matchedSource p of PVar v->scoped (matchedBindings p) v; _->corrupt "local parameter derivation") (matchedChildren info)
                  body<-block (index+1) rest more
                  pure (EP e (Binding b ps rhs body))
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
        unless (null (M.findWithDefault [] name (inferenceLayoutRequirements result))) (defer "layout entry parameters not yet migrated")
        let build _ [] []=Right []
            build index ((ps,gs,_):rest) rootFacts=do
              let (here,more)=splitAt (length gs+1) rootFacts
              unless (length here==length gs+1) (corrupt "clause root derivation")
              pats<-mapM (\i -> site (ParameterOf name index i) >>= patternOf) [0..length ps-1]
              guardPlans<-forM (zip3 [0..] gs (take (length gs) here)) $ \(i,g,expr)->case g of
                GBool _->Boolean <$> plan expr
                GPat _ _->do p<-site (GuardOf name index i) >>= patternOf; Matching p <$> plan expr
              b<-plan (last here)
              (Clause pats guardPlans b:) <$> build (index+1) rest more
            build _ _ _=corrupt "clause count derivation"
        cls<-build 0 clauses (M.findWithDefault [] name roots)
        pure (Plan cls clauses)
      answers=[(name,entry name cls) | (name,cls)<-M.toList groups]
      types=T.TypeContext [n | TType n True _ _<-inferenceTops result] (inferenceConstructors result)
  case [(name,why) | (name,Left (Corrupt why))<-answers] of
    (name,why):_->Left ("invalid checked lowering evidence for "++name++": "++why)
    []->pure (Plans (E.evidenceNamespace evidence) types (M.fromList [(n,p) | (n,Right p)<-answers]) [(n,why) | (n,Left (Deferred why))<-answers])
  where
    defer=Left . Deferred
    corrupt=Left . Corrupt
    planType (EP e _)=E.expressionType e
    uses uid (EP _ n)=case n of Ref (T.Local v)->v==uid; _->any (uses uid) (kids n)
    kids n=case n of
      Application a b->[a,b]; Lambda _ b->[b]; Binding _ _ a b->[a,b]; PatternBinding _ a b->[a,b]
      Pipe a b->[a,b]; Sequencing a b->[a,b]; Call2 _ a b->[a,b]; OperatorCall f a b->[f,a,b]
      ProjectCall _ _ a b->[a,b]; ShortCircuit _ a b->[a,b]; ResultPipe a b->[a,b]; Cons a b->[a,b]
      Case a bs->a:map snd bs; Note a->[a]; Tuple xs->xs; List xs->xs; Record fs->map snd fs
      Projection a _->[a]; Update a fs->a:map snd fs
      Interpolation ps->[x | Right (_,x)<-ps]; RenderApplication f _ a->[f,a]
      _->[]

data Desugared=Desugared T.TypeContext Prog (M.Map String T.Function)
desugaredCore :: Desugared -> Prog
desugaredCore (Desugared _ p _)=p
desugaredTyped :: Desugared -> M.Map String T.Function
desugaredTyped (Desugared _ _ p)=p
desugaredTypeContext :: Desugared -> T.TypeContext
desugaredTypeContext (Desugared t _ _)=t
compileTopChecked :: CheckedPlans -> [STop] -> D Desugared
compileTopChecked plans@(Plans ns types _ _) tops=do
  st<-get
  let entries=M.map (\(_,_,arity)->["x"++show i | i<-[1..arity]]) (dCons st)
  constructors<-M.traverseWithKey (constructorFunction ns types) entries
  groups<-mapM (lowerCheckedGroup plans) (groupClauses tops)
  pure (Desugared types (M.union (M.fromList (map fst groups)) (M.map fst constructors)) (M.union (M.fromList [(T.functionName f,f) | (_,Just f)<-groups]) (M.map snd constructors)))
-- Constructor entry points are generated too. Keep their schemas and
-- identities in the same stage product, including nullary/builtin entries.
constructorFunction :: Namespace -> T.TypeContext -> String -> [String] -> D (([String],Core),T.Function)
constructorFunction (Namespace ns) types@(T.TypeContext linears schemas) name names = do
  let Forall _ _ signature=case M.lookup name schemas of
        Just sc->sc
        Nothing->error ("typed Core: missing constructor schema "++name)
      peel (TFn a b)=let (as,r)=peel b in (a:as,r)
      peel t=([],t)
      (fields,result)=peel signature
      ps=[T.Binder (BinderId (Namespace (ns++"/constructor/"++name)) i) n (Forall [] [] ty) (linShapeT linears ty)
         | (i,(n,ty))<-zip [0..] (zip names fields)]
      value b=T.Expr (T.binderType b) (T.binderShape b) T.Generated Nothing (T.Var (T.Local (T.binderId b)))
      body=T.Expr result (linShapeT linears result) T.Generated Nothing (T.Construct name (map value ps))
      fn=T.Function name ps body
  unless (length names==length fields) (error ("typed Core: constructor schema/layout arity "++name))
  st<-get
  out<-eraseFunction types (layoutOf st) fn
  case out of Left why->error why; Right body->pure (body,fn)

layoutOf :: DEnv -> Layout D
layoutOf st=Layout fresh (\c->case M.lookup c (dCons st) of Just x->Just x; _->wideTup c) (dShapes st)
  (\jn ps b->modify (\s->s {dLifted=(jn,ps,b):dLifted s,dJoins=jn:dJoins s}))

lowerToUntyped :: CheckedPlans -> [STop] -> D Prog
lowerToUntyped ps ts=desugaredCore <$> compileTopChecked ps ts

lowerCheckedGroup :: CheckedPlans -> (String,[([SPat],[SGuard],SExpr)]) -> D ((String,([String],Core)),Maybe T.Function)
lowerCheckedGroup (Plans (Namespace ns) types plans _) group@(name,clauses)=case M.lookup name plans of
  Just (Plan cls expected) | encode clauses==encode expected->do
    args<-case cls of
      Clause ps _ _:_->forM (zip [1::Int ..] ps) $ \(i,p)->do
        st<-get; n<-fresh ("a"++show i)
        pure (T.Binder (BinderId (Namespace (ns++"/core/"++name)) (dFresh st)) n (Forall [] [] (T.patType p)) (shape (T.patType p)))
      _->error "typed Core: empty clause plan"
    let alts=[T.Alternative ps (map lowerGuard gs) (lower b) | Clause ps gs b<-cls]
        body=case cls of Clause _ _ b:_->gen (ty b) (T.Match (T.FunctionMatch name) (map ref args) alts); _->error "empty typed clauses"
        fn=T.Function name args body
    st<-get
    erased<-eraseFunction types (layoutOf st) fn
    case erased of Left why->error why; Right out->pure ((name,out),Just fn)
  _->(,Nothing) <$> compileGroup group
  where
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
          LitInt v->T.IntValue v
          LitString s->T.StringValue s
          LitAtom s->T.AtomValue s
          Application a b->T.Apply (lower a) (lower b)
          Lambda ps b->T.Lambda ps (lower b)
          Binding p ps a b->
            let rhs=lower a
                value=if null ps then rhs else gen (foldr (TFn . T.binderType) (T.exprType rhs) ps) (T.Lambda ps rhs)
            in T.Let p value (lower b)
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
