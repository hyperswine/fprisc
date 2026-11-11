-- Bounded uniqueness proofs for fresh constructors and private consuming entries.
-- Public calls remain borrowing. Only a fresh, nonescaping root can transfer
-- ownership; last syntactic use of a borrowed value is never sufficient.
module Reuse (reuseFresh, reuseProgram, reuseProgramWithImports, spineBuilders, reuseView, poolResetters) where
import Control.Applicative ((<|>))
import Core.Opt.Normalize (normIn)
import Core.Syntax (Core(..), Prog, Name)
import Core.Primitives (primArities,entryTickName)
import Core.Region.Runtime (Hook(..),hookName)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isPrefixOf)
import Data.Maybe (mapMaybe, fromMaybe, listToMaybe)

type Shape = (Int,Int,Int)
type Plans = M.Map String (Int,Shape,Int,String)

reuseView :: Core -> Maybe (String,[Core])
reuseView (CApp (CApp (CVar "$reuse.fresh") (CVar x)) (CMk _ _ fs)) = Just (x,fs)
reuseView _ = Nothing

reuseFresh :: Core -> Core
reuseFresh body = rewrite (poolResetters (M.singleton "$reuse.entry" ([],body))) M.empty S.empty body

-- A pool reset frees every object allocated in the pool before it. A reused
-- constructor writes into the old object's memory, so no reuse may span an
-- expression that can reset the pool: Sys.poolReset itself, or a call to a
-- function that reaches one (A.tidy's `boundary`, once inlining brought the
-- match and the rebuilt tuple into one body). A resetting CAF is evaluated at
-- a bare reference, too. Unknown callbacks and opaque foreign entries are
-- barriers: the source may legitimately stop using an old allocation before
-- the callback, while reuse would introduce a new write to it afterwards.
-- See docs/2026-10-27-FOLLOWUPS.md for the conservative supported contract.
poolResetters :: Prog -> S.Set String
poolResetters prog = go initial
  where
    base=S.fromList ("Sys.poolReset":map hookName [CallLeave,LoopLeave,Cycle,ReceiveLoop])
    safe=S.fromList (entryTickName:map fst primArities++map hookName [CallPending,SequenceNumber,Open,PoolMark,HasRoom])
    facts=M.map (\(ps,b)->references (S.fromList ps) b) prog
    calls=M.map fst facts
    unknown=S.unions (M.elems calls) S.\\ (M.keysSet prog `S.union` safe)
    initial=base `S.union` unknown `S.union` M.keysSet (M.filter snd facts)
    go known = let next = known `S.union` M.keysSet (M.filter (not . S.null . S.intersection known) calls)
               in if next == known then known else go next
    references bound e=case e of
      CVar f | f `S.notMember` bound->(S.singleton f,False)
      CLet x rhs body->merge (references bound rhs) (references (S.insert x bound) body)
      CLam ps body->references (bound `S.union` S.fromList ps) body
      CApp {}->let (head',args)=spine e
                   dynamic=case head' of CVar f->f `S.member` bound;_->True
               in foldr merge (S.empty,dynamic) (map (references bound) (head':args))
      _->foldr merge (S.empty,False) (map (references bound) (children e))
    merge (a,x) (b,y)=(a `S.union` b,x || y)

-- Each clone consumes one parameter and returns that same allocation (or
-- fails). Other parameters remain borrowing. No wrapper, descriptor or exported
-- ABI is changed. Bodies and call sites are in the same compilation unit.
reuseProgram :: S.Set String -> S.Set String -> Prog -> (Prog,[String])
reuseProgram = reuseProgramWithImports M.empty M.empty

reuseProgramWithImports :: M.Map Name (Int,Int) -> Prog -> S.Set String -> S.Set String -> Prog -> (Prog,[String])
reuseProgramWithImports linked imports resetting excluded prog = (spineProgram `M.union` additions,
  ["# private consuming workers: "++show (M.size additions),
   "# private consuming list traversals: "++show (M.size spineProgram - M.size rewritten)])
  where
    spineProgram = consumeListSpines linked (prog `M.union` imports) resetting excluded rewritten
    choose (name,(ps,b))
      | "$worker." `isPrefixOf` name || S.member name excluded ||
        null ps || length ps>64 || not (bounded 256 b) = Nothing
      | otherwise = case mapMaybe (candidate name ps b) (zip [0..] ps) of
          p:_ -> Just (name,p)
          _ -> Nothing
    candidate name ps b (i,p) = do
      b' <- aliases p b
      shape <- resultShape b' <|> recursiveShape name i b'
      -- Do not assume calls, closures or other parameters are disjoint from
      -- a borrowed input. The caller establishes disjointness for the clone.
      let worker="$worker.consume."++show i++"."++name
      _ <- consumingBody name ps i shape worker b'
      pure (i,shape,length ps,worker)
    consumingBody name ps i shape worker = go
      where
        root=ps!!i
        scope=S.fromList ps
        safe a=readsOnly root (width shape) a && not (resets resetting scope a)
        go (CIf c yes no) | safe c = CIf c <$> go yes <*> go no
        go expr | (CVar f,args)<-spine expr, f==name, f `S.notMember` scope,
                  length args==length ps, all safe args,
                  all (not . mentions root) (drop (i+1) args),
                  CMk t v fields<-args!!i, (t,v,length fields)==shape =
          let updated=CApp (CApp (CVar "$reuse.fresh") (CVar root)) (args!!i)
          in Just (foldl CApp (CVar worker) (take i args++[updated]++drop (i+1) args))
        go expr=consume resetting M.empty scope root shape expr
    plans = M.fromList (take 128 (mapMaybe choose (M.toAscList prog)))
    rewritten = M.map (\(ps,b)->(ps,rewrite resetting plans (S.fromList ps) b)) prog
    used = S.fromList [f | (_,(_,b))<-M.toList rewritten, e<-nodes b,
                          (CVar f,_)<-[spine e], "$worker.consume." `isPrefixOf` f]
    additions = M.fromList [(worker,(ps,out)) |
      (name,(i,shape,_,worker))<-M.toList plans, S.member worker used,
      let (ps,b)=prog M.! name,
      Just b'<-[aliases (ps!!i) b],
      Just out<-[consumingBody name ps i shape worker b']]

-- A strict accumulator traversal has already evaluated the next tail
-- before constructing the next accumulator. Transfer that exact cons cell
-- only from a spine whose entire construction is private to this call.
consumeListSpines :: M.Map Name (Int,Int) -> Prog -> S.Set String -> S.Set String -> Prog -> Prog
consumeListSpines linked definitions resetting excluded program = rewritten `M.union` M.restrictKeys twins used
  where
    nil = CMk 2 0 []
    plan name (ps,CIf (CTagEq 2 tag (CVar xs)) a b) = do
      let (empty,step) = if tag==0 then (a,b) else (b,a)
          worker = "$worker.spine."++name
          -- Keep the strict field reads in their original order.
          projections = peelFields xs (S.fromList ps) M.empty step
      (wrap,fields,tailCall) <- projections
      let (callee,args) = spine tailCall
      if tag `notElem` [0,1] || name `S.member` excluded || name `elem` ps ||
         worker `M.member` definitions || worker `elem` ps || M.member worker fields ||
         M.member name fields || callee/=CVar name ||
         length args/=length ps || not (bounded 256 step) then Nothing else pure ()
      [(src,acc)] <- pure [(i,j) | (i,p)<-zip [0..] ps,p==xs,
                            (j,q)<-zip [0..] ps,i<j,empty==CVar q]
      let scope=S.fromList ps `S.union` M.keysSet fields
          resolve (CVar k)=M.findWithDefault (CVar k) k fields
          resolve x=x
          protect e | e==CVar xs || resolve e==CProj 1 (CVar xs) = False
                    | e==CProj 0 (CVar xs) = True
                    | otherwise=all protect (children e)
          store locals (CLet k rhs rest)
            | S.notMember k locals, k/=worker, k/=name, protect rhs,
              not (mentions (ps!!acc) rhs || resets resetting locals rhs) =
                CLet k rhs <$> store (S.insert k locals) rest
          store locals node@(CMk 2 1 [value,CVar old])
            | old==ps!!acc, protect value, not (mentions old value || resets resetting locals value) =
                Just (CApp (CApp (CVar "$reuse.fresh") (CVar xs)) node)
          store _ _=Nothing
      updated<-store scope (args!!acc)
      -- The head may be passed to a known non-resetting operation. Never
      -- hand it the tail or the whole cell. Other arguments are forwarded.
      if resolve (args!!src)/=CProj 1 (CVar xs) ||
         any (\(j,v)->j/=src && j/=acc && v/=CVar (ps!!j)) (zip [0..] args)
        then Nothing else pure ()
      let next=wrap (foldl CApp (CVar worker) (take acc args ++ [updated] ++ drop (acc+1) args))
      pure (src,worker,(ps,CIf (CTagEq 2 tag (CVar xs))
                    (if tag==0 then empty else next) (if tag==0 then next else empty)))
    plan _ _=Nothing
    peelFields xs scope fields (CLet k rhs@(CProj i (CVar p)) body)
      | p==xs, i==0 || i==1, S.notMember k scope = do
          (wrap,bindings,rest)<-peelFields xs (S.insert k scope) (M.insert k rhs fields) body
          pure (CLet k rhs . wrap,bindings,rest)
    peelFields _ _ fields expr=Just (id,fields,expr)
    -- The TRMC builder has already read the current input's tail before
    -- it allocates the output cell. Reuse that input, then perform the
    -- original cursor link and recur with the saved tail. Only this clone's
    -- initializer supplies the disjoint output prefix and unique remainder.
    cursorPlan name (ps@[xs,root,cursor],CIf (CTagEq 2 0 (CVar tested)) done step)
      | tested==xs, "$worker.trmc." `isPrefixOf` name, returns root done = do
          out<-cellStep ps xs step $ \scope tailRef cell rest ->case rest of
            CLet k (CApp (CApp (CVar "$trmc.setTail") (CVar dst)) (CVar src)) call
              | dst==cursor,src==cell,S.notMember k scope,
                spine call==(CVar name,[tailRef,CVar root,CVar cell]) ->
                Just (CLet k (CApp (CApp (CVar "$trmc.setTail") (CVar dst)) (CVar src))
                  (foldl CApp (CVar worker) [tailRef,CVar root,CVar cell]))
            _ -> Nothing
          if worker `M.member` definitions || rebinds worker step || worker `elem` ps then Nothing
            else Just (worker,(ps,CIf (CTagEq 2 0 (CVar xs)) done out))
      where worker="$worker.spine.cursor."++name
    cursorPlan _ _=Nothing
    returns root (CVar x)=x==root
    returns root (CLet k (CApp (CVar f) (CInt 0)) rest)=f==entryTickName && k/=root && returns root rest
    returns _ _=False
    cursors=M.mapMaybeWithKey cursorPlan program
    cellStep ps xs step finish=do
      (wrap,fields,body)<-peelFields xs (S.fromList ps) M.empty step
      [tailName]<-pure [k | (k,CProj 1 _)<-M.toList fields]
      let initial=S.fromList ps `S.union` M.keysSet fields
          -- An element computation may read the projected head, never the
          -- cursor, list or tail. Preserve every evaluation and fuel tick.
          allowed scope e=not (resets resetting scope e || any (\x->mentions x e) (tailName:ps))
          allocation scope (CLet k rhs rest) | k `S.notMember` scope,allowed scope rhs =
            CLet k rhs <$> allocation (S.insert k scope) rest
          allocation scope value@(CMk 2 1 [v,end]) | allowed scope v,isNil scope end =
            Just (CApp (CApp (CVar "$reuse.fresh") (CVar xs)) value)
          allocation _ _=Nothing
          go scope (CLet k value rest) | S.notMember k scope =
            case allocation scope value of
              Just reused -> CLet k reused <$> finish (S.insert k scope) (CVar tailName) k rest
              Nothing | allowed scope value -> CLet k value <$> go (S.insert k scope) rest
              _ -> Nothing
          go _ _=Nothing
      wrap <$> go initial body
    startPlan name (ps@[xs,seed],CIf (CTagEq 2 0 (CVar tested)) empty step)
      | xs==tested, worker `M.notMember` definitions, worker `notElem` ps = do
          let scope=S.fromList ps
              -- The private entry is selected only with an empty accumulator.
              pick (CIf (CTagEq 2 0 (CVar p)) yes _) | p==seed = pick yes
              pick (CLet k a b) | k/=seed=CLet k a (pick b)
              pick e=e
              emptyBranch=pick empty
              endsNil local (CLet k (CApp (CVar f) (CInt 0)) b)=f==entryTickName && S.notMember f local && k/=seed && endsNil (S.insert k local) b
              endsNil local e=isNil local e || e==CVar seed
          if not (endsNil scope emptyBranch) then Nothing else pure ()
          out<-cellStep ps xs (pick step) $ \locals tailRef cell rest ->case spine rest of
            (CVar f,args) | args==[tailRef,CVar cell,CVar cell], Just (w,_)<-M.lookup f cursors,
                            f `S.notMember` locals,w `S.notMember` locals ->
              Just (foldl CApp (CVar w) args)
            _ -> Nothing
          pure (0,worker,(ps,CIf (CTagEq 2 0 (CVar xs)) emptyBranch out))
      where worker="$worker.spine.map."++name
    startPlan _ _=Nothing
    starters=M.mapMaybeWithKey startPlan program
    traversals=M.mapMaybeWithKey plan program
    loops=M.mapMaybeWithKey loopPlan program
    plans=M.unions [traversals,loops,M.mapMaybeWithKey regionEntry program]
    -- The borrowing entry owns the region lifecycle. Its consuming twin
    -- enters the same scope and changes only the destination of the inner
    -- call. The cold edge in that inner loop calls the ordinary cycle.
    regionEntry name (ps,body)=do
      CLet seqId open (CLet markId mark (CApp (CApp (CVar leave) token) call))<-Just body
      let (callee,args)=spine call
          worker="$worker.spine.region."++name
      CVar inner<-Just callee
      (i,target,(params,_))<-M.lookup inner loops
      if open/=CApp (CVar (hookName SequenceNumber)) (CInt 0) ||
         mark/=CApp (CVar (hookName PoolMark)) (CInt 0) ||
         leave/=hookName LoopLeave || token/=CVar seqId ||
         args/=map CVar (ps++[markId,seqId]) || length params/=length args ||
         i>=length ps || seqId==markId || any (`elem` ps) [seqId,markId] ||
         any (`elem` (seqId:markId:ps)) [inner,target,leave,hookName SequenceNumber,hookName PoolMark] ||
         M.member worker definitions ||
         name `S.member` excluded then Nothing else
        Just (i,worker,(ps,CLet seqId open (CLet markId mark
          (CApp (CApp (CVar leave) token) (foldl CApp (CVar target) args)))))

    -- A traversal seeded with Nil returns precisely the consumed cells.
    -- Carry that fact through a self-tail call, keeping the public entry
    -- borrowing. A terminal arm can hand the list back to arbitrary code.
    loopPlan name (ps,body)
      | name `elem` ps || name `S.member` excluded || not (bounded 256 body) = Nothing
      | otherwise=listToMaybe [ (i,worker,(ps,out)) | (i,x)<-zip [0..] ps,
          worker `M.notMember` definitions, not (rebinds worker body), worker `notElem` ps,
          not (rebinds x body || rebinds name body),
          Just (True,out)<-[branch i x (S.fromList ps) body]]
      where
        worker="$worker.spine.loop."++name
        safe x scope e=not (mentions x e || resets resetting scope e)
        branch i x scope (CLet k rhs rest) | safe x scope rhs = do
          (changed,out)<-branch i x (S.insert k scope) rest
          pure (changed,CLet k rhs out)
        branch i x scope (CIf c a b) | safe x scope c = do
          (ca,a')<-branch i x scope a
          (cb,b')<-branch i x scope b
          pure (ca || cb,CIf c a' b')
        branch i x scope e
          | not (mentions name e)=Just (False,e)
          | (CVar f,args)<-spine e,f==name,length args==length ps,
            all (safe x scope) (take i args++drop (i+1) args) = do
              mapped<-transfer x scope S.empty (args!!i)
              pure (True,foldl CApp (CVar worker) (take i args++[mapped]++drop (i+1) args))
          | otherwise=Nothing
        transfer x scope nulls (CLet k rhs rest) | safe x scope rhs =
          let next=if isNil scope rhs then S.insert k nulls else S.delete k nulls
          in CLet k rhs <$> transfer x (S.insert k scope) next rest
        transfer x scope nulls e=case spine e of
          (CVar f,[token,result]) | f==hookName CallLeave, S.notMember f scope,
            M.notMember f definitions, safe x scope token ->
              CApp (CApp (CVar f) token) <$> transfer x scope nulls result
          (CVar f,[source,seed]) | source==CVar x, Just (0,w,([_,_],_))<-M.lookup f (M.union traversals starters),
            S.notMember f scope,S.notMember w scope,isNil scope seed || (case seed of CVar k->S.member k nulls;_->False) ->
              Just (CApp (CApp (CVar w) source) seed)
          _ -> Nothing
    isNil scope (CVar f)=S.notMember f scope && M.lookup f definitions==Just ([],nil)
    isNil _ e=e==nil
    twins=M.fromList ([(worker,body) | (_,worker,body)<-M.elems plans++M.elems starters] ++ M.elems cursors)
    builders=spineBuildersWith linked resetting definitions
    fresh _ e | e==nil=True
    fresh scope (CLet x _ rest)=fresh (S.insert x scope) rest
    fresh scope e | Just (_,rest)<-consFields definitions scope e=fresh scope rest
    fresh scope e=case spine e of
      (CVar f,[_,result]) | f==hookName CallLeave, S.notMember f scope,
                            M.notMember f definitions -> fresh scope result
      (CVar f,args) | S.notMember f scope, Just (ps,body)<-M.lookup f definitions,
                       length args==length ps -> case (ps,body,args) of
        ([],CMk 2 0 [],[]) -> True
        _ -> privateSeed scope args (M.lookup f builders)
      (CVar f,args) | S.notMember f scope -> privateSeed scope args (M.lookup f linked)
      _ -> False
    privateSeed _ args (Just (arity,i)) | i<0 = length args==arity
    privateSeed scope args (Just (arity,i)) = length args==arity && fresh scope (args!!i)
      && all (not . resets resetting scope) (drop (i+1) args)
    privateSeed _ _ Nothing=False
    -- Move ownership of a let-bound spine along one executed path. Any
    -- sibling use (including a projection of the tail) defeats transfer.
    lastUse x scope expr=case spine expr of
      (CVar f,[token,result]) | f==hookName CallLeave, S.notMember f scope,
        M.notMember f definitions, independent token -> CApp (CApp (CVar f) token) (descend result)
      (CVar f,args) | Just (i,w,(ps,_))<-M.lookup f plans,
        f `S.notMember` scope,w `S.notMember` scope,length args==length ps,
        args!!i==CVar x,all independent (take i args++drop (i+1) args) ->
          foldl CApp (CVar w) args
      _->case expr of
        CIf c a b | independent c -> CIf c (descend a) (descend b)
        CLet k a b | k/=x, independent a -> CLet k a (lastUse x (S.insert k scope) b)
        CLet k a b | not (mentions x b) -> CLet k (descend a) b
        CApp f a | independent f -> CApp f (descend a)
        CApp f a | not (mentions x a) -> CApp (descend f) a
        _->expr
      where independent e=not (mentions x e || resets resetting scope e)
            descend=lastUse x scope
    rewriteCall scope e=case spine e of
      (CVar f,args) | Just (i,w,(ps,_))<-M.lookup f plans, f `S.notMember` scope,
        w `S.notMember` scope, length args==length ps, fresh scope (args!!i),
        all (not . resets resetting scope) (drop (i+1) args) -> foldl CApp (CVar w) args
      _->case e of
        CLet x a b->let local=S.insert x scope
                        body=if fresh scope a then lastUse x local b else b
                    in CLet x (rewriteCall scope a) (rewriteCall local body)
        CIf c a b->CIf (rewriteCall scope c) (rewriteCall scope a) (rewriteCall scope b)
        CApp f x->CApp (rewriteCall scope f) (rewriteCall scope x)
        _->e
    rewritten=M.map (\(ps,b)->(ps,rewriteCall (S.fromList ps) b)) program
    references p=S.fromList [w | (_,b)<-M.elems p,CVar w<-nodes b,M.member w twins]
    reachable seen pending
      | S.null pending=seen
      | otherwise=let next=seen `S.union` pending
                  in reachable next (references (M.restrictKeys twins pending) S.\\ next)
    used=reachable S.empty (references rewritten)

-- Only publish arity and the ownership-transferring seed slot. Callers
-- still prove the seed fresh at the actual saturated call site.
spineBuilders :: S.Set Name -> Prog -> M.Map Name (Int,Int)
spineBuilders = spineBuildersWith M.empty

-- Builders publish their seed slot; a function every exit of which returns a
-- fresh spine whatever its arguments publishes slot -1. Fresh exits are Nil, a
-- cons onto a fresh spine, a call to a builder with a fresh seed, a call to
-- another fresh-returning function (a greatest fixed point: tail calls and the
-- region wrappers' inner and cold functions), and a call or loop region's
-- leave around one (its result is copied out or adopted whole). List.reverse
-- (revOnto seeded with Nil) is one; so is a builder that exits through it.
spineBuildersWith :: M.Map Name (Int,Int) -> S.Set Name -> Prog -> M.Map Name (Int,Int)
spineBuildersWith linked resetting definitions = M.union seeded unconditional
  where
    seeded=seededBuilders resetting definitions
    candidates=M.keysSet (M.filterWithKey (\n (ps,b)->not (null ps) && n `notElem` ps && bounded 256 b) definitions)
    fixed known=let next=S.filter (exitsFresh known) known in if next==known then known else fixed next
    unconditional=M.fromSet (\n->(length (fst (definitions M.! n)),-1)) (fixed (candidates S.\\ M.keysSet seeded))
    exitsFresh known n=let (ps,b)=definitions M.! n in exits known (S.fromList ps) b
    exits known scope (CLet x _ rest)=exits known (S.insert x scope) rest
    exits known scope (CIf _ a b)=exits known scope a && exits known scope b
    exits known scope e=freshExpr known scope e
    freshExpr known scope e
      | e==CMk 2 0 []=True
      | Just (_,rest)<-consFields definitions scope e=freshExpr known scope rest
      | otherwise=case spine e of
          (CVar f,[_,result]) | f `elem` [hookName CallLeave,hookName LoopLeave], S.notMember f scope,
                                M.notMember f definitions -> freshExpr known scope result
          (CVar f,args) | S.notMember f scope -> case M.lookup f definitions of
            Just ([],CMk 2 0 []) -> null args
            Just (ps,_) | length args==length ps ->
              S.member f known || seedFresh (M.lookup f seeded) args
            Just _ -> False
            Nothing -> seedFresh (M.lookup f linked) args
          _ -> False
        where seedFresh (Just (arity,i)) args=length args==arity && (i<0 || freshExpr known scope (args!!i))
              seedFresh Nothing _=False

seededBuilders :: S.Set Name -> Prog -> M.Map Name (Int,Int)
seededBuilders resetting definitions=M.mapMaybeWithKey summarize definitions
  where
    summarize n fn@(ps,_) = fmap ((,) (length ps)) (builderSlot n fn)
    -- A builder returns its private accumulator, or tail-calls itself
    -- with one new cons. No guard, payload or other argument sees the
    -- accumulator. Its output is private exactly when its seed is private.
    builderSlot name (ps,body)
      | name `elem` ps || null ps || not (bounded 256 body) = Nothing
      | otherwise = case [i | (i,p)<-zip [0..] ps,
                               Just True<-[ends i p (S.fromList ps) normalized]] of
          [i]->Just i
          _->Nothing
      where
        normalized=normIn (S.fromList ps) body
        safe p scope e=not (mentions p e || resets resetting scope e)
        ends i p scope (CLet k rhs rest)
          | k/=p && k/=name && safe p scope rhs=ends i p (S.insert k scope) rest
        ends i p scope (CIf c a b) | safe p scope c=(||) <$> ends i p scope a <*> ends i p scope b
        ends _ p _ (CVar k) | k==p=Just False
        ends i p scope expr=case spine expr of
          (CVar f,args) | f==name, length args==length ps,
            all (safe p scope) (take i args++drop (i+1) args),
            extends p scope (args!!i) -> Just True
          _ -> Nothing
        extends p scope (CLet k rhs rest) | k/=p && safe p scope rhs=extends p (S.insert k scope) rest
        extends p scope expr | Just (x,CVar t)<-consFields definitions scope expr=t==p && safe p scope x
        extends _ _ _=False

consFields _ _ (CMk 2 1 [x,t])=Just (x,t)
consFields definitions scope expr=case spine expr of
  (CVar f,[x,t]) | S.notMember f scope,
    Just ([h,r],CMk 2 1 [CVar a,CVar b])<-M.lookup f definitions,
    h==a && r==b -> Just (x,t)
  _ -> Nothing

-- A recursive backedge can carry the same private allocation into the
-- next activation. Candidate discovery alone grants no ownership: the
-- caller must supply a fresh root and every exit is checked above.
recursiveShape :: String -> Int -> Core -> Maybe Shape
recursiveShape name slot expr = case S.toList shapes of
  [shape@(_,_,n)] | n>0 && n<=64 -> Just shape
  _ -> Nothing
  where
    shapes=S.fromList [(t,v,length fs) | node<-nodes expr,
      (CVar f,args)<-[spine node], f==name, CMk t v fs:_<- [drop slot args]]

rewrite :: S.Set String -> Plans -> S.Set String -> Core -> Core
rewrite resetting plans = go
  where
    go locals e = case e of
      CLet x a b ->
        let a'=go locals a; scope=S.insert x locals; b'=go scope b
        in CLet x a' $ case resultShape a' of
          Just shape -> tryRoot resetting plans scope x shape b'
          _ -> b'
      CIf a b c -> CIf (go locals a) (go locals b) (go locals c)
      CApp a b -> CApp (go locals a) (go locals b)
      CMk t v fs -> CMk t v (map (go locals) fs)
      CProj k a -> CProj k (go locals a)
      CTagEq t v a -> CTagEq t v (go locals a)
      -- Never move a uniqueness proof into a closure.
      _ -> e

tryRoot :: S.Set String -> Plans -> S.Set String -> String -> Shape -> Core -> Core
tryRoot resetting plans locals x shape b = fromMaybe b $ do
  if bounded 256 b then pure () else Nothing
  b' <- aliases x b
  useRoot resetting plans locals x shape b'

-- Every successful path returns the original allocation, directly or through a
-- proven consuming callee. A non-tail transfer is allowed only if no old alias
-- survives into its continuation; its result becomes the next unique root.
consume :: S.Set String -> Plans -> S.Set String -> String -> Shape -> Core -> Maybe Core
consume resetting plans locals x shape e = case e of
  CMk t v fs | shape==(t,v,length fs), all ro fs ->
    Just (CApp (CApp (CVar "$reuse.fresh") (CVar x)) e)
  CVar y | x==y -> Just e
  CLet y a b | y/=x ->
    if ro a then CLet y a <$> consume resetting plans (S.insert y locals) x shape b
    else if not (mentions x b) then do
      a' <- consume resetting plans locals x shape a
      b' <- aliases y b
      CLet y a' <$> consume resetting plans (S.insert y locals) y shape b'

    else Nothing
  CIf c a b | ro c -> CIf c <$> consume resetting plans locals x shape a <*> consume resetting plans locals x shape b
  CErr _ -> Just e
  _ -> case spine e of
    (CVar f,args) | S.notMember f locals,
      Just (i,s,arity,worker)<-M.lookup f plans, s==shape, length args==arity,
      args!!i==CVar x, and [ro a | (j,a)<-zip [0..] args,j/=i] ->
        Just (foldl CApp (CVar worker) args)
    _ -> Nothing
  where ro e' = readsOnly x (width shape) e' && not (resets resetting locals e')

-- A last-use transfer may feed an arbitrary continuation, but that does not
-- prove that the entire expression returns the unique root. Keep this separate
-- from consume, whose return-shape guarantee permits subsequent transfers.
useRoot :: S.Set String -> Plans -> S.Set String -> String -> Shape -> Core -> Maybe Core
useRoot resetting plans locals x shape e = case consume resetting plans locals x shape e of
  Just out -> Just out
  Nothing -> case e of
    CLet y a b | y/=x ->
      if ro a then CLet y a <$> useRoot resetting plans (S.insert y locals) x shape b
      else if not (mentions x b) then do
        a' <- consume resetting plans locals x shape a
        pure (CLet y a' (tryRoot resetting plans (S.insert y locals) y shape b))
      else Nothing
    CIf c a b | ro c -> CIf c <$> useRoot resetting plans locals x shape a <*> useRoot resetting plans locals x shape b
    _ | ro e -> Just e
    _ -> Nothing
  where ro e' = readsOnly x (width shape) e' && not (resets resetting locals e')

-- Does evaluating e call something that may reset the pool?
resets :: S.Set String -> S.Set String -> Core -> Bool
resets resetting bound e=case e of
  CVar f->f `S.member` resetting
  CLet x rhs body->resets resetting bound rhs || resets resetting (S.insert x bound) body
  CApp {}->let (head',args)=spine e
               dynamic=case head' of CVar f->f `S.member` bound;_->True
           in dynamic || any (resets resetting bound) (head':args)
  CLam _ _->False -- constructing a closure does not execute its body
  _->any (resets resetting bound) (children e)

-- Only constructor-producing exits establish freshness. Error exits do not
-- return. The bounded search rejects differing branch shapes and bare aliases.
resultShape :: Core -> Maybe Shape
resultShape e | not (bounded 256 e) = Nothing
resultShape e = case shapes e of
  Just ss | [s@(t,v,n)]<-S.toList ss, n>0, n<=64 -> Just (t,v,n)
  _ -> Nothing
  where
    shapes (CMk t v fs) = Just (S.singleton (t,v,length fs))
    shapes (CLet _ _ b) = shapes b
    shapes (CIf _ a b) = S.union <$> shapes a <*> shapes b
    shapes (CErr _) = Just S.empty
    shapes _ = Nothing
width :: Shape -> Int
width (_,_,n)=n

-- Canonicalize aliases of this root only. The root is not rebound anywhere in
-- its scope; alias substitutions respect lexical shadowing. This includes
-- separate branch scopes, without claiming that arbitrary joins are unique.
aliases :: String -> Core -> Maybe Core
aliases x b | rebinds x b = Nothing
aliases x b = Just (go S.empty b)
  where
    go env e = case e of
      CVar y | S.member y env -> CVar x
      CLet y a rest ->
        let a'=go env a; env'=S.delete y env
        in if a'==CVar x then go (S.insert y env') rest
           else CLet y a' (go env' rest)
      CIf c a d -> CIf (go env c) (go env a) (go env d)
      CApp a d -> CApp (go env a) (go env d)
      CMk t v fs -> CMk t v (map (go env) fs)
      CProj k a -> CProj k (go env a)
      CTagEq t v a -> CTagEq t v (go env a)
      CLam ps a -> CLam ps (go (foldr S.delete env ps) a)
      _ -> e

-- Children may escape: a freshly allocated parent cannot be reachable from
-- its pre-existing children. Whole-parent uses and captures are rejected.
readsOnly :: String -> Int -> Core -> Bool
readsOnly x n = go
  where
    go (CVar y) = x/=y
    go (CProj k (CVar y)) | x==y = k>=0 && k<n
    go (CTagEq _ _ (CVar y)) | x==y = True
    go (CLet y a b) = x/=y && go a && go b
    go (CLam ps b) = x `notElem` ps && not (mentions x b)
    go e = all go (children e)
mentions :: String -> Core -> Bool
mentions x (CVar y) = x==y
mentions x e = any (mentions x) (children e)
rebinds :: String -> Core -> Bool
rebinds x (CLet y a b) = x==y || rebinds x a || rebinds x b
rebinds x (CLam ps b) = x `elem` ps || rebinds x b
rebinds x e = any (rebinds x) (children e)
spine :: Core -> (Core,[Core])
spine = go [] where go xs (CApp f a)=go (a:xs) f; go xs f=(f,xs)
bounded :: Int -> Core -> Bool
bounded n e = length (take (n+1) (nodes e))<=n
nodes :: Core -> [Core]
nodes e=e:concatMap nodes (children e)
children :: Core -> [Core]
children (CApp a b) = [a,b]
children (CLet _ a b) = [a,b]
children (CIf c a b) = [c,a,b]
children (CMk _ _ fs) = fs
children (CProj _ a) = [a]
children (CTagEq _ _ a) = [a]
children (CLam _ b) = [b]
children _ = []
