{-# LANGUAGE LambdaCase #-}

-- A tail-recursive receive SCC becomes a trampoline of value-only PAPs.
-- This runs AFTER checking source types and BEFORE specialization/inlining.
-- The private runtime protocol is existential: (True, next PAP) or
-- (False, the original result). It is not a polymorphic source primitive.
--
-- Stage 2 of docs/2026-10-23-COST-SIZED-REGIONS.md (docs/2026-10-24-REGIONS-STAGE2.md)
-- widens what becomes a turn:
--   * a self tail call is a boundary too: a tail-recursive SCC that never
--     receives gets the same trampoline when its iteration allocates (the
--     cost pass's word on every primitive it calls; an unknown callee is
--     assumed to) and every live parameter is of bounded size, so the copy
--     out of the arguments cannot grow with the loop;
--   * a live parameter that is loop-invariant (every call in the SCC passes
--     the caller's own parameter in that slot) or function-typed needs no
--     value evidence: it is copied as it is, and a Vector in it, or anywhere
--     in the state, is MOVED by the runtime when this actor's base pool owns
--     it (vec_movable_here) and copied otherwise;
--   * the notes say which rule placed each boundary; --cost prints them.
module ReceiveTurns
  (Rewrite,receiveTurns,rewriteProgram,rewriteNotes,rewriteGenerated,
   Generated,GeneratedKind(..),generatedKind,generatedSource,generatedParameters,
   generatedState,generatedSourceInterface,Group,groupMembers,groupPure,groupLooped,groupBoundaries,
   groupInvariants,groupLive,rewriteGroups,rewriteCallTargets,rewriteInput,validateSource,publish) where

import Data.List (intercalate, foldl')
import Data.Graph (SCC (..), stronglyConnComp)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Core.Syntax
import Compiler.DataLayout (tupWideBase)
import Core.Region.Interface
import qualified Core.Region.Types as Region
import qualified Core.Region.CallSites as Sites
import Type.Syntax (Type (..))
import Control.Monad (unless,forM_)
import qualified Core.Region.Analysis as Analysis
import Cost (primAllocates, allocGrows, CostEq)

data GeneratedKind=LoopInner | LoopCycle | ReceiveThunk | ReceiveJoin deriving (Eq,Show)
data Generated=Generated
  { generatedKind :: GeneratedKind,generatedSource :: Name,generatedParameters :: [Name],
    generatedState :: [Name],generatedSourceInterface :: Maybe Interface } deriving Show
data Group=Group
  { groupMembers :: [Name],groupPure :: Bool,groupBoundaries :: S.Set Name,
    groupInvariants :: S.Set (Name,Int),groupLive :: M.Map Name (S.Set Name),
    -- the loop form: a direct tail loop that tests the allocation clock at
    -- its boundaries and cycles its region once a slab has filled. Pure
    -- loops always; receive loops too, except in a QOS process image (its
    -- plane memory reclaims per turn through the $receiveLoop trampoline)
    groupLooped :: Bool } deriving Show
data Authority=Authority Prog (S.Set Name) Prog (S.Set Name)
data Rewrite=Rewrite Prog [String] (M.Map Name Generated) [Group] (M.Map Name (S.Set Name)) Authority
rewriteProgram (Rewrite p _ _ _ _ _)=p
rewriteNotes (Rewrite _ ns _ _ _ _)=ns
rewriteGenerated (Rewrite _ _ gs _ _ _)=gs
rewriteGroups (Rewrite _ _ _ gs _ _)=gs
rewriteCallTargets (Rewrite _ _ _ _ ts _)=ts
rewriteInput (Rewrite _ _ _ _ _ (Authority p _ _ _))=p
-- Publish a checked producer's new projection, preserving the planner's
-- source/liveness authority and checking every physical helper declaration.
publish :: Rewrite -> Prog -> Either String Rewrite
publish (Rewrite _ notes generated groups targets authority@(Authority before _ _ _)) after=do
  let facts=M.mapWithKey (\name g->g {generatedParameters=maybe (generatedParameters g) fst (M.lookup name after)}) generated
      result=Rewrite after notes facts groups targets authority
  verifyRewrite before result
  pure result

-- Helper-body passes may simplify a logical source graph, but cannot use the
-- old region contract after making a dead slot live, weakening invariance,
-- adding an unmanaged cycle, or invalidating a non-returning result proof.
validateSource :: Rewrite -> Prog -> Either String ()
validateSource (Rewrite _ _ _ groups _ (Authority before membership context shared)) current=do
  let bad why=Left ("typed region proof: "++why)
      liveNow=Analysis.liveParameters membership current
      refs (ps,b)=S.fromList (freeVars b) S.\\ S.fromList ps
      edges p=M.map refs p
      reaches graph seeds=let next=seeds<>M.keysSet (M.filter (not . S.null . S.intersection seeds) graph)
                          in if next==seeds then seeds else reaches graph next
      effect names=let seeds=S.fromList names
                       external=reaches (edges (current `M.union` context)) seeds `S.intersection` shared
                   in reaches (edges current) (seeds<>external)
      managed=effect ["Sys.poolReset","Sys.arena","Sys.loop","Sys.loopWith","$receiveLoop","$loopLeave"]
      receiving=effect ["receive","receiveFrom","receiveRes","receiveNow","receiveFromRes","receiveFromNow"]
  forM_ groups $ \g->do
    let members=S.fromList (groupMembers g)
        invariantsNow=Analysis.invariantParameters current (groupMembers g)
        rest=members S.\\ groupBoundaries g
        cycles p=[() | CyclicSCC _<-stronglyConnComp
          [(n,n,S.toList (refs (p M.! n) `S.intersection` rest)) | n<-S.toList rest]]
    unless (all (`M.member` current) (groupMembers g)) (bad "source group lost a definition")
    unless (S.null (members `S.intersection` managed)) (bad "source group acquired explicit region management")
    unless (not (groupPure g) || S.null (members `S.intersection` receiving)) (bad "pure loop acquired a receive effect")
    unless (not (null (cycles before)) || null (cycles current)) (bad "a control cycle bypasses the boundary set")
    unless (groupInvariants g `S.isSubsetOf` invariantsNow) (bad "loop-invariant argument proof changed")
    unless (not (Analysis.nonReturning before members) || Analysis.nonReturning current members)
      (bad "non-returning result proof changed")
    forM_ (S.toList (groupBoundaries g)) $ \n->do
      let oldPs=fst (before M.! n);newPs=fst (current M.! n)
          oldLive=S.fromList [i | (i,p)<-zip [0::Int ..] oldPs,p `S.member` (groupLive g M.! n)]
          newLive=S.fromList [i | (i,p)<-zip [0::Int ..] newPs,p `S.member` (liveNow M.! n)]
      unless (length oldPs==length newPs && newLive `S.isSubsetOf` oldLive) (bad ("dead argument became observable at "++n))

receiveTurns :: Bool -> Bool -> Bool -> M.Map Name (CostEq,CostEq) -> M.Map Name Interface
             -> Region.ValueModel -> Sites.CallSites -> S.Set Name -> Prog -> S.Set Name -> Prog -> Either String Rewrite
receiveTurns loopRegions callRegionsOn receiveLoops contextEqs interfaces model sites shared context joins prog = do
  let result=Rewrite final (notes++callNotes) generated selectedGroups callTargets (Authority prog (M.keysSet membership) context shared)
  verifyRewrite prog result
  pure result
  where
    -- Region.copyable/bounded walk nominal declarations afresh on every
    -- call, and the boundary checks ask about the same few interface types
    -- thousands of times: answer each interface type once (the pair's
    -- components stay lazy, so an unasked property is never computed)
    typeProperties = M.fromList [(t, (Region.bounded model t, Region.copyable model t))
                                | signature <- M.elems interfaces, t <- interfaceResult signature : interfaceArguments signature]
    boundedType t = maybe (Region.bounded model t) fst (M.lookup t typeProperties)
    copyableType t = maybe (Region.copyable model t) snd (M.lookup t typeProperties)
    refs ps = S.fromList . filter (`notElem` ps) . freeVars
    edges p = M.map (uncurry refs) p
    reaches graph seeds = fix seeds
      where fix known = let next = known `S.union` M.keysSet (M.filter (not . S.null . S.intersection known) graph)
                         in if next == known then known else fix next
    -- Only explicit shared identities cross the context boundary. Checked
    -- private code has a stable owner; compatibility counters remain local.
    effect names =
      let seeds = S.fromList names
          external = reaches (edges context) seeds `S.intersection` shared
       in reaches (edges prog) (seeds `S.union` external)
    receivers = effect ["receive", "receiveFrom", "receiveRes", "receiveNow", "receiveFromRes", "receiveFromNow"]
    managed = effect ["Sys.poolReset", "Sys.arena", "Sys.loop", "Sys.loopWith", "$receiveLoop", "$loopLeave"]
    recGroups = [ns | CyclicSCC ns <- stronglyConnComp
                  [(n, n, S.toList (refs ps b `S.intersection` M.keysSet prog)) | (n,(ps,b)) <- M.toList prog]]
    receiveGroups = [ns | ns <- recGroups, any (`S.member` receivers) ns]
    -- a pure tail-recursive group is a boundary when its iteration allocates
    -- (rule 2 of the proposal: the arguments are the state, the rest scratch)
    pureGroups = [ns | ns <- recGroups, not (any (`S.member` receivers) ns), any (allocates (S.fromList ns)) ns]
    groups = receiveGroups ++ pureGroups
    pureSet = S.fromList (map S.fromList pureGroups)
    isPure ns = S.member (S.fromList ns) pureSet
    -- A receive loop in the loop form (docs/2026-10-26-RECEIVE-TURNS-PER-SLAB.md):
    -- its region opens at entry, and a turn's scratch and the messages it
    -- received die when the region cycles, once a slab has filled
    looped ns = isPure ns || receiveLoops
    membership = M.fromList [(n,S.fromList ns) | ns <- groups, n <- ns]
    results = map transform groups
    rewritten = M.unions [p | (ns, Right p) <- zip groups results, loopRegions || not (isPure ns)]
    -- a declined pure group is noise in a --cost report (every list helper in
    -- the closure is one): those lines carry a "(declined)" tag the driver
    -- prints only under FPR_RECEIVE_NOTES, with a count under --cost
    notes = [(if isPure ns then (if isLeft r then "turn-regions (declined): " else if loopRegions then "turn-regions: " else "turn-regions (candidate): ") else "receive-turns: ") ++ unwords ns ++ ": "
              ++ either id (const (if isPure ns then (if loopRegions then "loop region at the self tail call (opens after a slab, resets per slab)" else "loop region not placed (FPR_NO_LOOP_REGIONS=1)")
                                   else if looped ns then "turn region at the receive (opens at entry, cycles per slab)" else "automatic value-state turn regions")) r
            | (ns,r) <- zip groups results]
    turned = M.union rewritten prog
    -- the loops that got a region: a call into one needs no call region
    loopEntries = S.fromList (concat [ns | (ns, Right _) <- zip groups results, isPure ns, loopRegions])
    (final, callNotes) = if callRegionsOn then callRegions turned else (turned, [])
    generated=M.fromList (concat
      [describe ns | (ns,Right _)<-zip groups results,loopRegions || not (isPure ns)])
    selectedGroups=[Group ns (isPure ns) (entries ns) (invariants ns) (M.restrictKeys live (S.fromList ns)) (looped ns)
      | (ns,Right _)<-zip groups results,loopRegions || not (isPure ns)]
    callCandidates=[g | (g,(ps,_))<-M.toList (prog `M.union` context),costly g (length ps)]
    callCandidateSet=S.fromList callCandidates
    callTargets=if not callRegionsOn then M.empty else M.fromList
      [(n,targets) | (n,body)<-M.toList prog,M.member n interfaces,
        let targets=S.filter (\g->g `S.member` callCandidateSet && copyableAt n g && not (sameGroup n g)) (refs (fst body) (snd body)),
        not (S.null targets)]
    sameGroup a b=case (M.lookup a sccIx,M.lookup b sccIx) of (Just x,Just y)->x==y;_->False
    describe ns=concatMap one ns
      where
        boundaries=entries ns
        invariant=invariants ns
        one n=let ps=fst (prog M.! n)
                  state=[p | (i,p)<-zip [0..] ps,p `elem` kept n,S.notMember (n,i) invariant]
                  make kind params fields=Generated kind n params fields (M.lookup n interfaces)
                  boundary=n `S.member` boundaries
              in if looped ns then
                   (loopName n,make LoopInner (ps++["$loop.mark","$loop.seq"]) state):
                   [(cycleName n,make LoopCycle (ps++["$loop.mark","$loop.seq"]) state) | boundary]
                 else [(receiveName boundary n,if boundary
                   then make ReceiveThunk ["$receive.state","$receive.unit"] (kept n)
                   else make ReceiveJoin ps [])]
    loopName n="$loop.in."++n
    cycleName n="$loop.cycle."++n
    receiveName boundary n=(if boundary then "$receive.turn." else "$receive.local.")++n
    isLeft = either (const True) (const False)
    -- does an iteration of n allocate SCRATCH?  Counted: on a path that ends
    -- in a call into the group, every allocation except the constructors
    -- handed to that call as its arguments (they are the next state: copied
    -- out by the turn, or unboxed by the field workers when the loop stays a
    -- jump; counting them made every `loop n (a + n, b + 1)` a turn) and
    -- everything on an exit path (allocated once, not per iteration).
    -- Constructors with fields, closures and the primitives the cost pass
    -- says allocate count; a call to a global outside the group that is not
    -- a primitive is assumed to allocate.
    allocates group n = let (ps, b) = prog M.! n in iterAlloc (S.fromList ps) b
      where
        -- A vector read allocates only for a Vector of records or tuples (a
        -- row is built); Int, float and boxed elements come back as the
        -- word itself (runtime/vec.c row_at/get_cell). The vector's type is
        -- its parameter's checked interface type, through let aliases; any
        -- other read keeps the unknown-code rule and counts as allocating.
        -- A loop region around a loop that never allocates is only
        -- overhead (tests/bench/vecread.fpr, 10%).
        -- names bound exactly once (parameters included), so an alias means
        -- the same value wherever it is read; a rebound name is never typed
        binders e = case e of
          CLet x a b' -> (x, case a of CVar y -> Just y; _ -> Nothing) : binders a ++ binders b'
          CLam xs b' -> [(x, Nothing) | x <- xs] ++ binders b'
          CIf c t f -> binders c ++ binders t ++ binders f
          CApp a b' -> binders a ++ binders b'
          CMk _ _ fs -> concatMap binders fs
          CTagEq _ _ x -> binders x
          CProj _ x -> binders x
          _ -> []
        vectorTypes = let (ps, b) = prog M.! n
                          bs = [(p, Nothing) | p <- ps] ++ binders b
                          once = M.keysSet (M.filter (== (1 :: Int)) (M.fromListWith (+) [(x, 1) | (x, _) <- bs]))
                          aliasOf = M.fromList [(x, y) | (x, Just y) <- bs, S.member x once]
                          params = case M.lookup n interfaces of
                            Just signature | length (interfaceArguments signature) == length ps ->
                              M.fromList [(p, t) | (p, t) <- zip ps (interfaceArguments signature), S.member p once]
                            _ -> M.empty
                          resolve depth x | depth > (length bs) = Nothing
                                          | Just t <- M.lookup x params = Just t
                                          | Just y <- M.lookup x aliasOf = resolve (depth + 1) y
                                          | otherwise = Nothing
                      in M.fromList [(x, t) | (x, _) <- bs, Just t <- [resolve 0 x]]
        flatVector h = case M.lookup h vectorTypes of
          Just (TAp (TC "Vector") t) -> flatElement t
          _ -> False
        flatElement t = case t of
          TC c -> c `elem` ["Int","Bool","Unit","Atom","I64","Word","F64","F32","I32","String"]
          TAp _ _ -> not (isRow t)
          _ -> False
        isRow t = case spineT t of (TC c, _) -> c `notElem` ["List","Vector","Result","Option","Map"]; _ -> True
        spineT = goT [] where goT as (TAp g a) = goT (a:as) g; goT as h = (h,as)
        vectorRead g as = case (g, as) of
          ("$vec.len", [_]) -> Just False
          (_, [_, CVar h]) | g `elem` ["$vec.at","$vec.get"], flatVector h -> Just False
          _ -> Nothing
        groupCall bound e = case spine e of
          (CVar g, as) | not (S.member g bound), S.member g group, not (null as) -> Just as
          _ -> Nothing
        reach bound e = case groupCall bound e of
          Just _ -> True
          Nothing -> case e of
            CLet x a b' -> reach bound a || reach (S.insert x bound) b'
            CIf c t f -> reach bound c || reach bound t || reach bound f
            CApp a b' -> reach bound a || reach bound b'
            CLam xs b' -> reach (bound `S.union` S.fromList xs) b'
            CMk _ _ fs -> any (reach bound) fs
            CTagEq _ _ x -> reach bound x
            CProj _ x -> reach bound x
            _ -> False
        iterAlloc bound e = case groupCall bound e of
          Just as -> any (argAlloc bound) as
          Nothing -> case e of
            CLet x a b' -> let bound' = S.insert x bound
                            in (reach bound a && iterAlloc bound a)
                               || (reach bound' b' && (rawAlloc bound a || iterAlloc bound' b'))
            CIf c t f -> ((reach bound t || reach bound f) && rawAlloc bound c)
                         || (reach bound t && iterAlloc bound t)
                         || (reach bound f && iterAlloc bound f)
            _ -> reach bound e && rawAlloc bound e
        -- an argument of the recursive call: its constructors are the state
        argAlloc bound e = case e of
          CMk _ _ fs -> any (argAlloc bound) fs
          _ -> rawAlloc bound e
        rawAlloc bound e = case spine e of
          (CVar g, as) | not (S.member g bound), not (null as) ->
            if S.member g group then any (argAlloc bound) as
            else case maybe (primAllocates g (length as)) Just (vectorRead g as) of
              Just False -> any (rawAlloc bound) as
              Just True -> True
              Nothing -> True -- unknown code: assumed to allocate
          _ -> case e of
            CLet x a b' -> rawAlloc bound a || rawAlloc (S.insert x bound) b'
            CIf c t f -> rawAlloc bound c || rawAlloc bound t || rawAlloc bound f
            CApp a b' -> rawAlloc bound a || rawAlloc bound b'
            CLam _ _ -> True
            CMk _ _ fs -> not (null fs) || any (rawAlloc bound) fs
            CTagEq _ _ x -> rawAlloc bound x
            CProj _ x -> rawAlloc bound x
            _ -> False
    -- ---- call regions (rule 3 of the proposal) ----------------------------
    -- A saturated call to a function outside the caller's recursive group
    -- whose allocation grows with its input or cannot be named (Cost) and
    -- whose result is a copyable value gets a pending region: $callPend
    -- before the call, $callLeave after.  Nothing happens unless the call
    -- uses a slab of the pool it started in; then the allocator opens the
    -- region and $callLeave copies the result out.  The copy costs at most
    -- the result, once per wrapped call: a call into the caller's own
    -- recursive group is never wrapped, so no copy compounds with recursion
    -- (the proposal's rule 4); the threshold rule 3 left open is the slab.
    -- Not around a call into a loop with a region of its own.
    -- the whole program's equations (computed once, Compile.hs): a call into
    -- another unit is judged by its callee's own cost, by source name
    callEqs = contextEqs
    -- an opaque allocation grows when it stands for unverified recursion (a
    -- function of the program) or an unknown argument ("?..."); an
    -- undeclared primitive is a constant (I64 boxing, a string op's result)
    growingOmega nm = M.member nm prog || M.member nm context || take 1 nm == "?"
    sccIx = M.fromList [(n, i) | (i, c) <- zip [0 :: Int ..] (stronglyConnComp [(n, n, S.toList (refs ps b `S.intersection` M.keysSet prog)) | (n, (ps, b)) <- M.toList prog]), n <- flat c]
      where flat (AcyclicSCC n) = [n]; flat (CyclicSCC ns) = ns
    costly g arity = case (M.lookup g prog `orElse` M.lookup g context,M.lookup g interfaces,M.lookup g callEqs) of
      (Just (ps,_),Just signature,Just (_,eq)) | length ps==arity,interfaceArity signature==arity,
        callableRegionEntry signature ->
          copyableType (interfaceResult signature) && allocGrows growingOmega eq && S.notMember g loopEntries
      _->False
    copyableAt owner g=Sites.mayCopyResult sites (maybe owner generatedSource (M.lookup owner generated)) g
    callRegions p = (M.mapWithKey site p, [ "call-regions: " ++ n ++ ": " ++ show k ++ " call(s) under a pending region"
                                          | (n, k) <- M.toList counts, k > 0 ])
      where
        -- every function, the loop bodies included: a costly call inside a loop
        -- is where a region pays most (dtree's `run` inside repeatRuns); the
        -- loop's own boundary only reclaims per slab of its iteration.  Not the
        -- generated bookkeeping helpers. Their explicit roles, rather than
        -- a spelling convention, decide which bodies can contain call regions.
        eligible n = M.member n prog && (M.member n interfaces ||
          maybe False ((==LoopInner) . generatedKind) (M.lookup n generated))
        rewritten' = M.mapWithKey (\n (ps, b) -> if eligible n then let (b', k) = wrap n (S.fromList ps) 0 b in ((ps, b'), k) else ((ps, b), 0)) p
        site n _ = fst (rewritten' M.! n)
        counts = M.map snd rewritten'
        sameGroup a b = case (M.lookup a sccIx, M.lookup b sccIx) of (Just x, Just y) -> x == y; _ -> False
        -- wrap: (expression, sites so far) -> (expression', sites)
        wrap n bound k e = case spine e of
          (CVar g, as@(_ : _)) | S.notMember g bound, not (sameGroup n g), copyableAt n g, costly g (length as) ->
            -- the arguments are evaluated inside the pending region, as part
            -- of the call: a trip moves only later allocations to the arena,
            -- and the arguments die with the call (unbound, so the field
            -- workers still see a literal constructor argument)
            let (as', k') = wrapList n bound k as
                tok = "$call." ++ show k' ++ ".t"
                callE = foldl CApp (CVar g) as'
             in (CLet tok (CApp (CVar "$callPend") (CInt 0)) (CApp (CApp (CVar "$callLeave") (CVar tok)) callE), k' + 1)
          _ -> case e of
            CApp a b' -> let (a', k1) = wrap n bound k a; (b2, k2) = wrap n bound k1 b' in (CApp a' b2, k2)
            CLam xs b' -> let (b2, k1) = wrap n (bound `S.union` S.fromList xs) k b' in (CLam xs b2, k1)
            CLet x a b' -> let (a', k1) = wrap n bound k a; (b2, k2) = wrap n (S.insert x bound) k1 b' in (CLet x a' b2, k2)
            CIf c t f -> let (c', k1) = wrap n bound k c; (t', k2) = wrap n bound k1 t; (f', k3) = wrap n bound k2 f in (CIf c' t' f', k3)
            CMk a b' fs -> let (fs', k1) = wrapList n bound k fs in (CMk a b' fs', k1)
            CTagEq a b' x -> let (x', k1) = wrap n bound k x in (CTagEq a b' x', k1)
            CProj i x -> let (x', k1) = wrap n bound k x in (CProj i x', k1)
            _ -> (e, k)
        wrapList n bound k = foldl (\(acc, kk) x -> let (x', kk') = wrap n bound kk x in (acc ++ [x'], kk')) ([], k)
    -- A pure group needs a back-edge test only where every cycle passes: its
    -- members called from outside the group (in this program or, by source
    -- name, the whole program), then as few more as break every remaining
    -- cycle of the group's own call graph.  The other members keep their
    -- small bodies, so the inliner can still merge a mutual pair (vecread's
    -- sumAt/sumAt1) into one loop.  A member another unit calls that is not a
    -- boundary is reached through its original definition, which this pass
    -- leaves in place: correct, without the region.
    pureBoundaries ns = complete (S.fromList [n | n <- ns, calledFromOutside n] S.\\ joins)
      where
        group = S.fromList ns
        localGraph = M.fromList [(n, S.toList ((edges prog M.! n) `S.intersection` group)) | n <- ns]
        calledFromOutside n =
          or [S.member n refsG | (g, refsG) <- M.toList (edges prog), S.notMember g group]
            || (S.member n shared && or [S.member n refsG | (g, refsG) <- M.toList (edges context), S.notMember g group, S.member g shared])
        complete bs =
          let rest = [n | n <- ns, S.notMember n bs]
              cyclic = [c | CyclicSCC c <- stronglyConnComp [(n, n, filter (`S.notMember` bs) (localGraph M.! n)) | n <- rest]]
           in case cyclic of
                [] -> if S.null bs then S.fromList (take 1 ns) else bs
                (c : _) -> complete (S.insert (pickOf c) bs)
        pickOf c = case [n | n <- c, S.notMember n joins] of (n : _) -> n; [] -> head c
    -- loop-invariant parameter slots of a group: (function, index) classes
    -- joined by every call inside the group that passes a caller's own
    -- parameter; a class any call feeds with anything else is variable.
    invariants = Analysis.invariantParameters prog
    -- Least fixed point: a parameter only forwarded into another dead slot
    -- need not cross the boundary. All argument expressions still execute;
    -- only a read of an already-bound local is effect-free to discard.
    live = Analysis.liveParameters (M.keysSet membership) prog
    kept n = filter (`S.member` (live M.! n)) (fst (prog M.! n))
    -- Only entries that can receive BEFORE another source function in the
    -- SCC start a new turn. Other helpers, like generated joins, run inside
    -- the current turn: their temporary payloads are not persistent state.
    -- Follow private joins here because a clause fallback can contain the
    -- receive belonging to its source function.
    entries ns
      | isPure ns = pureBoundaries ns
      | otherwise = close seeds S.\\ joins
      where
        group = S.fromList ns
        graph = edges prog
        seeds = S.fromList [n | n <- ns, not (S.null ((graph M.! n) `S.intersection` (receivers S.\\ group)))]
        close known = let next = known `S.union` S.fromList
                                [n | n <- ns, not (S.null ((graph M.! n) `S.intersection` joins `S.intersection` known))]
                       in if next == known then known else close next
    transform ns
      | any (`S.member` managed) ns = Left "explicit region management; unchanged"
      | S.null boundaries = Left "no checked receive entry; unchanged"
      | not (null problems) = Left ((if isPure ns then "state is unbounded, polymorphic or lacks type evidence; unchanged ("
                                     else "state/result is mutable, functional, polymorphic or lacks type evidence; unchanged (") ++ intercalate "; " problems ++ ")"
                                     ++ (if S.null invariant then "" else "; invariant: " ++ unwords [n ++ "#" ++ show (i + 1) | (n, i) <- S.toList invariant]))
      | any (\n -> length (fst (prog M.! n)) > 64) ns = Left "requires at most 64 parameters after arity spilling; unchanged"
      | looped ns && any (\n -> length (fst (prog M.! n))+2>64) ns = Left "loop control cells exceed the physical argument convention; unchanged"
      | looped ns = do
          bodies <- mapM (\n -> let (ps,b) = prog M.! n in (,) n <$> loopE (S.fromList ps) b) ns
          pure (M.fromList (concatMap pureMake bodies))
      | otherwise = do
          bodies <- mapM (\n -> let (ps,b) = prog M.! n in (,) n <$> tailE (S.fromList ps) b) ns
          pure (M.fromList (concatMap make bodies))
      where
        group = S.fromList ns
        boundaries = entries ns
        invariant = invariants ns
        problems = concatMap (typedProblems (isPure ns) invariant) (S.toList boundaries)
        helper n = receiveName (n `S.member` boundaries) n
        mentions bound e = not . S.null $ (S.fromList (freeVars e) S.\\ bound) `S.intersection` group
        tailE bound = \case
          CLet x a b | not (mentions bound a) -> CLet x a <$> tailE (S.insert x bound) b
          CIf c t f | not (mentions bound c) -> CIf c <$> tailE bound t <*> tailE bound f
          e | (CVar n, args) <- spine e,
              n `S.member` group, n `S.notMember` bound,
              length args == length (fst (prog M.! n)),
              not (any (mentions bound) args) ->
                -- Calls are strict, left to right. Evaluate arguments BEFORE
                -- constructing the PAP; otherwise effects could be delayed
                -- until after the boundary and dead locals would be captured.
                let saved = ["$receive.arg." ++ show i | i <- [0 .. length args - 1]]
                    ps = fst (prog M.! n)
                    state = [CVar v | (p,v) <- zip ps saved, p `elem` kept n]
                    next = if n `S.notMember` boundaries
                           then foldl CApp (CVar (helper n)) (map CVar saved)
                           else CMk 4 0 [CMk 1 1 [], CApp (CVar (helper n)) (pack state)]
                 in Right (foldr (\(v,a) b -> CLet v a b) next (zip saved args))
            | not (mentions bound e) -> Right (CMk 4 0 [CMk 1 0 [], e])
            | otherwise -> Left "non-tail, partial or escaping recursive call; unchanged"
        -- A PURE loop keeps its tail calls as tail calls (the typed IR makes a
        -- self tail call a jump): each member gets an inner version with two
        -- more parameters, the pool mark and the activation's sequence
        -- number, and a tail call to a boundary member tests the mark first.
        -- Only when a slab has been allocated since does the cold branch run:
        -- $regionCycle opens the region (first time) or copies the changing
        -- arguments out and resets it, and the mark is read again.  The
        -- entry takes a sequence number and a mark; $loopLeave closes the
        -- region, if one opened, copying the result out.  Invariant arguments
        -- are passed as they are: they were built before the loop, outside
        -- every region it opens.
        inName = loopName
        loopE bound = \case
          CLet x a b | not (mentions bound a) -> CLet x a <$> loopE (S.insert x bound) b
          CIf c t f | not (mentions bound c) -> CIf c <$> loopE bound t <*> loopE bound f
          e | (CVar g, args) <- spine e,
              g `S.member` group, g `S.notMember` bound,
              length args == length (fst (prog M.! g)),
              not (any (mentions bound) args) ->
                -- a direct tail call evaluates its arguments strictly, left to
                -- right, as it did: no binding needed (the receive trampoline
                -- binds them because its call is delayed inside a closure)
                Right (foldl CApp (CVar (inName g)) (args ++ [CVar "$loop.mark", CVar "$loop.seq"]))
            | not (mentions bound e) -> Right e
            | otherwise -> Left "non-tail, partial or escaping recursive call; unchanged"
        -- the test sits at a boundary member's entry, every call to it a plain
        -- tail call: the members stay small (a mutual pair still merges into
        -- one loop), and the cold path is a function of its own
        cycName = cycleName
        pureMake (n,b) =
          let ps = fst (prog M.! n)
              extra = ["$loop.mark", "$loop.seq"]
              vars = [i | (i, p) <- zip [0 :: Int ..] ps, p `elem` kept n, not (S.member (n, i) invariant)]
              slot i = case lookup i (zip vars [0 :: Int ..]) of
                Nothing -> CVar (ps !! i)
                Just k -> if length vars == 1 then CVar "$loop.packed" else CProj k (CVar "$loop.packed")
              cycBody = CLet "$loop.packed" (CApp (CApp (CVar "$regionCycle") (CVar "$loop.seq")) (pack [CVar (ps !! i) | i <- vars]))
                          (CLet "$loop.mark2" (CApp (CVar "$regionMark") (CInt 0))
                            (foldl CApp (CVar (inName n)) ([slot i | i <- [0 .. length ps - 1]] ++ [CVar "$loop.mark2", CVar "$loop.seq"])))
              tested = CIf (CApp (CVar "$regionRoom") (CVar "$loop.mark")) b
                         (foldl CApp (CVar (cycName n)) (map CVar (ps ++ extra)))
              inner = (inName n, (ps ++ extra, if n `S.member` boundaries then tested else b))
              cycle = (cycName n, (ps ++ extra, cycBody))
              -- a receive loop opens its region at entry, so the messages
              -- it receives belong to its scope from the first turn: the
              -- loop runs on the sequence number $regionOpen returns, which
              -- keeps the call (an unused one would be dead code)
              sequence = CApp (CVar "$regionSeq") (CInt 0)
              entryE = CLet "$loop.seq.0" (if isPure ns then sequence else CApp (CVar "$regionOpen") sequence)
                         (CLet "$loop.mark.0" (CApp (CVar "$regionMark") (CInt 0))
                           (CApp (CApp (CVar "$loopLeave") (CVar "$loop.seq.0"))
                             (foldl CApp (CVar (inName n)) (map CVar ps ++ [CVar "$loop.mark.0", CVar "$loop.seq.0"]))))
           in if n `S.member` boundaries then [(n, (ps, entryE)), inner, cycle] else [inner]
        make (n,b)
          -- A generated join is ordinary control flow INSIDE this turn,
          -- never a copied continuation. This preserves the shared DAG and
          -- needs no invented ownership types for its scratch captures.
          | n `S.notMember` boundaries = [(helper n, (fst (prog M.! n), b))]
          | otherwise =
              let ps = fst (prog M.! n)
                  ks = kept n
                  thunk = CApp (CVar (helper n)) (pack (map CVar ks))
                  slots = M.fromList (zip ks [0..])
                  unpack p = case M.lookup p slots of
                    Nothing -> CInt 0 -- dead (possibly polymorphic) forwarding slot
                    Just i -> if length ks == 1 then CVar "$receive.state" else CProj i (CVar "$receive.state")
                  unpacked = foldr (\p body -> CLet p (unpack p) body) b ps
                  -- the runtime frees the thunk and, when the stub packed
                  -- two or more live parameters, the tuple it made for them
                  -- (runtime.c g_receive_loop): the count says which
               in [(n, (ps, CApp (CApp (CVar "$receiveLoop") thunk) (CInt (fromIntegral (length ks))))),
                   (helper n, (["$receive.state", "$receive.unit"], unpacked))]

    -- Only live, closed first-order values cross a turn. Unknown captures
    -- still cannot smuggle a Vector into state; generated joins stay inside
    -- the current scratch arena. Nominal declarations are checked deeply.
    -- pure: a self-tail-call boundary wants BOUNDED live parameters (the
    -- copy out of the arguments must not grow with the loop); a receive
    -- loop takes any value type.  An invariant or function-typed parameter
    -- needs no evidence: it is copied as it is, Vectors moved by the runtime.
    typedProblems pure invariant n = case M.lookup n interfaces of
      Just signature -> let ps=fst (prog M.! n)
                            as=interfaceArguments signature;r=interfaceResult signature
                            ok=if pure then boundedType else copyableType
                            handedBack=case r of
                              TV x->or [case a of TV y->x==y;_->False
                                | (i,a)<-zip [0..] as,S.member (n,i) invariant]
                              _->False
                        in if length as/=length ps then [n++": parameter arity lacks type evidence"] else
                          [n++": live parameter "++show i++" has "++show a
                            | (i,p,a)<-zip3 [1::Int ..] ps as,p `elem` kept n,not (ok a),
                              S.notMember (n,i-1) invariant,not (isFn a)]
                          ++[n++": result has "++show r | not (copyableType r || nonReturning n || handedBack)]
      Nothing->[n++": no checked physical interface"]
    isFn (TFn _ _)=True
    isFn _=False
    -- Check EVERY member, including untyped private joins: a source body
    -- ending at a join is not proof that the join itself cannot return.
    nonReturning n = Analysis.nonReturning prog (M.findWithDefault S.empty n membership)

spine :: Core -> (Core,[Core])
spine = go [] where go as (CApp f a) = go (a:as) f; go as h = (h,as)
-- A region result has one explicit declaration for every generated helper.
-- Scope/physical checks here do not claim that erased helper bodies are typed
-- Core; their checked source interfaces and runtime protocol roles stay distinct.
verifyRewrite :: Prog -> Rewrite -> Either String ()
verifyRewrite before (Rewrite after _ generated _ _ _)=do
  let bad why=Left ("region rewrite: "++why)
      newNames=M.keysSet generated
  unless (S.null (newNames `S.intersection` M.keysSet before)) (bad "generated helper collides with an input definition")
  unless (M.keysSet after==M.keysSet before<>newNames) (bad "helper declaration/emission mismatch")
  mapM_ (\(n,(ps,_))->unless (Just ps==(fst <$> M.lookup n after)) (bad ("changed physical entry: "++n))) (M.toList before)
  mapM_ (\(n,g)->unless (Just (generatedParameters g)==(fst <$> M.lookup n after))
    (bad ("generated physical interface: "++n))) (M.toList generated)
  mapM_ (\(n,(ps,_))->unless (length ps==S.size (S.fromList ps)
    && (n `M.notMember` generated || length ps<=64))
    (bad ("invalid physical parameters: "++n))) (M.toList after)
  let globals p=S.unions [S.fromList (freeVars body) S.\\ S.fromList ps | (ps,body)<-M.elems p]
      hooks=S.fromList ["$callPend","$callLeave","$loopLeave","$regionSeq","$regionOpen","$regionMark","$regionRoom","$regionCycle","$receiveLoop"]
      unknown=globals after S.\\ (globals before<>M.keysSet after<>hooks)
  unless (S.null unknown) (bad ("unbound generated references: "++unwords (S.toList unknown)))

-- State bundling keeps the step at two arguments, including its dummy Unit,
-- even for the 64-argument native convention. Arity spilling has already
-- reduced larger source calls; tuples use the same wide tags as desugaring.
pack :: [Core] -> Core
pack [] = CInt 0 -- Unit: a capture-free step still stays delayed.
pack [x] = x
pack xs = CMk (case length xs of 2 -> 4; 3 -> 5; n | n <= 8 -> n + 6; n -> tupWideBase + n) 0 xs

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing y = y
