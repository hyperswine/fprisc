{-# LANGUAGE FlexibleContexts #-}
-- TRMC runs on final checked bodies, after the passes that clone/in-line
-- callbacks. Mutation is confined to TrmcProof's fresh-cell worker protocol.
module Core.Typed.Trmc (TrmcPlan,planTrmc,trmcClosed) where
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Callback.Catalog
import Core.Typed.Callback.Model (Target(..),Template(..),spine,unNote)
import Core.Typed.Walk
import Core.Typed.Verify (sameType)
import Core.Identity
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import Control.Monad (foldM)
import Control.Monad.State.Strict
import Data.Functor.Const (Const(..))
import Data.Functor.Identity (runIdentity)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

children e=getConst (mapChildrenM (Const . (:[])) e)
size e=1+sum (map size (children e))
uses b e=binderId b `elem` localUses e
local b e=case exprNode (unNote e) of Var (Local u)->u==binderId b;_->False
isNil e=case exprNode (strip e) of
  Construct "Nil" []->True
  Var (Global "Nil" _)->True
  ListValue []->True
  _->False
strip e=case exprNode e of
  Note x->strip x
  Sequence a b | EntryTick<-exprNode a->strip b
  Let _ rhs b | EntryTick<-exprNode rhs->strip b
  _->e
cons e=case exprNode (unNote e) of
  Construct "Cons" [h,t]->Just (h,t)
  _->case spine e [] of
    (f,[h,t]) | Var (Global "Cons" _)<-exprNode f->Just (h,t)
    _->Nothing
-- Only identity aliases and an irrefutable parameter rebinding disappear.
-- Effects, entry ticks, refutable matches and guards retain their positions.
canonical e=step (runIdentity (mapChildrenM (pure . canonical) e))
  where
    step x=case exprNode x of
      Note b->b
      Let b rhs body | Var (Local uid)<-exprNode rhs->canonical (renameUses (M.singleton (binderId b) uid) body)
      Let b rhs body | local b body->rhs
      -- Specialization stages the new accumulator before its self call.
      -- Sink only into that single argument, across evaluated locals. Never
      -- float callback work across an effect, trap, capture, or another use.
      Let b rhs body | CodeCall k caps args<-exprNode body,
        binderId b `notElem` caps,
        (before,arg:after)<-break (local b) args,
        all evaluatedLocal before,all (not . uses b) (before++after),local b arg->
          body {exprNode=CodeCall k caps (before++[rhs]++after)}
      MatchTail (FunctionMatch _) args [Alternative pats [] body] _
        | length args==length pats,Just pairs<-traverse pair (zip pats args)->canonical (renameUses (M.fromList pairs) body)
      _->x
    evaluatedLocal a=case exprNode a of Var (Local _)->True;IntValue _->True;BoolValue _->True;_->False
    pair (p,a)=case (patNode p,exprNode a) of (Bind b,Var (Local uid))->Just (binderId b,uid);_->Nothing

-- Calls use identities, and reverse helpers are proved from checked bodies.
call scope e=case exprNode (unNote e) of
  CodeCall k caps args->do
    bs<-traverse (`M.lookup` scope) caps
    pure (CodeTarget k,map ref bs++args)
  _->case spine e [] of
    (f,args)|Var (Global n _)<-exprNode f->Just (RootTarget n,args)
    _->Nothing
  where ref b=Expr (binderType b) (binderShape b) Generated Nothing (Var (Local (binderId b)))

listCase e=case exprNode (strip e) of
  MatchTail CaseMatch [xs] [Alternative [pn] [] no,Alternative [pc] [] yes] fallback
    | ConstructorPattern "Nil" []<-patNode pn,
      ConstructorPattern "Cons" [ph,pt]<-patNode pc,
      Bind h<-patNode ph,Bind t<-patNode pt,Fail _<-exprNode fallback->Just (xs,no,h,t,yes)
  _->Nothing

reverseHelpers snapshot=(revOntos,reverses)
  where
    templates=catalogTemplates snapshot
    revOntos=M.keysSet (M.filterWithKey rev templates)
    reverses=M.keysSet (M.filter reverse' templates)
    rev key (Template [] [xs,acc] raw _ _)=case listCase (canonical raw) of
      Just (scrut,no,h,t,yes)|local xs scrut,local acc (strip no),
        Just (self,[tl,cell])<-call M.empty (strip yes),self==key,
        local t tl,Just (hd,tail')<-cons (strip cell)->local h hd && local acc tail'
      _->False
    rev _ _=False
    reverse' (Template [] [xs] raw _ _)=case call M.empty (strip (canonical raw)) of
      Just (k,[arg,n]) -> S.member k revOntos && local xs arg && isNil n
      _->False
    reverse' _=False

data TrmcPlan=TrmcPlan (S.Set Target,S.Set Target) (S.Set Target)
planTrmc :: Catalog -> TrmcPlan
planTrmc snapshot=TrmcPlan (reverseHelpers snapshot) (close sensitive)
  where
    -- A builder cannot be copied as independent root/cursor region state.
    -- Do not take an existing receive/managed loop away from its region
    -- planner. Match the planner's known effects, including indirect calls
    -- and referenced callback bodies; opaque callbacks remain opaque to both.
    sensitive=S.fromList (map RootTarget
      ["receive","receiveFrom","receiveRes","receiveNow","receiveFromRes","receiveFromNow",
       "Sys.poolReset","Sys.arena","Sys.loop","Sys.loopWith","$receiveLoop","$loopLeave"])
    graph=M.map (\(Template _ _ body _ _)->refs body) (catalogTemplates snapshot)
    refs e=(case exprNode e of
      Var (Global n _)->S.singleton (RootTarget n)
      CodeCall k _ _->S.singleton (CodeTarget k)
      JoinCall k _ _->S.singleton (CodeTarget k)
      ClosureValue k _->S.singleton (CodeTarget k)
      _->S.empty) `S.union` S.unions (map refs (children e))
    close known=let next=known `S.union` M.keysSet (M.filter (not . S.null . S.intersection known) graph)
                in if next==known then known else close next

data Build=Build Int (M.Map CodeId CodeFunction) Int Int

trmcClosed :: Namespace -> TypeContext -> TrmcPlan -> ClosedFunction -> Either String (ClosedFunction,Int,Int,Bool)
trmcClosed (Namespace ns) types@(TypeContext linears _) (TrmcPlan (revOntos,reverses) regionSensitive) input=do
  ((root,codes),Build _ added loops appends)<-runStateT run (Build 0 M.empty 0 0)
  if loops+appends==0 then pure (input,0,0,False) else do
    output<-rewriteClosed types (\_ _->Right (root,codes `M.union` added)) input
    pure (output,loops,appends,True)
  where
    owner=functionName (closedRoot input)
    gen ty node=Expr ty (linShapeT linears ty) Generated Nothing node
    ref b=gen (binderType b) (Var (Local (binderId b)))
    nil ty=gen ty (Construct "Nil" [])
    cell hd tail'=gen (exprType tail') (Construct "Cons" [hd,tail'])
    bind b rhs body=gen (exprType body) (Let b rhs body)
    store base value=gen (TC "Unit") (SetField base 1 value)
    codeCall label args result=gen result (CodeCall label [] args)
    fresh ty=do
      Build n cs l a<-get
      put (Build (n+1) cs l a)
      let label="$trmc."++show (length owner)++"."++owner++"."++show n
      pure (Binder (BinderId (Namespace (ns++"/trmc/"++owner)) n) label (Forall [] [] ty) (linShapeT linears ty))
    label=do b<-fresh (TC "Unit");pure (CodeId ("$worker.trmc."++binderName b))
    install code=modify (\(Build n cs l a)->Build n (M.insert (codeId code) code cs) l a)
    run=do
      root<-function (RootTarget owner) (closedRoot input)
      codes<-M.traverseWithKey (\key c->do
        f<-function (CodeTarget key) (codeAsFunction c)
        pure c {codeBody=functionBody f}) (closedCode input)
      pure (root,codes)
    scope fn=M.fromList [(binderId b,b) | b<-functionParameters fn++allBinders (functionBody fn)]
    function key original=do
      let fn=original {functionBody=canonical (functionBody original)}
          ps=functionParameters fn
          env=scope fn
          body=functionBody fn
          candidates=[i | (i,acc)<-zip [0..] ps,listType (binderType acc),sameType (binderType acc) (exprType body),
            Just (ex,step)<-[check env key ps acc i body],ex && step]
      looped<-if size body>1024 || length ps>62 || any poly ps || key `S.member` revOntos || key `S.member` reverses || key `S.member` regionSensitive
        then pure original else case candidates of
          i:_->transform key fn i
          []->pure original
      Build _ _ _ beforeAppend<-get
      appended<-appendSites (canonical (functionBody looped))
      Build _ _ _ afterAppend<-get
      pure (if beforeAppend==afterAppend then looped else looped {functionBody=appended})
    poly b=case binderScheme b of Forall [] [] _->False;_->True
    listType (TAp (TC "List") _)=True
    listType _=False
    noAcc acc=not . uses acc
    -- Prefixes inside Cons preserve evaluation order, but never mention acc.
    peel acc e=case exprNode (unNote e) of
      Let b rhs rest | noAcc acc rhs->let (bs,leaf)=peel acc rest in ((Just b,rhs):bs,leaf)
      Sequence rhs rest | noAcc acc rhs->let (bs,leaf)=peel acc rest in ((Nothing,rhs):bs,leaf)
      _->([],unNote e)
    wrap prefix body=foldr (\(b,rhs) rest->case b of
      Just binder->bind binder rhs rest
      Nothing->gen (exprType rest) (Sequence rhs rest)) body prefix
    consArg acc e=let (bs,leaf)=peel acc e in case cons leaf of
      Just (hd,tl)|local acc tl,noAcc acc hd->Just (bs,hd)
      _->Nothing
    exit env acc e=case call env e of
      Just (k,[arg])|S.member k reverses->fromArg arg (nil (binderType acc))
      Just (k,[arg,tail'])|S.member k revOntos,noAcc acc tail'->fromArg arg tail'
      _->Nothing
      where
        fromArg arg tail' | local acc arg=Just ([],tail')
        fromArg arg tail'=do (bs,hd)<-consArg acc arg;pure (bs,cell hd tail')
    check env key ps acc i e=case exprNode e of
      Note x->check env key ps acc i x
      Let _ rhs rest | noAcc acc rhs->check env key ps acc i rest
      Sequence rhs rest | noAcc acc rhs->check env key ps acc i rest
      If cond yes no | noAcc acc cond->combine <$> check env key ps acc i yes <*> check env key ps acc i no
      MatchTail _ args alts fallback | all (noAcc acc) args,all (all (noAcc acc) . guards) alts->
        foldM (\s b->combine s <$> check env key ps acc i b) (False,False) (fallback:[b | Alternative _ _ b<-alts])
      Fail _->Just (False,False)
      _ | Just _<-exit env acc e->Just (True,False)
        | Just (k,args)<-call env e,k==key,length args==length ps,
          and [noAcc acc a | (j,a)<-zip [0..] args,j/=i]->
            if local acc (args!!i) then Just (False,False)
            else case consArg acc (args!!i) of Just _->Just (False,True);_->Nothing
      _->Nothing
    combine (a,b) (c,d)=(a||c,b||d)
    guards (Alternative _ gs _)=[e | g<-gs,e<-case g of BoolGuard x->[x];PatternGuard _ x->[x]]
    -- Every moved operand is staged once in original argument order. Only
    -- allocation of the fresh output cell is delayed until the staged call.
    stage xs=do
      bs<-mapM (fresh . exprType) xs
      pure (zip bs xs,map ref bs)
    finish root cursor tail'=if isNil tail' then pure (ref root) else do
      t<-fresh (exprType tail');u<-fresh (TC "Unit")
      pure (bind t tail' (bind u (store (ref cursor) (ref t)) (ref root)))
    start worker before hd after ty=do
      (bb,bv)<-stage before
      h<-fresh (exprType hd)
      (ab,av)<-stage after
      c<-fresh ty
      pure (foldr (uncurry bind) (bind c (cell (ref h) (nil ty))
        (codeCall worker (bv++[ref c,ref c]++av) ty)) (bb++[(h,hd)]++ab))
    push worker root cursor before hd after ty=do
      (bb,bv)<-stage before;h<-fresh (exprType hd);(ab,av)<-stage after
      c<-fresh ty;u<-fresh (TC "Unit")
      pure (foldr (uncurry bind) (bind c (cell (ref h) (nil ty))
        (bind u (store (ref cursor) (ref c)) (codeCall worker (bv++[ref root,ref c]++av) ty)))
        (bb++[(h,hd)]++ab))
    transform key fn i=do
      worker<-label
      let ps=functionParameters fn;acc=ps!!i;ty=binderType acc;body=functionBody fn;env=scope fn
      root<-fresh ty;cursor<-fresh ty
      workerBody<-rewrite env key ps acc i worker (Just (root,cursor)) body
      let workerPs=take i ps++[root,cursor]++drop (i+1) ps
      -- Entry and worker must not share any binder identity or spelling.
      let bs=workerPs++allBinders workerBody
      new<-mapM (fresh . binderType) bs
      let ids=M.fromList (zip (map binderId bs) (map binderId new))
          names=M.fromList (zip (map binderId new) (map binderName new))
          rename=renameBinderNames names . renameBinders ids
          wbody=rename (gen ty (ListBuilder (binderId root) (binderId cursor) workerBody))
          wps=take (length workerPs) new
      install (CodeFunction worker EntryCode [] wps wbody)
      entry<-rewrite env key ps acc i worker Nothing body
      modify (\(Build n cs l a)->Build n cs (l+1) a)
      pure fn {functionBody=entry}
    rewrite env key ps acc i worker mode e=case exprNode e of
      Note x->rewrite env key ps acc i worker mode x
      Let b rhs rest->bind b rhs <$> recurse rest
      Sequence rhs rest->gen (exprType e) . Sequence rhs <$> recurse rest
      If cond yes no->gen (exprType e) <$> (If cond <$> recurse yes <*> recurse no)
      MatchTail style args alts fallback->do
        as<-mapM (\(Alternative pats gs body)->Alternative pats gs <$> recurse body) alts
        k<-recurse fallback
        pure (e {exprNode=MatchTail style args as k})
      Fail _->pure e
      _ | Just (prefix,tail')<-exit env acc e->case mode of
            Just (root,cursor)->wrap prefix <$> finish root cursor tail'
            Nothing->do
              -- Keep the original nonempty-accumulator path, without copying
              -- any binders from the optimized branch into it.
              yes<-cloneExpr (wrap prefix tail')
              pure (emptyCase acc yes e)
        | Just (k,args)<-call env e,k==key,length args==length ps->
            let before=take i args;after=drop (i+1) args in
            if local acc (args!!i) then case mode of
              Nothing->pure e
              Just (root,cursor)->pure (codeCall worker (before++[ref root,ref cursor]++after) (exprType e))
            else case consArg acc (args!!i) of
              Just (prefix,hd)->case mode of
                Nothing->do
                  yes<-start worker before (wrap prefix hd) after (exprType e) >>= cloneExpr
                  pure (emptyCase acc yes e)
                Just (root,cursor)->push worker root cursor before (wrap prefix hd) after (exprType e)
              _->lift (Left "typed TRMC: lost cons plan")
      _->lift (Left "typed TRMC: lost tail plan")
      where recurse=rewrite env key ps acc i worker mode
    cloneExpr e=do
      let bs=allBinders e
      new<-mapM (fresh . binderType) bs
      let ids=M.fromList (zip (map binderId bs) (map binderId new))
          names=M.fromList (zip (map binderId new) (map binderName new))
      pure (renameBinderNames names (renameBinders ids e))
    emptyCase acc yes no=gen (exprType yes) (MatchTail CaseMatch [ref acc]
      [Alternative [Pattern (binderType acc) "Nil" (ConstructorPattern "Nil" [])] [] yes] no)
    -- Append is recognized by the same proved reverse helpers, never by name.
    -- Inlining leaves entry ticks around reverse; specialization may bind
    -- its result. Retain those ticks and the xs-before-ys evaluation order.
    ticks old result=case exprNode old of
      Note b->ticks b result
      Sequence a b | EntryTick<-exprNode a->gen (exprType result) (Sequence a (ticks b result))
      Let p a b | EntryTick<-exprNode a->bind p a (ticks b result)
      _->result
    reverseInput inner=case call M.empty (strip inner) of
      Just (r,[xs]) | S.member r reverses->Just xs
      Just (r,[xs,n]) | S.member r revOntos,isNil n->Just xs
      _->Nothing
    appendSites e=do
      child<-mapChildrenM appendSites e
      case exprNode child of
        Let b inner rest | Just xs<-reverseInput inner,
          Just (k,[arg,ys])<-call M.empty (strip rest),S.member k revOntos,
          local b arg,not (uses b ys)->ticks inner <$> appendBuild xs (ticks rest ys)
        _->case call M.empty child of
          Just (k,[inner,ys]) | S.member k revOntos,Just xs<-reverseInput inner->
            ticks inner <$> appendBuild xs ys
          _->pure child
    appendBuild xs ys=do
      worker<-label
      x<-fresh (exprType xs);y<-fresh (exprType ys);r<-fresh (exprType xs);c<-fresh (exprType xs)
      let ty=exprType xs;TAp _ element=ty
      h<-fresh element;t<-fresh ty
      done<-finish r c (ref y)
      more<-push worker r c [ref t,ref y] (ref h) [] ty
      let match source no yes=gen ty (MatchTail CaseMatch [source]
            [Alternative [Pattern ty "Nil" (ConstructorPattern "Nil" [])] [] no,
             Alternative [Pattern ty "Cons" (ConstructorPattern "Cons" [Pattern element "head" (Bind h),Pattern ty "tail" (Bind t)])] [] yes]
            (gen ty (Fail "TRMC: invalid list")))
          body=gen ty (ListBuilder (binderId r) (binderId c) (match (ref x) done more))
      install (CodeFunction worker EntryCode [] [x,y,r,c] body)
      entry<-start worker [ref t,ref y] (ref h) [] ty
      result<-cloneExpr (bind x xs (bind y ys (match (ref x) (ref y) entry)))
      modify (\(Build n cs l a)->Build n cs l (a+1))
      pure result
