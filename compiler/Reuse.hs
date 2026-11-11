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
    plan True _ _ = Nothing
    plan False name (ps,CIf (CTagEq 2 tag (CVar xs)) a b) = do
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
    plan _ _ _=Nothing
    peelFields xs scope fields (CLet k rhs@(CProj i (CVar p)) body)
      | p==xs, i==0 || i==1, S.notMember k scope = do
          (wrap,bindings,rest)<-peelFields xs (S.insert k scope) (M.insert k rhs fields) body
          pure (CLet k rhs . wrap,bindings,rest)
    peelFields _ _ fields expr=Just (id,fields,expr)
    -- The TRMC builder has already read the current input's tail before
    -- it allocates the output cell. Reuse that input, then perform the
    -- original cursor link and recur with the saved tail. Only this clone's
    -- initializer supplies the disjoint output prefix and unique remainder.
    cursorPlan em name (ps@[xs,root,cursor],CIf (CTagEq 2 0 (CVar tested)) done step)
      | tested==xs, "$worker.trmc." `isPrefixOf` name, returns root done = do
          out<-cellStep em ps xs step $ \scope tailRef cell rest ->case rest of
            CLet k (CApp (CApp (CVar "$trmc.setTail") (CVar dst)) (CVar src)) call
              | dst==cursor,src==cell,S.notMember k scope,
                spine call==(CVar name,[tailRef,CVar root,CVar cell]) ->
                Just (CLet k (CApp (CApp (CVar "$trmc.setTail") (CVar dst)) (CVar src))
                  (foldl CApp (CVar worker) [tailRef,CVar root,CVar cell]))
            _ -> Nothing
          if worker `M.member` definitions || rebinds worker step || worker `elem` ps then Nothing
            else Just (worker,(ps,CIf (CTagEq 2 0 (CVar xs)) done out))
      where worker=spinePrefix em++"cursor."++name
    cursorPlan _ _ _=Nothing
    returns root (CVar x)=x==root
    returns root (CLet k (CApp (CVar f) (CInt 0)) rest)=f==entryTickName && k/=root && returns root rest
    returns _ _=False
    cursors em=M.mapMaybeWithKey (cursorPlan em) program
    cellStep em ps xs step finish=do
      (wrap,fields,body)<-peelFields xs (S.fromList ps) M.empty step
      [tailName]<-pure [k | (k,CProj 1 _)<-M.toList fields]
      let initial=S.fromList ps `S.union` M.keysSet fields
          -- An element computation may read the projected head, never the
          -- cursor, list or tail. Preserve every evaluation and fuel tick.
          allowed scope e=not (resets resetting scope e || any (\x->mentions x e) (tailName:ps))
          -- element reuse (the spineE family only): the list's elements are
          -- unique, so the old element may become the new one when the element
          -- is a same-layout constructor whose fields read it; otherwise the
          -- element must be fresh or the old one moved, so the output stays
          -- element-fresh, or the plan is refused
          heads=[k | (k,CProj 0 _)<-M.toList fields]
          element rest v=case v of
            _ | not em -> Just v
            CVar k | k `elem` heads -> Just v -- the old element, moved
            _ | [h]<-heads, not (mentions h rest), Just v'<-reuseElement h v -> Just v'
            _ | freshHead v -> Just v
            _ -> Nothing
          -- in the spineE family any other computation may read the old
          -- element only by projection or layout test, never keep it
          keepsNoHead e=not em || all (\h->readsOnly h 64 e) heads
          allocation scope (CLet k rhs rest) | k `S.notMember` scope,allowed scope rhs,
            em, cellHead rest==Just (CVar k), occurrences k rest==1 = do
              rhs'<-element rest rhs
              CLet k rhs' <$> allocation (S.insert k scope) rest
          allocation scope (CLet k rhs rest) | k `S.notMember` scope,allowed scope rhs,keepsNoHead rhs =
            CLet k rhs <$> allocation (S.insert k scope) rest
          allocation scope (CMk 2 1 [v,end]) | allowed scope v,isNil scope end = do
            v'<-if em then (case v of CVar _ -> Just v; _ -> element (CMk 2 0 []) v) else Just v
            Just (CApp (CApp (CVar "$reuse.fresh") (CVar xs)) (CMk 2 1 [v',end]))
          allocation _ _=Nothing
          cellHead (CLet _ _ r)=cellHead r
          cellHead (CMk 2 1 [v,_])=Just v
          cellHead _=Nothing
          go scope (CLet k value rest) | S.notMember k scope =
            case allocation scope value of
              Just reused | not em || all (\h->not (mentions h rest)) heads -> CLet k reused <$> finish (S.insert k scope) (CVar tailName) k rest
              Just _ -> Nothing
              -- in the spineE family an element bound before the cell is not
              -- checked for freshness: refuse rather than guess
              Nothing | allowed scope value, keepsNoHead value, not (em && isElementLet k rest) -> CLet k value <$> go (S.insert k scope) rest
              _ -> Nothing
          go _ _=Nothing
          isElementLet k rest=case [c | c<-nodes rest, Just (CVar v)<-[cellHead c], v==k] of
            [] -> False
            _ -> True
      wrap <$> go initial body
    startPlan em name (ps@[xs,seed],CIf (CTagEq 2 0 (CVar tested)) empty step)
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
          out<-cellStep em ps xs (pick step) $ \locals tailRef cell rest ->case spine rest of
            (CVar f,args) | args==[tailRef,CVar cell,CVar cell], Just (w,_)<-M.lookup f (cursors em),
                            f `S.notMember` locals,w `S.notMember` locals ->
              Just (foldl CApp (CVar w) args)
            _ -> Nothing
          pure (0,worker,(ps,CIf (CTagEq 2 0 (CVar xs)) emptyBranch out))
      where worker=spinePrefix em++"map."++name
    startPlan _ _ _=Nothing
    starters em=M.mapMaybeWithKey (startPlan em) program
    traversals em=M.mapMaybeWithKey (plan em) program
    loops em=M.mapMaybeWithKey (loopPlan em) program
    plans em=M.unions [traversals em,loops em,M.mapMaybeWithKey (regionEntry em) program]
    -- The borrowing entry owns the region lifecycle. Its consuming twin
    -- enters the same scope and changes only the destination of the inner
    -- call. The cold edge in that inner loop calls the ordinary cycle.
    regionEntry em name (ps,body)=do
      CLet seqId open (CLet markId mark (CApp (CApp (CVar leave) token) call))<-Just body
      let (callee,args)=spine call
          worker=spinePrefix em++"region."++name
      CVar inner<-Just callee
      (i,target,(params,_))<-M.lookup inner (loops em)
      if open/=CApp (CVar (hookName SequenceNumber)) (CInt 0) ||
         mark/=CApp (CVar (hookName PoolMark)) (CInt 0) ||
         leave/=hookName LoopLeave || token/=CVar seqId ||
         args/=map CVar (ps++[markId,seqId]) || length params/=length args ||
         i>=length ps || seqId==markId || any (`elem` ps) [seqId,markId] ||
         any (`elem` (seqId:markId:ps)) [inner,target,leave,hookName SequenceNumber,hookName PoolMark] ||
         M.member worker definitions ||
         name `S.member` excluded then Nothing else
        Just (i,worker,(ps,CLet seqId (mutating open) (CLet markId mark
          (CApp (CApp (CVar leave) token) (foldl CApp (CVar target) args)))))

    -- A traversal seeded with Nil returns precisely the consumed cells.
    -- Carry that fact through a self-tail call, keeping the public entry
    -- borrowing. A terminal arm can hand the list back to arbitrary code.
    -- linear in the body; a region's inner loop carries its room test and
    -- its exit path, so it is often past the 256 the other plans use
    loopPlan em name (ps,body)
      | name `elem` ps || name `S.member` excluded || not (bounded 2048 body) = Nothing
      | otherwise=listToMaybe [ (i,worker,(ps,out)) | (i,x)<-zip [0..] ps,
          worker `M.notMember` definitions, not (rebinds worker body), worker `notElem` ps,
          not (rebinds x body || rebinds name body),
          Just (True,out)<-[branch i x (S.fromList ps) body]]
      where
        worker=spinePrefix em++"loop."++name
        safe x scope e=not (mentions x e || resets resetting scope e)
        branch i x scope (CLet k rhs rest) | safe x scope rhs = do
          (changed,out)<-branch i x (S.insert k scope) rest
          pure (changed,CLet k rhs out)
        branch i x scope (CIf c a b) | safe x scope c = do
          (ca,a')<-branch i x scope a
          (cb,b')<-branch i x scope b
          pure (ca || cb,CIf c a' b')
        branch i x scope e
          -- the consuming inner loop's cold edge: its region now holds cells
          -- written in place, so every cycle from here carries the mutating
          -- bit on the sequence number (runtime.c REGION_MUT_BIT), and when
          -- the state passes through unchanged the cycle re-enters this twin
          | Just cyc<-cycleOf name,(CVar f,args@(_:_))<-spine e,f==cyc,f `S.notMember` scope,
            M.member f definitions,length args==length ps =
              let marked=init args++[mutating (last args)]
                  consumes=args!!i==CVar x && all (safe x scope) (take i args++drop (i+1) args)
              in Just (False,foldl CApp (CVar (if consumes then cycleTwinName em name else f)) marked)
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
          (CVar f,[source,seed]) | source==CVar x, Just (0,w,([_,_],_))<-M.lookup f (M.union (traversals em) (starters em)),
            S.notMember f scope,S.notMember w scope,isNil scope seed || (case seed of CVar k->S.member k nulls;_->False) ->
              Just (CApp (CApp (CVar w) source) seed)
          _ -> Nothing
    isNil scope (CVar f)=S.notMember f scope && M.lookup f definitions==Just ([],nil)
    isNil _ e=e==nil
    -- the cold edge of a consuming region loop: the ordinary cycle (copy out,
    -- reset) re-entering the consuming inner loop. After a cycle the state is
    -- the loop's alone: a fresh copy, or its own cells when the copy deferred.
    cycleTwins em=M.fromList [(cycleTwinName em inner,(cps,renameHead inner worker cbody)) |
      (inner,(_,worker,_))<-M.toList (loops em), Just cyc<-[cycleOf inner],
      Just (cps,cbody)<-[M.lookup cyc definitions], M.notMember (cycleTwinName em inner) definitions]
    renameHead from to e=case e of
      CVar v | v==from->CVar to
      CLet k a b->CLet k (renameHead from to a) (renameHead from to b)
      CApp f a->CApp (renameHead from to f) (renameHead from to a)
      CIf c a b->CIf (renameHead from to c) (renameHead from to a) (renameHead from to b)
      _->e
    twinsOf em=M.fromList ([(worker,body) | (_,worker,body)<-M.elems (plans em)++M.elems (starters em)] ++ M.elems (cursors em)) `M.union` cycleTwins em
    twins=twinsOf False `M.union` twinsOf True
    builders=spineBuildersWith linked resetting definitions
    -- Element freshness: every element of the spine is stored in that spine
    -- only (a fresh constructor, or an element moved out of a unique spine).
    -- A summary is the set of argument slots whose spines must have fresh
    -- elements for the result's to be; a greatest fixed point, like the
    -- fresh results. Only the spineE family relies on it.
    efSummaries=efFixedM True (M.fromSet (const S.empty) efCandidates)
    -- spine freshness by the same walk, elements ignored: a seeded builder
    -- behind a copy-out region wrapper is fresh when its seed is
    fsSummaries=efFixedM False (M.fromSet (const S.empty) efCandidates)
    efCandidates=M.keysSet (M.filterWithKey (\n (ps,b)->not (null ps) && n `notElem` ps && bounded 4096 b) definitions)
    efFixedM hm cur=let next=M.fromList [(n,r) | n<-M.keys cur, Just r<-[efFunctionM hm cur n]]
                    in if next==cur then cur else efFixedM hm next
    efFunctionM hm cur n=let (ps,b)=definitions M.! n in efExitsM hm cur ps b M.empty b
    efExitsM hm cur ps body env e=case e of
      CLet x rhs rest
        | Just _<-efTrmcStart hm ps body env x rhs rest -> Just S.empty
        | otherwise -> efExitsM hm cur ps body (M.insert x rhs env) rest
      CIf _ a b -> S.union <$> efExitsM hm cur ps body env a <*> efExitsM hm cur ps body env b
      _ -> efExprM hm cur ps body env e
    -- a TRMC builder's first step: a cell with a fresh element becomes the
    -- root and cursor of a worker that only ever stores fresh elements
    efTrmcStart hm _ body env x rhs rest=do
      (CVar w,args@(_:_:_))<-Just (spine rest)
      if "$worker.trmc." `isPrefixOf` w && drop (length args-2) args==[CVar x,CVar x]
         && not (any (mentions x) (take (length args-2) args)) && freshCell rhs
         && (not hm || (efCellHead body env rhs && efWorker w)) then Just () else Nothing
    efCellHead body env rhs=case cellHead' rhs of
      Just h -> freshHeadIn body (M.union (bindings rhs) env) h
      Nothing -> False
    cellHead' (CLet _ _ r)=cellHead' r
    cellHead' (CMk 2 1 [v,_])=Just v
    cellHead' _=Nothing
    freshHeadIn body env h=freshHead h || case h of
      CVar k | Just rhs<-M.lookup k env -> freshHead rhs && occurrences k body==1
      _ -> False
    efWorker w=case M.lookup w definitions of
      Just (_,b) -> and [freshHeadIn b (bindings b) h | CMk 2 1 [h,_]<-nodes b]
      Nothing -> False
    bindings b=M.fromList [(k,rhs) | CLet k rhs _<-nodes b]
    efExpr=efExprM True
    efExprM hm cur ps body env e
      | isNil S.empty e = Just S.empty
      | Just i<-param e = Just (S.singleton i)
      -- a cell's element may never reach the spine behind it (a builder
      -- storing its accumulator in a payload keeps those cells alive)
      | Just (h,t)<-consFields definitions (S.fromList ps) e =
          if any (\v->mentions v h) (S.toList (reach (S.fromList [y | CVar y<-nodes t]))) then Nothing
          else S.union <$> (if hm then efHead h else Just S.empty) <*> efExprM hm cur ps body env t
      | otherwise=case spine e of
          (CVar f,[_,result]) | f `elem` [hookName CallLeave,hookName LoopLeave], M.notMember f definitions ->
            efExprM hm cur ps body env result
          (CVar f,args) | Just need<-M.lookup f cur, Just (fps,_)<-M.lookup f definitions, length args==length fps ->
            S.unions <$> mapM (\j->efExprM hm cur ps body env (args!!j)) (S.toList need)
          (CVar f,args) | M.notMember f definitions, Just (arity,need)<-stdMovers hm f, length args==arity ->
            S.unions <$> mapM (\j->efExprM hm cur ps body env (args!!j)) need
          _ -> case e of
            CLet x rhs rest -> efExprM hm cur ps body (M.insert x rhs env) rest
            -- a region cycle's packed state, read back: the copy is fresh, a
            -- deferral hands the same state back
            CVar k | Just rhs<-M.lookup k env, Just c<-cycled rhs Nothing -> efExprM hm cur ps body env c
            CProj j (CVar k) | Just rhs<-M.lookup k env, Just c<-cycled rhs (Just j) -> efExprM hm cur ps body env c
            _ -> Nothing
      where
        cycled rhs slot=case (spine rhs,slot) of
          ((CVar c,[_,packed]),Nothing) | c==hookName Cycle -> Just packed
          ((CVar c,[_,CMk _ _ comps]),Just j) | c==hookName Cycle, j<length comps -> Just (comps!!j)
          _ -> Nothing
        -- the variables a tail depends on, through the bindings in scope
        reach known=let next=S.unions (known:[S.fromList [y | CVar y<-nodes rhs] | k<-S.toList known, Just rhs<-[M.lookup k env]])
                    in if next==known then known else reach next
        -- a parameter, or the tail of a parameter's cell
        param (CVar p) | Just i<-lookup p (zip ps [0..])=Just i
        param (CVar k) | Just rhs<-M.lookup k env, Just c<-cycled rhs Nothing=param c
        param (CProj j (CVar k)) | Just rhs<-M.lookup k env, Just c<-cycled rhs (Just j)=param c
        param (CVar k) | Just rhs<-M.lookup k env=param rhs
        param (CProj 1 (CVar p)) | Just i<-lookup p (zip ps [0..])=Just i
        param _=Nothing
        -- an element: fresh, or moved out of a parameter's cell once
        efHead h | freshHeadIn body env h=Just S.empty
        efHead (CVar k) | Just (CProj 0 (CVar p))<-M.lookup k env, Just i<-lookup p (zip ps [0..]),
                          occurrences k body==1=Just (S.singleton i)
        efHead _=Nothing
    -- std/list's revOnto moves every element of its first argument onto its
    -- second, and reverse is revOnto onto Nil: their results' elements are
    -- fresh when their arguments' are. Their bodies live in another unit, so
    -- the linked builder table vouches for them (revOnto seeds slot 1,
    -- reverse is a fresh-returning wrapper).
    -- (spine only: revOnto's new cells are fresh, its tail is the second
    -- argument's spine; reverse's are all new)
    stdMovers hm f
      | "revOnto@" `isPrefixOf` f, M.lookup f linked==Just (2,1) = Just (2,if hm then [0,1] else [1])
      | "reverse@" `isPrefixOf` f, M.lookup f linked==Just (1,-1) = Just (1,if hm then [0] else [])
      | otherwise=Nothing
    elementsFresh scope e=efExpr efSummaries [] (CVar "$no.body") M.empty (stripLets e)==Just S.empty
    stripLets (CLet _ _ r)=stripLets r
    stripLets e=e
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
    -- a function whose spine summary the call's arguments meet (a seeded
    -- builder behind a region wrapper, a map entry)
    summaryFresh scope e=efExprM False fsSummaries [] (CVar "$no.body") M.empty (stripLets e)==Just S.empty
    -- Move ownership of a let-bound spine along one executed path. Any
    -- sibling use (including a projection of the tail) defeats transfer.
    lastUse x scope expr=case spine expr of
      (CVar f,[token,result]) | f==hookName CallLeave, S.notMember f scope,
        M.notMember f definitions, independent token -> CApp (CApp (CVar f) token) (descend result)
      (CVar f,args) | Just (i,w,(ps,_))<-M.lookup f (plans False),
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
      (CVar f,args) | Just (i,w,(ps,_))<-M.lookup f (plans True), f `S.notMember` scope,
        w `S.notMember` scope, length args==length ps, fresh scope (args!!i) || summaryFresh scope (args!!i), elementsFresh scope (args!!i),
        all (not . resets resetting scope) (drop (i+1) args) -> foldl CApp (CVar w) args
      (CVar f,args) | Just (i,w,(ps,_))<-M.lookup f (plans False), f `S.notMember` scope,
        w `S.notMember` scope, length args==length ps, fresh scope (args!!i) || summaryFresh scope (args!!i),
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
    -- the exit walk only descends lets and branches: a looser bound than the
    -- builders' (a TRMC map with its element inlined is often past 256)
    candidates=M.keysSet (M.filterWithKey (\n (ps,b)->not (null ps) && n `notElem` ps && bounded 4096 b) definitions)
    fixed known=let next=S.filter (exitsFresh known) known in if next==known then known else fixed next
    unconditional=M.fromSet (\n->(length (fst (definitions M.! n)),-1)) (fixed (candidates S.\\ M.keysSet seeded))
    exitsFresh known n=let (ps,b)=definitions M.! n in exits known (S.fromList ps) b
    -- a TRMC builder's first step: a fresh cell becomes the cursor worker's
    -- root and cursor (its last two parameters); the worker links fresh cells
    -- behind it and returns the root. No other argument may see the cell.
    exits _ scope (CLet x rhs rest)
      | freshCell rhs,(CVar w,args@(_:_:_))<-spine rest,"$worker.trmc." `isPrefixOf` w,
        S.notMember w scope,[CVar r,CVar c]<-drop (length args-2) args,r==x,c==x,
        not (any (mentions x) (take (length args-2) args))=True
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

-- the element-reusing rewrite: the value-producing constructor at e's tail
-- (through lets that only bind and return it, and ticks) is built over h when
-- h has the same layout, and allocated otherwise. The fields are bound first
-- (every read of h happens before the store), and the layout test reads h's
-- header: some field projects h, so h is a constructor. The old element is
-- unique (the spineE family's invariant), so nothing else sees the write.
reuseElement :: String -> Core -> Maybe Core
reuseElement h whole
  | any projects (nodes whole), Just (out,True)<-go whole = Just out
  | otherwise = Nothing
  where
    -- (rewritten, whether some exit now builds over h); every exit is either
    -- a rewritten constructor or a trap
    go e=case e of
      CLet y a b | returnsVar y b, Just (a',r)<-go a -> Just (CLet y a' b,r)
      -- a binding before the constructor runs before the store: it may read
      -- h by projection, never keep it
      CLet y a b | y/=h, readsOnly h 64 a, Just (b',r)<-go b -> Just (CLet y a b',r)
      CIf c a b | readsOnly h 64 c, Just (a',ra)<-go a, Just (b',rb)<-go b -> Just (CIf c a' b',ra || rb)
      CErr _ -> Just (e,False)
      CMk t v fs | t/=2, not (null fs), length fs<=64, all (readsOnly h (length fs)) fs,
        all (\x->not (mentions x e)) (names fs) ->
          Just (foldr (\(x,f) b->CLet x f b)
                  (CIf (CTagEq t v (CVar h))
                       (CApp (CApp (CVar "$reuse.fresh") (CVar h)) (CMk t v (map CVar (names fs))))
                       (CMk t v (map CVar (names fs))))
                  (zip (names fs) fs),True)
      _ -> Nothing
    names fs=["$elem."++h++"."++show i | i<-[0..length fs-1]]
    -- some read of a field of h in the element computation: h is a
    -- constructor, so the layout test may read its header
    projects n=case n of
      CProj _ (CVar y) -> y==h
      _ -> False
    returnsVar y (CVar z)=y==z
    returnsVar y (CLet k (CApp (CVar f) (CInt 0)) b)=f==entryTickName && k/=y && returnsVar y b
    returnsVar _ _=False
-- a freshly constructed (non-list) value: a constructor in every exit, seen
-- through lets that bind it and return it past fuel ticks
freshHead :: Core -> Bool
freshHead e=case e of
  CMk t _ fs -> t/=2 && not (null fs)
  CLet y a b | returnsVar b -> freshHead a
             | otherwise -> freshHead b
    where returnsVar (CVar z)=z==y
          returnsVar (CLet k (CApp (CVar f) (CInt 0)) r)=f==entryTickName && k/=y && returnsVar r
          returnsVar _=False
  CIf _ a b -> freshHead a && freshHead b
  CErr _ -> True
  CApp (CApp (CVar "$reuse.fresh") (CVar _)) c -> freshHead c
  _ -> False
occurrences :: String -> Core -> Int
occurrences x e=length [() | CVar y<-nodes e, y==x]

-- ReceiveTurns' region loop names: the inner loop and its cold cycle
cycleOf :: Name -> Maybe Name
cycleOf n | "$loop.in." `isPrefixOf` n=Just ("$loop.cycle."++drop (length "$loop.in.") n)
cycleOf _=Nothing
cycleTwinName :: Bool -> Name -> Name
cycleTwinName em inner=spinePrefix em++"cycle."++inner
-- the twin families: spine reuse, and spine plus element reuse (used only on
-- a list whose elements are fresh too)
spinePrefix :: Bool -> String
spinePrefix False="$worker.spine."
spinePrefix True="$worker.spineE."
-- runtime.c REGION_MUT_BIT: the region's loop overwrites its state in place
regionMutBit :: Integer
regionMutBit=2^(58::Int)
mutating :: Core -> Core
mutating seqValue=CApp (CApp (CVar "bor") seqValue) (CInt regionMutBit)

-- a cons whose tail is Nil, after any lets that compute its head
freshCell :: Core -> Bool
freshCell (CLet _ _ rest)=freshCell rest
freshCell (CMk 2 1 [_,t])=t==CMk 2 0 [] || t==CVar "Nil"
freshCell _=False

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
