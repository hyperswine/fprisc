{-# LANGUAGE FlexibleContexts #-}
-- Fuse std List chains before callback specialization: fold/sum/product/length
-- consume map/filter/range pipelines without the intermediate lists,
-- map/filter transformers compose (both same-kind and cross-kind), and
-- producer-only map over range collapses to a single-pass builder. Candidate
-- globals are shape-verified against their catalog templates (std/list's
-- content hash changes on every edit, so a name alone is not an identity);
-- safety evidence and the Int-overflow relaxation are Core.FusionPolicy's.
module Core.Typed.ListFusion (fuseListClosed) where
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Callback.Catalog
import Core.Typed.Callback.Model
import qualified Core.Typed.FusionSafety as Safety
import Core.Typed.Fusion (FusionNote(..),Decline(..))
import Core.FusionPolicy (safePrimitives)
import Core.Primitives (primArities)
import Core.Typed.Walk (allBinders,mapChildrenM)
import Core.Identity
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import Control.Monad.State.Strict
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Kind
  = KFold | KMap | KFilter | KMapFilter | KFilterMapped
  | KMapRange | KLengthRange | KRange | KSum | KProduct | KLength
  deriving (Eq,Show)
data Composition
  = FoldMap | FoldFilter | MapMap | FilterFilter
  | MapFilter | FilterMap | LengthMap | LengthFilter | MapRange
  deriving (Eq,Show)
-- old, combinator, head, arguments (fold: [f,z,xs]; map/filter: [f,xs];
-- mapFilter/filterMapped: [f,g,xs]; sum/product/length: [xs]; range: [a,b]),
-- then the peeled safe-let prefix.
data Site=Site Expr Kind Expr [Expr] [(Binder,Expr)]
data Callback=Callback Target Expr [(Expr,Scheme)] Int [Expr]
data Build=Build Int (M.Map CodeId CodeFunction) [FusionNote] (M.Map String Bool) Bool

-- Capture-aware occurrence counts: ClosureValue/CodeCall/JoinCall capture
-- lists are uses exactly like Var references, so a value consumed by a
-- synthesized closure still counts. Over-counting only declines fusion.
countUses :: Expr -> M.Map BinderId Int
countUses e=here<>getConst (mapChildrenM (Const . countUses) e)
  where
    here=case exprNode e of
      Var (Local uid)->M.singleton uid 1
      ClosureValue _ captures->M.fromList [(u,1)|u<-captures]
      CodeCall _ captures _->M.fromList [(u,1)|u<-captures]
      JoinCall _ captures _->M.fromList [(u,1)|u<-captures]
      _->M.empty

fuseListClosed :: Namespace -> TypeContext -> Catalog -> CodeLibrary -> ClosedFunction -> Either String (ClosedFunction,[FusionNote],Bool)
fuseListClosed (Namespace namespace) types@(TypeContext linears _) snapshot library input=do
  let source=mergeClosedLibrary library input
  ((root,codes),Build _ added notes _ changed)<-runStateT (pass (closedRoot source) (closedCode source)) (Build 0 M.empty [] M.empty False)
  if not changed then pure (input,notes,False)
  else do
    result<-rewriteClosed types (\_ _->Right (root,codes)) source
    pure (result,notes,True)
  where
    safety=Safety.planSafety (catalogTemplates snapshot)
    owner=functionName (closedRoot input)
    aliases=M.unions [bindings (functionBody f) | f<-closedRoot input:map codeAsFunction (M.elems (closedCode input))]
    counts=M.unionsWith (+) [countUses (functionBody f) | f<-closedRoot input:map codeAsFunction (M.elems (closedCode input))]
    bindings e=(case exprNode e of Let b rhs _->M.singleton (binderId b) rhs;_->M.empty)
      <>getConst (mapChildrenM (Const . bindings) e)
    -- Resolve only value operands, exactly as checked vector fusion does.
    resolve seen e=case exprNode (unNote e) of
      Var (Local uid) | uid `S.notMember` seen,Just rhs<-M.lookup uid aliases,
        let (head',args)=spine rhs [],all ready args->
          let value=resolve (S.insert uid seen) head'
          in case exprNode (unNote value) of
            Var (Global _ _)->foldl (apply e) value args
            ClosureValue {}->foldl (apply e) value args
            _->e
      _->e
    ready e=case exprNode (unNote e) of
      Var (Local _)->True
      IntValue _->True;StringValue _->True;BoolValue _->True
      _->False
    gen old ty node=Expr ty (linShapeT linears ty) Generated (exprOffset old) node
    ref old b ty=gen old ty (Var (Local (binderId b)))
    local old b=ref old b (binderType b)
    bind old (b,rhs) body=gen old (exprType body) (Let b rhs body)
    apply old fn arg=case exprType fn of
      TFn _ result->gen old result (Apply fn arg)
      _->error "list fusion: checked callback lost its arrow"
    pass root codes=do
      root'<-function root
      codes'<-traverse (\code->do
        changed<-function (codeAsFunction code)
        pure code {codeBody=functionBody changed}) codes
      Build _ added _ _ _<-get
      pure (root',codes' `M.union` added)
    function fn=do
      floated<-floatProducer (functionBody fn)
      let scope0=M.fromList [(binderId b,b) | b<-functionParameters fn++allBinders floated]
      folded<-go scope0 floated
      let scope1=M.fromList [(binderId b,b) | b<-functionParameters fn++allBinders folded]
      crossed<-goCross scope1 folded
      let scope2=M.fromList [(binderId b,b) | b<-functionParameters fn++allBinders crossed]
      body<-goRange scope2 crossed
      pure fn {functionBody=body}
    -- Float single-use let-bound producers to their use position before the
    -- site walk: the producer's evaluation then moves across only movable
    -- work (FusionPolicy-safe, or a bare function value, whose body runs
    -- only when a combinator calls it), so the float is observationally
    -- equivalent even when the later composition declines. Directly nested
    -- sites, chained bindings and uses under arbitrary expressions (a
    -- `print (sum r)`) all reduce to the same nested spine afterwards.
    floatProducer e=case exprNode (unNote e) of
      Let b rhs rest
        | Just (Site _ kind _ _ _)<-site rhs,kind `elem` [KRange,KMap,KFilter]
        -- a binder's occurrences cannot leave its binding's scope, so the
        -- whole-program count is exactly the count in the body
        , M.lookup (binderId b) counts==Just 1
        , Just rest'<-tryFloat (binderId b) rhs rest
        , M.notMember (binderId b) (countUses rest')->do
            modify (\(Build n cs ns v _)->Build n cs ns v True)
            floatProducer rest'
      _->mapChildrenM floatProducer e
    -- Replace binder uid's single occurrence with the producer. Only
    -- positions that always run are entered, so the producer still runs
    -- exactly when it ran before; children are visited in evaluation order
    -- and the producer may move behind earlier siblings only while they are
    -- movable. A use under a lambda, a capture list, a match, a conditional
    -- branch (if, and, or), the body of a refutable pattern binding, the
    -- right side of a result pipeline or an update branch refuses the float,
    -- as does every node not listed here.
    tryFloat uid producer e=case exprNode e of
      Note x->(\x'->e {exprNode=Note x'}) <$> tryFloat uid producer x
      Var (Local u)|u==uid->Just producer
      If c t f
        | uses t||uses f->Nothing
        | otherwise->(\c'->e {exprNode=If c' t f}) <$> tryFloat uid producer c
      LetPattern p _ body
        | uses body&&not (irrefutable p)->Nothing
        | otherwise->inOrder
      ResultPipe x rest
        | uses rest->Nothing
        | otherwise->(\x'->e {exprNode=ResultPipe x' rest}) <$> tryFloat uid producer x
      PlannedUpdate x plan
        | M.member uid (countUses x)&&M.findWithDefault 0 uid (countUses x)==M.findWithDefault 0 uid (countUses e)->
            (\x'->e {exprNode=PlannedUpdate x' plan}) <$> tryFloat uid producer x
        | otherwise->Nothing
      CodeCall _ captures _|uid `elem` captures->Nothing
      JoinCall _ captures _|uid `elem` captures->Nothing
      node|alwaysRuns node->inOrder
      _->Nothing
      where
        uses x=M.member uid (countUses x)
        inOrder=fst <$> runStateT (mapChildrenM child e) True
        child x=do
          ok<-get
          x'<-if uses x
                then if ok then maybe (lift Nothing) pure (tryFloat uid producer x)
                     else lift Nothing
                else pure x
          put (ok && movable x)
          pure x'
    -- strict nodes whose children all run, in order
    alwaysRuns node=case node of
      Apply {}->True;Let {}->True;LetRec {}->True;Sequence {}->True
      Construct {}->True;TupleValue {}->True;ListValue {}->True;RecordValue {}->True
      RecordField {}->True;RecordUpdate {}->True;BoolTest {}->True
      CodeCall {}->True;JoinCall {}->True
      _->False
    irrefutable p=case patNode p of
      Bind _->True;Wildcard->True;RecordPattern _->True
      TuplePattern ps->all irrefutable ps
      _->False
    movable e=case exprNode (unNote e) of
      ClosureValue {}->True
      Var (Global _ _)->True
      _->case spine (unNote e) [] of
        (head',args)|Var (Global name _)<-exprNode (unNote head'),underApplied name args->all movable args
        _->Safety.unsafeExpression safety e==Nothing
    -- A partial application only allocates the function value; the body or
    -- primitive runs when a combinator saturates it, an interleaving the
    -- composition rules already rule on. Saturated calls keep FusionSafety's
    -- judgment (an unknown or exact-arity call is not movable by itself).
    underApplied name args
      | Just (Template _ ps _ _ _)<-M.lookup (RootTarget name) (catalogTemplates snapshot)=length args<length ps
      | Just arity<-lookup name primArities=name `elem` safePrimitives&&length args<arity
      | otherwise=False
    go scope e=mapChildrenM (go scope) e >>= \e'->case site e' of
      Nothing->pure e'
      Just s->do
        rewritten<-fuseSite scope s
        maybe (pure e') (go scope) rewritten
    goCross scope e=mapChildrenM (goCross scope) e >>= \e'->case site e' of
      Nothing->pure e'
      Just s->do
        rewritten<-fuseCross scope s
        maybe (pure e') (goCross scope) rewritten
    goRange scope e=mapChildrenM (goRange scope) e >>= \e'->case site e' of
      Nothing->pure e'
      Just s->do
        rewritten<-fuseRange scope s
        pure (maybe e' id rewritten)
    globalName e=case exprNode (unNote e) of Var (Global n _)->n;_->""
    baseName name=takeWhile (/='@') name
    moduleHash name=case dropWhile (/='@') name of '@':h->h;_->""
    kindOf name=case baseName name of
      "fold"->Just KFold;"map"->Just KMap;"filter"->Just KFilter
      "mapFilter"->Just KMapFilter;"filterMapped"->Just KFilterMapped
      "mapRange"->Just KMapRange;"lengthRange"->Just KLengthRange
      "sum"->Just KSum;"product"->Just KProduct;"length"->Just KLength
      "range"->Just KRange
      _->Nothing
    site e=peel [] e
      where
        peel prefix old=case exprNode (unNote old) of
          Let b rhs rest | Safety.unsafeExpression safety rhs==Nothing->peel (prefix++[(b,rhs)]) rest
          _->case spine old [] of
            (head',args)|Var (Global name _)<-exprNode head'->case (kindOf name,args) of
              (Just KFold,[_,_,_])->Just (Site e KFold head' args prefix)
              (Just KMap,[_,_])->Just (Site e KMap head' args prefix)
              (Just KFilter,[_,_])->Just (Site e KFilter head' args prefix)
              (Just KMapFilter,[_,_,_])->Just (Site e KMapFilter head' args prefix)
              (Just KFilterMapped,[_,_,_])->Just (Site e KFilterMapped head' args prefix)
              (Just KSum,[_])->Just (Site e KSum head' args prefix)
              (Just KProduct,[_])->Just (Site e KProduct head' args prefix)
              (Just KLength,[_])->Just (Site e KLength head' args prefix)
              (Just KRange,[_,_])->Just (Site e KRange head' args prefix)
              _->Nothing
            _->Nothing
    template key=do
      Build _ added _ _ _<-get
      pure $ case key of
        CodeTarget label | Just code<-M.lookup label added->
          Just (Template (codeCaptures code) (codeParameters code) (codeBody code) (codeContract code) ClosureCode)
        _->M.lookup key (catalogTemplates snapshot)
    safeTarget key=do
      Build _ added _ _ _<-get
      pure $ case key of
        CodeTarget label | M.member label added->Nothing
        _->Safety.unsafeTarget safety key
    -- a callback this pass generated was admitted with ordinary evidence only
    safeTargetStrict key=do
      Build _ added _ _ _<-get
      pure $ case key of
        CodeTarget label | M.member label added->Just (Safety.Unsupported "a callback generated by fusion")
        _->Safety.unsafeTargetStrict safety key
    callback arity scope expr=do
      let (original,arguments)=spine expr []
          (resolved,leading')=spine (resolve S.empty original) []
          leading=leading'++arguments
          head'=gen resolved (foldr (TFn . exprType) (exprType expr) leading) (exprNode resolved)
          initial=case exprNode head' of
            Var (Global name _)->Just (RootTarget name,[])
            ClosureValue key ids->do
              bs<-mapM (`M.lookup` scope) ids
              pure (CodeTarget key,[(local head' b,binderScheme b) | b<-bs])
            _->Nothing
      case initial of
        Nothing->pure Nothing
        Just (key,captured)->do
          source<-template key
          pure $ case source of
            Just (Template caps ps _ _ ClosureCode)
              | length caps==length captured,length ps==length leading+arity->
                Just (Callback key head' (captured++map ordinary leading) (length captured) leading)
            Just (Template [] ps _ _ EntryCode)
              | null captured,length ps==length leading+arity->
                Just (Callback key head' (map ordinary leading) 0 leading)
            _->Nothing
      where
        ordinary x=(x,case exprNode (unNote x) of
          Var (Local uid) | Just b<-M.lookup uid scope->binderScheme b
          _->Forall [] [] (exprType x))
    fuseSite scope (Site old kind head' args prefix)=case (kind,args) of
      (KFold,[f,z,src])->foldWith scope old head' f z src prefix
      (KSum,[src])->expandFold scope old "sum" head' src prefix
      (KProduct,[src])->expandFold scope old "product" head' src prefix
      (KLength,[src])->lengthWith scope old head' src prefix
      (KMap,[f,src])->transformWith scope old KMap head' f src prefix
      (KFilter,[p,src])->transformWith scope old KFilter head' p src prefix
      _->pure Nothing
    -- sum/product are one-line fold wrappers; splice the checked body (its
    -- +/* closure included) instead of synthesizing primitive callbacks.
    expandFold scope old which head' src prefix
      | Just _<-site src=do
          verifiedWrapper<-verified (globalName head') (if which=="sum" then KSum else KProduct)
          if not verifiedWrapper then pure Nothing else do
            source<-template (RootTarget (which++"@"++moduleHash (globalName head')))
            case source of
              Just (Template [] [param] body _ EntryCode)->
                case functionClause [param] body of
                  Just ([param'],body')->case spine (strip body') [] of
                    (h,[f,z,v])|kindOf (globalName h)==Just KFold,isLocalOf param' v->
                      fuseSite scope (Site old KFold h [f,z,src] prefix)
                    _->pure Nothing
                  _->pure Nothing
              _->pure Nothing
      | otherwise=pure Nothing
    isLocalOf b e=case exprNode (unNote e) of Var (Local uid)->uid==binderId b;_->False
    strip e=case exprNode (unNote e) of
      Let _ rhs rest | Safety.unsafeExpression safety rhs==Nothing->strip rest
      _->unNote e
    foldWith scope old head' f z src prefix=do
      foldOk<-verified (globalName head') KFold
      if not foldOk then pure Nothing else case site src of
        Just (Site _ KRange rh [a,b] innerPrefix)->do
          rangeOk<-verified (globalName rh) KRange
          if not rangeOk then pure Nothing else do
            -- The fold callback needs no safety evidence here: the only
            -- producer-side effect is range's own admitted Int overflow.
            let accTy=exprType old
                intTy=TC "Int"
                ty=TFn (TFn accTy (TFn intTy accTy)) (TFn accTy (TFn intTy (TFn intTy accTy)))
                fr=gen old ty (Var (Global ("foldRange@"++moduleHash (globalName rh)) (Forall [] [] ty)))
                call=foldl (apply old) fr [f,z,a,b]
            modify (\(Build n cs ns v _)->Build n cs ns v True)
            pure (Just (foldr (bind old) call (prefix++innerPrefix)))
        Just (Site _ KMap mh [g,src'] innerPrefix)->
          composeTwo scope old KFold head' f (Just z) mh g src' (prefix++innerPrefix) FoldMap
        Just (Site _ KFilter ph [p,src'] innerPrefix)->
          composeTwo scope old KFold head' f (Just z) ph p src' (prefix++innerPrefix) FoldFilter
        _->pure Nothing
    lengthWith scope old head' src prefix=do
      lenOk<-verified (globalName head') KLength
      if not lenOk then pure Nothing else case site src of
        Just (Site _ KRange rh [a,b] innerPrefix)->do
          rangeOk<-verified (globalName rh) KRange
          let lrName="lengthRange@"++moduleHash (globalName rh)
          lrOk<-verified lrName KLengthRange
          if not (rangeOk&&lrOk) then pure Nothing else do
            let intTy=TC "Int"
                ty=TFn intTy (TFn intTy intTy)
                lrSc=M.findWithDefault (Forall [] [] ty) lrName (catalogSchemas snapshot)
                lr=gen old ty (Var (Global lrName lrSc))
                call=foldl (apply old) lr [a,b]
            modify (\(Build n cs ns v _)->Build n cs ns v True)
            pure (Just (foldr (bind old) call (prefix++innerPrefix)))
        Just (Site _ KMap mh [f,src'] innerPrefix)->do
          mapOk<-verified (globalName mh) KMap
          if not mapOk then pure Nothing else do
            let prefixes=prefix++innerPrefix
                scope'=foldl (\s (b,_)->M.insert (binderId b) b s) scope prefixes
            checked<-checkSingle scope' (globalName head') f LengthMap
            case checked of
              Nothing->pure Nothing
              Just _->do
                let ty=TFn (exprType src') (TC "Int")
                    lnName=globalName head'
                    lnSc=M.findWithDefault (Forall [] [] ty) lnName (catalogSchemas snapshot)
                    ln=gen head' ty (Var (Global lnName lnSc))
                    call=apply old ln src'
                modify (\(Build n cs ns v _)->Build n cs ns v True)
                pure (Just (foldr (bind old) call prefixes))
        Just (Site _ KFilter ph [p,src'] innerPrefix)->do
          filterOk<-verified (globalName ph) KFilter
          let foldName="fold@"++moduleHash (globalName head')
          foldOk<-verified foldName KFold
          if not (filterOk&&foldOk) then pure Nothing else do
            let prefixes=prefix++innerPrefix
                scope'=foldl (\s (b,_)->M.insert (binderId b) b s) scope prefixes
            checked<-checkSingle scope' (globalName head') p LengthFilter
            case checked of
              Nothing->pure Nothing
              Just cb->Just <$> lengthFilter old foldName src' cb prefixes
        _->pure Nothing
    transformWith scope old kind head' f src prefix=case site src of
      Just (Site _ KMap mh [g,src'] innerPrefix)|kind==KMap->
        composeTwo scope old KMap head' f Nothing mh g src' (prefix++innerPrefix) MapMap
      Just (Site _ KFilter ph [q,src'] innerPrefix)|kind==KFilter->
        composeTwo scope old KFilter head' f Nothing ph q src' (prefix++innerPrefix) FilterFilter
      _->pure Nothing
    -- Cross-kind map/filter composition on remaining list-producing chains.
    fuseCross scope (Site old kind head' [f,src] prefix)=case (kind,site src) of
      (KMap,Just (Site _ KFilter ph [p,src'] innerPrefix))->do
        outerOk<-verified (globalName head') KMap
        innerOk<-verified (globalName ph) KFilter
        let mfName="mapFilter@"++moduleHash (globalName head')
        mfOk<-verified mfName KMapFilter
        if not (outerOk&&innerOk&&mfOk) then pure Nothing else do
          let prefixes=prefix++innerPrefix
              scope'=foldl (\s (b,_)->M.insert (binderId b) b s) scope prefixes
          checked<-checkTwo scope' f p MapFilter
          case checked of
            Nothing->pure Nothing
            Just _->do
              let ty=TFn (exprType f) (TFn (exprType p) (TFn (exprType src') (exprType old)))
                  mfSc=M.findWithDefault (Forall [] [] ty) mfName (catalogSchemas snapshot)
                  mf=gen old ty (Var (Global mfName mfSc))
                  call=foldl (apply old) mf [f,p,src']
              modify (\(Build n cs ns v _)->Build n cs ns v True)
              pure (Just (foldr (bind old) call prefixes))
      (KFilter,Just (Site _ KMap mh [g,src'] innerPrefix))->do
        outerOk<-verified (globalName head') KFilter
        innerOk<-verified (globalName mh) KMap
        let fmName="filterMapped@"++moduleHash (globalName head')
        fmOk<-verified fmName KFilterMapped
        if not (outerOk&&innerOk&&fmOk) then pure Nothing else do
          let prefixes=prefix++innerPrefix
              scope'=foldl (\s (b,_)->M.insert (binderId b) b s) scope prefixes
          checked<-checkTwo scope' f g FilterMap
          case checked of
            Nothing->pure Nothing
            Just _->do
              let ty=TFn (exprType f) (TFn (exprType g) (TFn (exprType src') (exprType old)))
                  fmSc=M.findWithDefault (Forall [] [] ty) fmName (catalogSchemas snapshot)
                  fm=gen old ty (Var (Global fmName fmSc))
                  call=foldl (apply old) fm [f,g,src']
              modify (\(Build n cs ns v _)->Build n cs ns v True)
              pure (Just (foldr (bind old) call prefixes))
      _->pure Nothing
    fuseCross _ _=pure Nothing
    -- Producer-only map over range (after consumer and cross-transformer passes).
    fuseRange scope (Site old KMap head' [f,src] prefix)=case site src of
      Just (Site _ KRange rh [a,b] innerPrefix)->do
        mapOk<-verified (globalName head') KMap
        rangeOk<-verified (globalName rh) KRange
        let mrName="mapRange@"++moduleHash (globalName rh)
        mrOk<-verified mrName KMapRange
        if not (mapOk&&rangeOk&&mrOk) then pure Nothing else do
          let prefixes=prefix++innerPrefix
              scope'=foldl (\s (b,_)->M.insert (binderId b) b s) scope prefixes
          checked<-checkSingle scope' (globalName head') f MapRange
          case checked of
            Nothing->pure Nothing
            Just _->do
              let intTy=TC "Int"
                  ty=TFn (exprType f) (TFn intTy (TFn intTy (exprType old)))
                  mrSc=M.findWithDefault (Forall [] [] ty) mrName (catalogSchemas snapshot)
                  mr=gen old ty (Var (Global mrName mrSc))
                  call=foldl (apply old) mr [f,a,b]
              modify (\(Build n cs ns v _)->Build n cs ns v True)
              pure (Just (foldr (bind old) call prefixes))
      _->pure Nothing
    fuseRange _ _=pure Nothing
    -- length after map never calls the callback. The Int-overflow relaxation
    -- lets fusion move where an overflow traps, never drop it, so that rule
    -- takes the strict (no overflow) evidence. (mapRange calls its callback
    -- from the top of the range down: an overflow still traps, at another
    -- element, which is the relaxation; tests/check_list_fusion.py pins it.)
    checkSingle scope' outerName innerCb composition=do
      ic<-callback 1 scope' innerCb
      let strict=composition==LengthMap
          capture=if strict then Safety.unsafeExpressionStrict safety else Safety.unsafeExpression safety
      case ic of
        Just b@(Callback innerKey _ bc _ _)->do
          g<-if strict then safeTargetStrict innerKey else safeTarget innerKey
          let refusal=case g of
                Just why->Just (CallbackEffect (targetName innerKey) why)
                _ | any ((/=Nothing) . capture . fst) bc->Just CaptureEffect
                  | length bc>7->Just CaptureBudget
                  | otherwise->Nothing
          case refusal of
            Just why->do
              modify (\(Build n cs ns v changed)->Build n cs (ListNote owner (compositionName composition) outerName (targetName innerKey) why:ns) v changed)
              pure Nothing
            Nothing->pure (Just b)
        _->pure Nothing
    checkTwo scope' outerCb innerCb composition=do
      oc<-callback 1 scope' outerCb
      ic<-callback 1 scope' innerCb
      case (oc,ic) of
        (Just a@(Callback outerKey _ ac _ _),Just b@(Callback innerKey _ bc _ _))->do
          g<-safeTarget innerKey;f<-safeTarget outerKey
          let refusal=case (g,f) of
                (Just why,_)->Just (CallbackEffect (targetName innerKey) why)
                (_,Just why)->Just (CallbackEffect (targetName outerKey) why)
                _ | any ((/=Nothing) . Safety.unsafeExpression safety . fst) (ac++bc)->Just CaptureEffect
                  | length ac+length bc>7->Just CaptureBudget
                  | otherwise->Nothing
          case refusal of
            Just why->do
              modify (\(Build n cs ns v changed)->Build n cs (ListNote owner (compositionName composition) (targetName outerKey) (targetName innerKey) why:ns) v changed)
              pure Nothing
            Nothing->pure (Just (a,b))
        _->pure Nothing
    composeTwo scope old consumerKind consumerHead outerCb seed innerHead innerCb innerSrc prefixes composition=do
      outerOk<-verified (globalName consumerHead) consumerKind
      innerOk<-verified (globalName innerHead) (case composition of FoldMap->KMap;FoldFilter->KFilter;MapMap->KMap;FilterFilter->KFilter;_->KMap)
      if not (outerOk&&innerOk) then pure Nothing else do
        let scope'=foldl (\s (b,_)->M.insert (binderId b) b s) scope prefixes
            arity=case consumerKind of KFold->2;_->1
        oc<-callback arity scope' outerCb
        ic<-callback 1 scope' innerCb
        case (oc,ic) of
          (Just a@(Callback outerKey _ ac _ _),Just b@(Callback innerKey _ bc _ _))->do
            g<-safeTarget innerKey;f<-safeTarget outerKey
            let refusal=case (g,f) of
                  (Just why,_)->Just (CallbackEffect (targetName innerKey) why)
                  (_,Just why)->Just (CallbackEffect (targetName outerKey) why)
                  _ | any ((/=Nothing) . Safety.unsafeExpression safety . fst) (ac++bc)->Just CaptureEffect
                    | length ac+length bc>7->Just CaptureBudget
                    | otherwise->Nothing
            case refusal of
              Just why->do
                modify (\(Build n cs ns v changed)->Build n cs (ListNote owner (compositionName composition) (targetName outerKey) (targetName innerKey) why:ns) v changed)
                pure Nothing
              Nothing->Just <$> composite scope' old consumerHead seed innerSrc a b composition prefixes
          _->pure Nothing
    targetName (RootTarget n)=n
    targetName (CodeTarget (CodeId n))=n
    compositionName FoldMap="fold after map"
    compositionName FoldFilter="fold after filter"
    compositionName MapMap="map after map"
    compositionName FilterFilter="filter after filter"
    compositionName MapFilter="map after filter"
    compositionName FilterMap="filter after map"
    compositionName LengthMap="length after map"
    compositionName LengthFilter="length after filter"
    compositionName MapRange="map after range"
    lengthFilter old foldName innerSrc b@(Callback _ _ bc _ _) prefixes=do
      let count=length bc
      (label,ns)<-fresh (2*count+length prefixes+2)
      let spelling i=targetName (CodeTarget label)++".$"++show i
          capture i (_,scheme)=Binder (BinderId ns i) (spelling i) scheme
            (linShapeT linears (case scheme of Forall _ _ ty->ty))
          capsB=zipWith capture [0..] bc
          elementTy=case exprType innerSrc of
            TAp (TC "List") element->element
            _->error "list fusion: source lost its checked List type"
          intTy=TC "Int"
          lane=Binder (BinderId ns count) (spelling count) (Forall [] [] elementTy) (linShapeT linears elementTy)
          laneVar=local old lane
          acc=Binder (BinderId ns (count+1)) (spelling (count+1)) (Forall [] [] intTy) (linShapeT linears intTy)
          plusTy=TFn intTy (TFn intTy intTy)
          plusSc=M.findWithDefault (Forall [] [] plusTy) "+" (catalogSchemas snapshot)
          plusFn=gen old plusTy (Var (Global "+" plusSc))
          inc=apply old (apply old plusFn (local old acc)) (gen old intTy (IntValue 1))
          body=gen old intTy (If (invoke old b capsB [laneVar]) inc (local old acc))
          params=[acc,lane]
          code=CodeFunction label ClosureCode capsB params body
          stage (i,(value,scheme))=case exprNode (unNote value) of
            Var (Local uid)->(uid,[])
            _->let j=count+2+i
                   binding=Binder (BinderId ns j) (spelling j) scheme (linShapeT linears (exprType value))
               in (binderId binding,[(binding,value)])
          staged=map stage (zip [0..] bc)
          closureTy=foldr (TFn . binderType) intTy params
          closure=gen old closureTy (ClosureValue label (map fst staged))
          zero=gen old intTy (IntValue 0)
          args=[closure,zero,innerSrc]
          headTy=foldr (TFn . exprType) intTy args
          foldSc=M.findWithDefault (Forall [] [] headTy) foldName (catalogSchemas snapshot)
          head'=gen old headTy (Var (Global foldName foldSc))
          result=foldl (apply old) head' args
          renamed=[(binder {binderName=spelling (2*count+2+i)},rhs) | (i,(binder,rhs))<-zip [0..] prefixes]
      modify (\(Build n cs notes v _)->Build n (M.insert label code cs) notes v True)
      pure (foldr (bind old) result (renamed++concatMap snd staged))
    composite _ old consumerHead seed innerSrc
      a@(Callback _ _ ac _ _) b@(Callback _ _ bc _ _) composition prefixes=do
        let values=ac++bc
            count=length values
        (label,ns)<-fresh (2*count+length prefixes+2)
        let spelling i=targetName (CodeTarget label)++".$"++show i
            capture i (_,scheme)=Binder (BinderId ns i) (spelling i) scheme
              (linShapeT linears (case scheme of Forall _ _ ty->ty))
            caps=zipWith capture [0..] values
            capsA=take (length ac) caps
            capsB=drop (length ac) caps
            elementTy=case exprType innerSrc of
              TAp (TC "List") element->element
              _->error "list fusion: source lost its checked List type"
            lane=Binder (BinderId ns count) (spelling count) (Forall [] [] elementTy) (linShapeT linears elementTy)
            laneVar=local old lane
            accTy=case seed of Just z->exprType z;Nothing->error "list fusion: fold composition without a seed"
            acc=Binder (BinderId ns (count+1)) (spelling (count+1)) (Forall [] [] accTy) (linShapeT linears accTy)
            (params,body)=case composition of
              MapMap->([lane],invoke old a capsA [invoke old b capsB [laneVar]])
              FilterFilter->([lane],gen old (TC "Bool")
                (If (invoke old b capsB [laneVar]) (invoke old a capsA [laneVar]) (gen old (TC "Bool") (BoolValue False))))
              FoldMap->([acc,lane],invoke old a capsA [local old acc,invoke old b capsB [laneVar]])
              FoldFilter->([acc,lane],gen old (exprType old)
                (If (invoke old b capsB [laneVar]) (invoke old a capsA [local old acc,laneVar]) (local old acc)))
              _->error "list fusion: unexpected composite rule"
            code=CodeFunction label ClosureCode caps params body
            stage (i,(value,scheme))=case exprNode (unNote value) of
              Var (Local uid)->(uid,[])
              _->let j=count+2+i
                     binding=Binder (BinderId ns j) (spelling j) scheme (linShapeT linears (exprType value))
                 in (binderId binding,[(binding,value)])
            staged=map stage (zip [0..] values)
            closureTy=foldr (TFn . binderType) (exprType body) params
            closure=gen old closureTy (ClosureValue label (map fst staged))
            args=closure:maybe [] (:[]) seed++[innerSrc]
            headTy=foldr (TFn . exprType) (exprType old) args
            head'=gen consumerHead headTy (exprNode consumerHead)
            result=foldl (apply old) head' args
            renamed=[(binder {binderName=spelling (2*count+2+i)},rhs) | (i,(binder,rhs))<-zip [0..] prefixes]
        modify (\(Build n cs notes v _)->Build n (M.insert label code cs) notes v True)
        pure (foldr (bind old) result (renamed++concatMap snd staged))
    invoke old (Callback key head' original capCount leading) captures args=case key of
      CodeTarget label->gen old result (CodeCall label (map binderId (take capCount captures))
        (zipWith (\b x->ref old b (exprType x)) (drop capCount captures) leading++args))
      RootTarget _->foldl (apply old) head'
        (zipWith (\b (x,_)->ref old b (exprType x)) captures original++args)
      where result=foldl (\ty _->case ty of TFn _ r->r;_->ty) (exprType head') (leading++args)
    fresh count=do
      Build serial codes notes v changed<-get
      let choose n=
            let base="$typed.listfusion."++show n++"."++show (length owner)++"."++owner
                ns=Namespace (namespace++"/listfusion/"++owner++"/"++show n)
            in if ns `S.member` catalogNamespaces snapshot || any (`S.member` catalogNames snapshot) (base:[base++".$"++show i | i<-[0..count]])
               then choose (n+1) else (CodeId base,ns,n+1)
          (label,ns,next)=choose serial
      put (Build next codes notes v changed)
      pure (label,ns)
    -- Shape verification: a same-named user combinator must not fuse. The
    -- wrapper bodies and their workers are matched structurally against
    -- std/list's definitions; the result is cached per global name.
    verified name kind=do
      Build _ _ _ cache _<-get
      case M.lookup name cache of
        Just ok->pure ok
        Nothing->do
          source<-template (RootTarget name)
          let ok=maybe False (checkShape kind) source
          modify (\(Build n cs ns v changed)->Build n cs ns (M.insert name ok v) changed)
          pure ok
    checkShape kind (Template [] params body _ EntryCode)=case functionClause params body of
      Just (ps,body')->case kind of
        KFold->case ps of
          [f,z,xs]->case spine (strip body') [] of
            (h,[vf,vz,vxs])|isLocalOf f vf,isLocalOf z vz,isLocalOf xs vxs->
              workerShape (globalName h) "foldGo" foldWorker
            _->False
          _->False
        KMap->wrapperNil ps body' "mapGo" mapWorker
        KFilter->wrapperNil ps body' "filterGo" filterWorker
        KMapFilter->wrapperNil2 ps body' "mapFilterGo" mapFilterWorker
        KFilterMapped->wrapperNil2 ps body' "filterMappedGo" filterMappedWorker
        KMapRange->case ps of
          [f,a,b]->case spine (strip body') [] of
            (h,[vf,va,vb,vnil])|isLocalOf f vf,isLocalOf a va,isLocalOf b vb,isNil vnil->
              workerShape (globalName h) "mapRangeGo" mapRangeWorker
            _->False
          _->False
        KLengthRange->case ps of
          [a,b]->case spine (strip body') [] of
            (h,[va,vb,vzero])|isLocalOf a va,isLocalOf b vb,isIntLiteral vzero->
              workerShape (globalName h) "lengthRangeGo" lengthRangeWorker
            _->False
          _->False
        KRange->case ps of
          [a,b]->case spine (strip body') [] of
            (h,[va,vb,vnil])|isLocalOf a va,isLocalOf b vb,isNil vnil->
              workerShape (globalName h) "rangeGo" rangeWorker
            _->False
          _->False
        KLength->case ps of
          [xs]->case spine (strip body') [] of
            (h,[vxs,vzero])|isLocalOf xs vxs,isIntLiteral vzero->
              workerShape (globalName h) "lengthGo" lengthWorker
            _->False
          _->False
        KSum->sumProduct ps body'
        KProduct->sumProduct ps body'
      Nothing->False
    checkShape _ _=False
    -- A checked function retains its FunctionMatch clause. Validate that it
    -- only rebinds the entry parameters, then match the body against those
    -- bound identities rather than the outer entry binders.
    functionClause params body=case exprNode (strip body) of
      MatchTail (FunctionMatch _) scruts [Alternative pats [] rhs] _->clause scruts pats rhs
      Match (FunctionMatch _) scruts [Alternative pats [] rhs]->clause scruts pats rhs
      _->Nothing
      where
        clause scruts pats rhs
          | length params==length scruts,length params==length pats,
            and (zipWith isLocalOf params scruts)=do
              bs<-mapM bindPattern pats
              pure (bs,unNote rhs)
          | otherwise=Nothing
        bindPattern p=case patNode p of Bind b->Just b;_->Nothing
    -- map f xs = mapGo f xs Nil (filter likewise); the worker carries the
    -- semantic evidence, so the wrapper only has to forward its parameters.
    wrapperNil [f,xs] body worker check=case spine (strip body) [] of
      (h,[vf,vxs,vnil])|isLocalOf f vf,isLocalOf xs vxs,isNil vnil->
        workerShape (globalName h) worker check
      _->False
    wrapperNil _ _ _ _=False
    wrapperNil2 [f,g,xs] body worker check=case spine (strip body) [] of
      (h,[vf,vg,vxs,vnil])|isLocalOf f vf,isLocalOf g vg,isLocalOf xs vxs,isNil vnil->
        workerShape (globalName h) worker check
      _->False
    wrapperNil2 _ _ _ _=False
    sumProduct [xs] body=case spine (strip body) [] of
      (h,[_,z,v])|kindOf (globalName h)==Just KFold,isLocalOf xs v,isIntLiteral z->True
      _->False
    sumProduct _ _=False
    isNil e=case exprNode (unNote e) of
      Var (Global "Nil" _)->True
      AtomValue "Nil"->True
      Construct "Nil" []->True
      _->False
    isIntLiteral e=case exprNode (unNote e) of IntValue _->True;_->False
    workerShape name worker check=baseName name==worker&&case M.lookup (RootTarget name) (catalogTemplates snapshot) of
      Just (Template [] params body _ EntryCode)->maybe False (uncurry check) (functionClause params body)
      _->False
    -- foldGo f z xs = case xs of Nil -> z | x::r -> foldGo f (f z x) r
    foldWorker [f,z,xs] body=case listCase body of
      Just (scrut,nilExpr,x,r,consExpr)|isLocalOf xs scrut,isLocalOf z nilExpr->
        case spine (strip consExpr) [] of
          (_,[vf,update,vr])|isLocalOf f vf,isLocalOf r vr->
            case spine (strip update) [] of
              (fu,[uz,ux])|isLocalOf f fu,isLocalOf z uz,isLocalOf x ux->True
              _->False
          _->False
      _->False
    foldWorker _ _=False
    -- lengthGo xs n = case xs of Nil -> n | _::r -> lengthGo r (n + 1)
    lengthWorker [xs,n] body=case listTailCase body of
      Just (scrut,nilExpr,r,consExpr)|isLocalOf xs scrut,isLocalOf n nilExpr->
        case spine (strip consExpr) [] of
          (_,[vr,inc])|isLocalOf r vr->
            case spine (strip inc) [] of
              (add,[vn,one])|globalName add=="+",isLocalOf n vn,isIntLiteral one->True
              _->False
          _->False
      _->False
    lengthWorker _ _=False
    -- rangeGo a b acc = case b < a of True -> acc | False -> rangeGo a (b-1) (b::acc)
    rangeWorker [a,b,acc] body=case boolCase body of
      Just (test,thenExpr,elseExpr)|isLocalOf acc thenExpr->
        case spine (strip test) [] of
          (lt,[vb,va])|globalName lt=="<",isLocalOf b vb,isLocalOf a va->
            case spine (strip elseExpr) [] of
              (_,[va',dec,cons])|isLocalOf a va'->
                case spine (strip dec) [] of
                  (sub,[vb',one])|globalName sub=="-",isLocalOf b vb',isIntLiteral one->
                    case consArgs cons of
                      Just (hd,tl)->isLocalOf b hd&&isLocalOf acc tl
                      Nothing->False
                  _->False
              _->False
          _->False
      _->False
    rangeWorker _ _=False
    -- mapRangeGo f a b acc = case b < a of True -> acc | False -> mapRangeGo f a (b-1) (f b::acc)
    mapRangeWorker [f,a,b,acc] body=case boolCase body of
      Just (test,thenExpr,elseExpr)|isLocalOf acc thenExpr->
        case spine (strip test) [] of
          (lt,[vb,va])|globalName lt=="<",isLocalOf b vb,isLocalOf a va->
            case spine (strip elseExpr) [] of
              (_,[vf,va',dec,cons])|isLocalOf f vf,isLocalOf a va'->
                case spine (strip dec) [] of
                  (sub,[vb',one])|globalName sub=="-",isLocalOf b vb',isIntLiteral one->
                    case consArgs cons of
                      Just (hd,tl)->case spine (strip hd) [] of
                        (fu,[vb''])|isLocalOf f fu,isLocalOf b vb''->isLocalOf acc tl
                        _->False
                      Nothing->False
                  _->False
              _->False
          _->False
      _->False
    mapRangeWorker _ _=False
    -- lengthRangeGo a b n = case b < a of True -> n | False -> lengthRangeGo a (b-1) (n+1)
    lengthRangeWorker [a,b,n] body=case boolCase body of
      Just (test,thenExpr,elseExpr)|isLocalOf n thenExpr->
        case spine (strip test) [] of
          (lt,[vb,va])|globalName lt=="<",isLocalOf b vb,isLocalOf a va->
            case spine (strip elseExpr) [] of
              (_,[va',dec,inc])|isLocalOf a va'->
                case (spine (strip dec) [],spine (strip inc) []) of
                  ((sub,[vb',one]),(add,[vn,one']))
                    |globalName sub=="-",isLocalOf b vb',isIntLiteral one,
                     globalName add=="+",isLocalOf n vn,isIntLiteral one'->True
                  _->False
              _->False
          _->False
      _->False
    lengthRangeWorker _ _=False
    -- mapGo f xs acc = case xs of Nil -> reverse acc | x::r -> mapGo f r (f x::acc)
    mapWorker [f,xs,acc] body=case listCase body of
      Just (scrut,nilExpr,x,r,consExpr)|isLocalOf xs scrut->
        case spine (strip nilExpr) [] of
          (rev,[va])|baseName (globalName rev)=="reverse",isLocalOf acc va->
            case spine (strip consExpr) [] of
              (_,[vf,vr,cons])|isLocalOf f vf,isLocalOf r vr->
                case consArgs cons of
                  Just (hd,tl)->case spine (strip hd) [] of
                    (fu,[vx])|isLocalOf f fu,isLocalOf x vx->isLocalOf acc tl
                    _->False
                  Nothing->False
              _->False
          _->False
      _->False
    mapWorker _ _=False
    -- filterGo p xs acc = case xs of Nil -> reverse acc | x::r ->
    --   case p x of True -> filterGo p r (x::acc) | False -> filterGo p r acc
    filterWorker [p,xs,acc] body=case listCase body of
      Just (scrut,nilExpr,x,r,consExpr)|isLocalOf xs scrut->
        case spine (strip nilExpr) [] of
          (rev,[va])|baseName (globalName rev)=="reverse",isLocalOf acc va->
            case boolCase consExpr of
              Just (test,thenExpr,elseExpr)->
                case spine (strip test) [] of
                  (pu,[vx])|isLocalOf p pu,isLocalOf x vx->
                    filterBranch p r x acc thenExpr True&&filterBranch p r x acc elseExpr False
                  _->False
              Nothing->False
          _->False
      _->False
    filterWorker _ _=False
    filterBranch p r x acc e keep=case spine (strip e) [] of
      (_,[vp,vr,tail'])|isLocalOf p vp,isLocalOf r vr->
        if keep then case consArgs tail' of
          Just (hd,tl)->isLocalOf x hd&&isLocalOf acc tl
          Nothing->False
        else isLocalOf acc tail'
      _->False
    -- mapFilterGo f p xs acc = case xs of Nil -> reverse acc | x::r ->
    --   case p x of True -> mapFilterGo f p r (f x::acc) | False -> mapFilterGo f p r acc
    mapFilterWorker [f,p,xs,acc] body=case listCase body of
      Just (scrut,nilExpr,x,r,consExpr)|isLocalOf xs scrut->
        case spine (strip nilExpr) [] of
          (rev,[va])|baseName (globalName rev)=="reverse",isLocalOf acc va->
            case boolCase consExpr of
              Just (test,thenExpr,elseExpr)->
                case spine (strip test) [] of
                  (pu,[vx])|isLocalOf p pu,isLocalOf x vx->
                    mapFilterBranch f p r x acc thenExpr True&&mapFilterBranch f p r x acc elseExpr False
                  _->False
              Nothing->False
          _->False
      _->False
    mapFilterWorker _ _=False
    mapFilterBranch f p r x acc e keep=case spine (strip e) [] of
      (_,[vf,vp,vr,tail'])|isLocalOf f vf,isLocalOf p vp,isLocalOf r vr->
        if keep then case consArgs tail' of
          Just (hd,tl)->case spine (strip hd) [] of
            (fu,[vx])|isLocalOf f fu,isLocalOf x vx->isLocalOf acc tl
            _->False
          Nothing->False
        else isLocalOf acc tail'
      _->False
    -- filterMappedGo p f xs acc = case xs of Nil -> reverse acc | x::r ->
    --   y = f x; case p y of True -> filterMappedGo p f r (y::acc) | False -> filterMappedGo p f r acc
    filterMappedWorker [p,f,xs,acc] body=case listCase body of
      Just (scrut,nilExpr,x,r,consExpr)|isLocalOf xs scrut->
        case spine (strip nilExpr) [] of
          (rev,[va])|baseName (globalName rev)=="reverse",isLocalOf acc va->
            case exprNode (strip consExpr) of
              Let y rhs rest->
                case spine (strip rhs) [] of
                  (fu,[vx])|isLocalOf f fu,isLocalOf x vx->
                    case boolCase rest of
                      Just (test,thenExpr,elseExpr)->
                        case spine (strip test) [] of
                          (pu,[vy])|isLocalOf p pu,isLocalOf y vy->
                            filterMappedBranch p f r y acc thenExpr True&&filterMappedBranch p f r y acc elseExpr False
                          _->False
                      Nothing->False
                  _->False
              _->False
          _->False
      _->False
    filterMappedWorker _ _=False
    filterMappedBranch p f r y acc e keep=case spine (strip e) [] of
      (_,[vp,vf,vr,tail'])|isLocalOf p vp,isLocalOf f vf,isLocalOf r vr->
        if keep then case consArgs tail' of
          Just (hd,tl)->isLocalOf y hd&&isLocalOf acc tl
          Nothing->False
        else isLocalOf acc tail'
      _->False
    consArgs e=case spine (strip e) [] of
      (h,[hd,tl])|globalName h=="Cons"->Just (hd,tl)
      _->case exprNode (unNote e) of
        Construct "Cons" [hd,tl]->Just (hd,tl)
        _->Nothing
    -- A two-alternative list case: Nil, then Cons x r. Closure conversion
    -- introduces a temporary for every case scrutinee; resolve only that
    -- alias and let the worker's identity check validate its source.
    listCase e=case exprNode (unNote e) of
      Let b rhs rest->
        case listCase rest of
          Just (scrut,nilExpr,x,r,consExpr)|isLocalOf b scrut->Just (rhs,nilExpr,x,r,consExpr)
          _->Nothing
      _->case exprNode (strip e) of
        Match _ [scrut] alts->listAlts scrut alts
        MatchTail _ [scrut] alts _->listAlts scrut alts
        _->Nothing
    listAlts scrut [Alternative [np] [] nilExpr,Alternative [cp] [] consExpr]=case (patNode np,patNode cp) of
      (ConstructorPattern "Nil" [],ConstructorPattern "Cons" [px,pr])->
        case (patNode px,patNode pr) of
          (Bind x,Bind r)->Just (scrut,unNote nilExpr,x,r,unNote consExpr)
          _->Nothing
      _->Nothing
    listAlts _ _=Nothing
    listTailCase e=case exprNode (unNote e) of
      Let b rhs rest->
        case listTailCase rest of
          Just (scrut,nilExpr,r,consExpr)|isLocalOf b scrut->Just (rhs,nilExpr,r,consExpr)
          _->Nothing
      _->case exprNode (strip e) of
        Match _ [scrut] alts->listTailAlts scrut alts
        MatchTail _ [scrut] alts _->listTailAlts scrut alts
        _->Nothing
    listTailAlts scrut [Alternative [np] [] nilExpr,Alternative [cp] [] consExpr]=case (patNode np,patNode cp) of
      (ConstructorPattern "Nil" [],ConstructorPattern "Cons" [px,pr])->
        case (patNode px,patNode pr) of
          (Wildcard,Bind r)->Just (scrut,unNote nilExpr,r,unNote consExpr)
          (Bind _,Bind r)->Just (scrut,unNote nilExpr,r,unNote consExpr)
          _->Nothing
      _->Nothing
    listTailAlts _ _=Nothing
    boolCase e=case exprNode (unNote e) of
      Let b rhs rest->
        case boolCase rest of
          Just (scrut,t,f)|isLocalOf b scrut->Just (rhs,t,f)
          _->Nothing
      _->case exprNode (strip e) of
        If test thenExpr elseExpr->Just (strip test,strip thenExpr,strip elseExpr)
        Match _ [scrut] [Alternative [tp] [] t,Alternative [fp] [] f]->boolAlts scrut tp fp t f
        MatchTail _ [scrut] [Alternative [tp] [] t,Alternative [fp] [] f] _->boolAlts scrut tp fp t f
        _->Nothing
    boolAlts scrut tp fp t f=case (patNode tp,patNode fp) of
      (ConstructorPattern "True" [],ConstructorPattern "False" [])->Just (scrut,strip t,strip f)
      _->Nothing
