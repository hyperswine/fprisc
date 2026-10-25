-- Remove forwarding-only callback-object parameters without reconstructing
-- escaping function objects. Private arity overflow restores original calls.
module Core.Typed.Callback.Trim (trimCallbacks) where
import Core.Typed.Callback.Model
import Core.Typed.Syntax
import Core.Typed.Walk (mapChildrenM,allBinders,localUses)
import Core.Identity
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import Control.Monad.Identity
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- Original callback-object parameters are provisional until the whole clone
-- graph is available. A least fixpoint removes forwarding-only recursive
-- parameters while retaining every returned, compared or captured object.
trimCallbacks types@(TypeContext linears _) arities schemas templates plans removable root codes=do
  let candidates=M.unions [M.fromSet (const label) ids | (label,ClonePlan _ ids)<-M.toList plans]
      active0=M.keysSet plans
      original=M.keysSet codes S.\\ active0
      run active=do
        let activeCodes=M.restrictKeys codes (original `S.union` active)
            restored=M.map (\f->f {codeBody=restore active (codeBody f)}) activeCodes
            root'=root {functionBody=restore active (functionBody root)}
            activeCandidates=M.filter (`S.member` active) candidates
            candidateIds=M.keysSet activeCandidates
            required=liveParameters restored candidateIds root'
            dead=candidateIds S.\\ required
            tooWide=S.fromList [label | (label,f)<-M.toList restored,label `S.member` active,
              length [b | b<-codeCaptures f++codeParameters f,binderId b `S.notMember` dead]>64]
        if S.null tooWide then pure (root',restored,active,dead) else run (active S.\\ tooWide)
      restore active e=let child=runIdentity (mapChildrenM (pure . restore active) e) in case exprNode child of
        CodeCall label cs ps | label `M.member` plans,label `S.notMember` active->originalCall child label cs ps
        JoinCall label cs ps | label `M.member` plans,label `S.notMember` active->originalCall child label cs ps
        _->child
      originalCall old label cs ps=
        let ClonePlan target _=plans M.! label
            Template captures parameters _ _ kind=templates M.! target
            caps=take (length captures) cs
            args=take (length parameters) ps
        in case target of
          CodeTarget targetId->old {exprNode=if kind==JoinCode then JoinCall targetId caps args else CodeCall targetId caps args}
          RootTarget name->
            let ty=foldr (TFn . exprType) (exprType old) args
                head'=Expr ty (linShapeT linears ty) Generated Nothing (Var (Global name (schemas M.! name)))
                app f a=case exprType f of
                  TFn _ r->Expr r (linShapeT linears r) Generated Nothing (Apply f a)
                  _->error "typed callbacks: restored arrow"
            in (foldl app head' args) {exprOrigin=exprOrigin old,exprOffset=exprOffset old}
      liveParameters graph candidateIds root'=fix S.empty
        where
          functions=root':map codeAsFunction (M.elems graph)
          fix live=let used=S.unions [uses graph candidateIds live M.empty (functionBody f) | f<-functions]
                       next=used `S.intersection` candidateIds
                   in if next==live then live else fix next
      uses graph candidateIds live aliases e=case exprNode e of
        Var (Local uid)->S.singleton (resolve aliases uid)
        ClosureValue _ cs->S.fromList (map (resolve aliases) cs)
        Let b rhs body->case exprNode (unNote rhs) of
          Var (Local uid)->uses graph candidateIds live (M.insert (binderId b) (resolve aliases uid) aliases) body
            <>if droppable graph b rhs then S.empty else S.singleton (resolve aliases uid)
          _->let bodyUses=uses graph candidateIds live aliases body
             in (S.delete (binderId b) bodyUses) `S.union`
                (if binderId b `S.member` bodyUses || not (droppable graph b rhs) then uses graph candidateIds live aliases rhs else S.empty)
        CodeCall label cs ps->callUses graph candidateIds live aliases label cs ps
        JoinCall label cs ps->callUses graph candidateIds live aliases label cs ps
        MatchTail (FunctionMatch _) args alternatives fallback->
          let simple p=case patNode p of Bind _->True;Wildcard->True;_->False
              neededArg i=any (\(Alternative ps _ _)->not (simple (ps!!i))) alternatives
              retainedArgs=S.unions [uses graph candidateIds live aliases a | (i,a)<-zip [0..] args,neededArg i]
              branch (Alternative ps guards body)=
                let scope=foldl (\env (p,a)->case (patNode p,exprNode (unNote a)) of
                      (Bind b,Var (Local uid))->M.insert (binderId b) (resolve env uid) env
                      _->env) aliases (zip ps args)
                    guardUses g=case g of BoolGuard x->uses graph candidateIds live scope x;PatternGuard _ x->uses graph candidateIds live scope x
                in S.unions (uses graph candidateIds live scope body:map guardUses guards)
          in retainedArgs<>S.unions (map branch alternatives)<>uses graph candidateIds live aliases fallback
        _->getConst (mapChildrenM (Const . uses graph candidateIds live aliases) e)
      callUses graph candidateIds live aliases label cs ps=case M.lookup label graph of
        Just f->S.unions
          ([S.singleton (resolve aliases uid) | (b,uid)<-zip (codeCaptures f) cs,needed b]
           ++[uses graph candidateIds live aliases x | (b,x)<-zip (codeParameters f) ps,needed b])
        Nothing->S.fromList (map (resolve aliases) cs)<>S.unions (map (uses graph candidateIds live aliases) ps)
        where needed b=binderId b `S.notMember` candidateIds || binderId b `S.member` live
      resolve aliases uid=case M.lookup uid aliases of Just next | next/=uid->resolve aliases next;_->uid
      droppable graph b rhs=binderId b `S.member` removable && pureValue graph rhs
      pureValue graph e=case exprNode (unNote e) of
        Var (Local _)->True
        Var (Global name _)->maybe False (>0) (M.lookup name arities)
        ClosureValue label _->maybe False ((==ClosureCode) . codeKind) (M.lookup label graph)
        Apply {}->let (h,args)=spine e []
                      n=case exprNode h of
                        Var (Global name _)->M.lookup name arities
                        ClosureValue label _->length . codeParameters <$> M.lookup label graph
                        _->Nothing
                  in maybe False (>length args) n && all (evaluated arities) args
        IntValue _->True;StringValue _->True;BoolValue _->True;LayoutLiteral _->True
        _->False
  (root0,graph,active,dead)<-run active0
  let dummyLabels=S.fromList [label | (label,f)<-M.toList graph,codeKind f==JoinCode,
        all ((`S.member` dead) . binderId) (codeCaptures f++codeParameters f)]
      existing=[b | f<-root0:map codeAsFunction (M.elems graph),b<-functionParameters f++allBinders (functionBody f)]
      globalNames e=(case exprNode e of Var (Global n _)->S.singleton n;_->S.empty)
        <>getConst (mapChildrenM (Const . globalNames) e)
      reservedNames=S.fromList (map binderName existing++map functionName (root0:map codeAsFunction (M.elems graph)))
        <>S.unions (map (globalNames . functionBody) (root0:map codeAsFunction (M.elems graph)))
      dummy label=head [Binder uid name (Forall [] [] (TC "Int")) (linShapeT linears (TC "Int"))
        | n<-[0..],let uid=BinderId (Namespace ("callback-join/"++show label)) n,
          let name="$typed_cb_join_unit_"++show n,
          all ((/=uid) . binderId) existing,name `S.notMember` reservedNames]
      rewrite e=let child=runIdentity (mapChildrenM (pure . rewrite) e) in case exprNode child of
        CodeCall label cs ps->child {exprNode=CodeCall label (keepCaps label cs) (keepArgs label ps)}
        JoinCall label cs ps->child {exprNode=JoinCall label (keepCaps label cs) (keepArgs label ps)}
        _->child
      keepCaps label cs=case M.lookup label graph of
        Just f->[uid | (b,uid)<-zip (codeCaptures f) cs,binderId b `S.notMember` dead]
        _->cs
      keepArgs label ps=let args=case M.lookup label graph of
                              Just f->[x | (b,x)<-zip (codeParameters f) ps,binderId b `S.notMember` dead]
                              _->ps
                        in args++[Expr (TC "Int") (linShapeT linears (TC "Int")) Generated Nothing (IntValue 0) | label `S.member` dummyLabels]
      cleanup e=let child=runIdentity (mapChildrenM (pure . cleanup) e) in case exprNode child of
        Let b rhs body | binderId b `notElem` localUses body,droppable graph b rhs->body
        MatchTail style@(FunctionMatch _) args alternatives fallback->
          let unused p guards body=case patNode p of
                Wildcard->True
                Bind b->binderId b `notElem` (localUses body++concat [localUses x | g<-guards,x<-case g of BoolGuard e->[e];PatternGuard _ e->[e]])
                _->False
              removable i a=case exprNode (unNote a) of
                Var (Local uid)->uid `S.member` dead && all (\(Alternative ps gs body)->unused (ps!!i) gs body) alternatives
                _->False
              keep=[i | (i,a)<-zip [0..] args,not (removable i a)]
              project (Alternative ps gs body)=Alternative [p | (i,p)<-zip [0..] ps,i `elem` keep] gs body
          in child {exprNode=MatchTail style [a | (i,a)<-zip [0..] args,i `elem` keep] (map project alternatives) fallback}
        _->child
      update label f=f {codeCaptures=filter ((`S.notMember` dead) . binderId) (codeCaptures f),
        codeParameters=filter ((`S.notMember` dead) . binderId) (codeParameters f)++[dummy label | label `S.member` dummyLabels],
        codeBody=cleanup (rewrite (codeBody f))}
  pure (root0 {functionBody=cleanup (rewrite (functionBody root0))},M.mapWithKey update graph,active)
