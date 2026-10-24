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
module ReceiveTurns (receiveTurns) where

import Data.List (intercalate, foldl', isPrefixOf)
import Data.Graph (SCC (..), stronglyConnComp)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Core.Syntax
import Frontend.Syntax
import Frontend.Desugar (tupWideBase)
import Type.Syntax (Type (..), Row (..))
import Cost (primAllocates, allocGrows, CostEq)

receiveTurns :: Bool -> Bool -> M.Map Name (CostEq, CostEq) -> M.Map Name Type -> [STop] -> Prog -> S.Set Name -> Prog -> (Prog, [String])
receiveTurns loopRegions callRegionsOn contextEqs types tops context joins prog = (final, notes ++ callNotes)
  where
    refs ps = S.fromList . filter (`notElem` ps) . freeVars
    edges p = M.map (uncurry refs) p
    reaches graph seeds = fix seeds
      where fix known = let next = known `S.union` M.keysSet (M.filter (not . S.null . S.intersection known) graph)
                         in if next == known then known else fix next
    -- Lifted helper names are local to a compilation, and their counters can
    -- coincide in the whole-program and per-unit Core. Only SOURCE names may
    -- cross that boundary; follow local helper edges in the local graph.
    effect names =
      let seeds = S.fromList names
          external = reaches (edges context) seeds `S.intersection` M.keysSet types
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
    membership = M.fromList [(n,S.fromList ns) | ns <- groups, n <- ns]
    results = map transform groups
    rewritten = M.unions [p | (ns, Right p) <- zip groups results, loopRegions || not (isPure ns)]
    -- a declined pure group is noise in a --cost report (every list helper in
    -- the closure is one): those lines carry a "(declined)" tag the driver
    -- prints only under FPR_RECEIVE_NOTES, with a count under --cost
    notes = [(if isPure ns then (if isLeft r then "turn-regions (declined): " else if loopRegions then "turn-regions: " else "turn-regions (candidate): ") else "receive-turns: ") ++ unwords ns ++ ": "
              ++ either id (const (if isPure ns then (if loopRegions then "loop region at the self tail call (opens after a slab, resets per slab)" else "loop region not placed (FPR_NO_LOOP_REGIONS=1)") else "automatic value-state turn regions")) r
            | (ns,r) <- zip groups results]
    turned = M.union rewritten prog
    -- the loops that got a region: a call into one needs no call region
    loopEntries = S.fromList (concat [ns | (ns, Right _) <- zip groups results, isPure ns, loopRegions])
    (final, callNotes) = if callRegionsOn then callRegions turned else (turned, [])
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
            else case primAllocates g (length as) of
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
    costly g arity = case (M.lookup g prog `orElse` M.lookup g context, M.lookup g types, M.lookup g callEqs) of
      (Just (ps, _), Just ty, Just (_, eq)) | length ps == arity, take 1 g /= "$" ->
        let (as, r) = split arity ty
         in length as == arity && value S.empty r && allocGrows growingOmega eq && S.notMember g loopEntries
      _ -> False
    callRegions p = (M.mapWithKey site p, [ "call-regions: " ++ n ++ ": " ++ show k ++ " call(s) under a pending region"
                                          | (n, k) <- M.toList counts, k > 0 ])
      where
        -- every function, the loop bodies included: a costly call inside a loop
        -- is where a region pays most (dtree's `run` inside repeatRuns); the
        -- loop's own boundary only reclaims per slab of its iteration.  Not the
        -- compiler's own `$` helpers, whose calls are the region bookkeeping.
        eligible n = (take 1 n /= "$" || "$loop.in." `isPrefixOf` n) && M.member n prog
        rewritten' = M.mapWithKey (\n (ps, b) -> if eligible n then let (b', k) = wrap n (S.fromList ps) 0 b in ((ps, b'), k) else ((ps, b), 0)) p
        site n _ = fst (rewritten' M.! n)
        counts = M.map snd rewritten'
        sameGroup a b = case (M.lookup a sccIx, M.lookup b sccIx) of (Just x, Just y) -> x == y; _ -> False
        -- wrap: (expression, sites so far) -> (expression', sites)
        wrap n bound k e = case spine e of
          (CVar g, as@(_ : _)) | S.notMember g bound, not (sameGroup n g), costly g (length as) ->
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
            || (M.member n types && or [S.member n refsG | (g, refsG) <- M.toList (edges context), S.notMember g group, M.member g types])
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
    invariants ns = S.fromList [slot | slot <- M.keys cls, S.member (rep slot) good]
      where
        group = S.fromList ns
        -- a call's arguments, each resolved to the caller's parameter slot it
        -- is (through the `let x = param` aliases Core binds the surface names
        -- with), a global (a constant), or something else (variable)
        calls = concat [callsIn n (M.fromList (zip ps [0 ..])) b | n <- ns, let (ps, b) = prog M.! n]
        callsIn n alias e = case spine e of
          (CVar g, as) | S.member g group, not (M.member g alias), length as == length (fst (prog M.! g)) ->
            [(g, map (argKind alias) as)] ++ concatMap (callsIn n alias) as
          _ -> case e of
            CLet x a b' -> callsIn n alias a ++ callsIn n (case a of
                             CVar y | Just j <- M.lookup y alias -> M.insert x j alias
                             _ -> M.delete x alias) b'
            CIf c t f -> concatMap (callsIn n alias) [c, t, f]
            CApp a b' -> callsIn n alias a ++ callsIn n alias b'
            CLam xs b' -> callsIn n (foldr M.delete alias xs) b'
            CMk _ _ fs -> concatMap (callsIn n alias) fs
            CTagEq _ _ x -> callsIn n alias x
            CProj _ x -> callsIn n alias x
            _ -> []
          where
            argKind al a = case a of
              CVar x | Just j <- M.lookup x al -> Just (Just (n, j))
                     | M.member x prog -> Just Nothing -- a global: a constant
              _ -> Nothing
        slots = [(n, i) | n <- ns, i <- [0 .. length (fst (prog M.! n)) - 1]]
        -- union-find by a parent map, small groups: repeated path compression
        -- is not worth the code
        cls0 = M.fromList [(sl, sl) | sl <- slots]
        (cls, variable) = foldl' step (cls0, S.empty) calls
        step (c, var) (g, kinds) = foldl' one (c, var) (zip [0 ..] kinds)
          where
            one (c', v') (i, k) = case k of
              Just (Just slot) -> (union c' (g, i) slot, v')
              Just Nothing -> (c', v')
              Nothing -> (c', S.insert (g, i) v')
        find c sl = let p = c M.! sl in if p == sl then sl else find c p
        union c a b = let ra = find c a; rb = find c b in if ra == rb then c else M.insert ra rb c
        rep = find cls
        variableReps = S.fromList (map rep (S.toList variable))
        good = S.fromList [rep sl | sl <- slots] S.\\ variableReps
    -- Least fixed point: a parameter only forwarded into another dead slot
    -- need not cross the boundary. All argument expressions still execute;
    -- only a read of an already-bound local is effect-free to discard.
    live = settle (M.map (const S.empty) prog)
      where
        settle known =
          let next = M.mapWithKey (\n (ps,b) -> S.fromList ps `S.intersection` needed known (S.fromList ps) b) prog
           in if next == known then known else settle next
        needed known bound e
          | (CVar n,as) <- spine e, M.member n membership,
            n `S.notMember` bound, length as == length (fst (prog M.! n)) =
              S.unions [if p `S.notMember` (known M.! n) && local bound a
                        then S.empty else needed known bound a
                       | (p,a) <- zip (fst (prog M.! n)) as]
          | otherwise = case e of
              CLet x a b ->
                let rest = needed known (S.insert x bound) b
                    rhs = if x `S.notMember` rest && local bound a then S.empty else needed known bound a
                 in rhs `S.union` S.delete x rest
              CIf c t f -> S.unions (map (needed known bound) [c,t,f])
              CApp f a -> needed known bound f `S.union` needed known bound a
              CMk _ _ fs -> S.unions (map (needed known bound) fs)
              CTagEq _ _ x -> needed known bound x
              CProj _ x -> needed known bound x
              _ -> S.fromList (freeVars e)
        local bound (CVar v) = v `S.member` bound
        local _ _ = False
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
      | isPure ns = do
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
        helper n = (if n `S.member` boundaries then "$receive.turn." else "$receive.local.") ++ n
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
        inName n = "$loop.in." ++ n
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
        cycName n = "$loop.cycle." ++ n
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
              entryE = CLet "$loop.seq.0" (CApp (CVar "$regionSeq") (CInt 0))
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
    typedProblems pure invariant n = case M.lookup n types of
      Just ty -> let ps = fst (prog M.! n)
                     (as,r) = split (length ps) ty
                     ok = if pure then bounded S.empty else value S.empty
                     -- a result that is one of the invariant parameters' own
                     -- (polymorphic) types is the caller's value handed back:
                     -- it needs no more evidence than the parameter did
                     handedBack = case r of
                       TV x -> or [case a of TV y -> x == y; _ -> False
                                  | (i, a) <- zip [0 ..] as, S.member (n, i) invariant]
                       _ -> False
                  in if length as /= length ps then [n ++ ": parameter arity lacks type evidence"] else
                     [n ++ ": live parameter " ++ show i ++ " has " ++ show a
                      | (i,p,a) <- zip3 [1::Int ..] ps as, p `elem` kept n, not (ok a),
                        not (S.member (n, i - 1) invariant), not (isFn a)]
                     ++ [n ++ ": result has " ++ show r
                        | not (value S.empty r || nonReturning n || handedBack)]
      Nothing -> [n ++ ": no checked source interface"]
    isFn t = case t of TFn _ _ -> True; _ -> False
    -- bounded: a value whose size does not depend on the loop: scalars,
    -- handles, Vectors (moved by handle), and products of those; a List,
    -- String or Result of unbounded parts may grow as the loop runs
    bounded seen = \case
      TTupT ts -> all (bounded seen) ts
      TRec r -> boundedRow seen r
      t -> case tySpine t of
        (TC n,as)
          | n `elem` ["Int","Bool","Unit","Atom","I64","Word","F64","I32"] -> null as
          | n == "Vector" -> length as == 1
          | n == "Result" -> length as == 2 && all (bounded seen) as
          | Just fs <- M.lookup n shapes, null as, n `S.notMember` seen ->
              all (fieldB (S.insert n seen) M.empty . snd) fs
          | Just (vs,fields) <- M.lookup n decls,
            length vs == length as, all (bounded seen) as ->
              -- a recursive nominal (a Tree) is a value but not bounded: its
              -- size is the data's, and copying it every iteration would grow
              -- with the loop
              n `S.notMember` seen && all (fieldB (S.insert n seen) (M.fromList (zip vs as))) fields
        _ -> False
    boundedRow seen = \case
      RNil -> True
      RExt _ t r -> bounded seen t && boundedRow seen r
      _ -> False
    fieldB seen subst = \case
      TVarT n -> maybe False (bounded seen) (M.lookup n subst)
      TCon n ts -> maybe False (bounded seen) (convert subst (TCon n ts))
      TTup ts -> all (fieldB seen subst) ts
      TRecT fs Nothing -> all (fieldB seen subst . snd) fs
      _ -> False
    -- Check EVERY member, including untyped private joins: a source body
    -- ending at a join is not proof that the join itself cannot return.
    nonReturning n = let group = M.findWithDefault S.empty n membership
                      in all (\g -> let (ps,b) = prog M.! g in neverReturns group (S.fromList ps) b) (S.toList group)
    -- An infinite actor needs no copyable result when every terminal path
    -- in its SCC is another saturated SCC call or a compiler trap.
    neverReturns group bound = \case
      CLet x _ b -> neverReturns group (S.insert x bound) b
      CIf _ t f -> neverReturns group bound t && neverReturns group bound f
      CErr _ -> True
      e -> case spine e of
        (CVar g,as) -> g `S.member` group && g `S.notMember` bound && length as == length (fst (prog M.! g))
        _ -> False
    split 0 t = ([],t)
    split k (TFn a b) = let (as,r) = split (k-1) b in (a:as,r)
    split _ t = ([],t)
    decls = M.fromList [(n,(vs,concatMap snd cs)) | TType n False vs cs <- tops]
    shapes = M.fromList [(n,fs) | TShape n fs <- tops]
    value seen = \case
      TTupT ts -> all (value seen) ts
      TRec r -> row seen r
      t -> case tySpine t of
        (TC n,as)
          | n `elem` ["Int","String","Bool","Unit","Atom","I64","Word","F64","I32"] -> null as
          | n == "Vector" -> length as == 1 -- moved by handle when owned here, copied otherwise (runtime.c)
          | n `elem` ["List","Result"] -> length as == (if n == "List" then 1 else 2) && all (value seen) as
          | Just fs <- M.lookup n shapes, null as, n `S.notMember` seen ->
              all (field (S.insert n seen) M.empty . snd) fs
          | Just (vs,fields) <- M.lookup n decls,
            length vs == length as, all (value seen) as ->
              n `S.member` seen || all (field (S.insert n seen) (M.fromList (zip vs as))) fields
        _ -> False
    row seen = \case
      RNil -> True
      RExt _ t r -> value seen t && row seen r
      _ -> False
    field seen subst = \case
      TVarT n -> maybe False (value seen) (M.lookup n subst)
      TCon n ts -> maybe False (value seen) (convert subst (TCon n ts))
      TTup ts -> all (field seen subst) ts
      TRecT fs Nothing -> all (field seen subst . snd) fs
      _ -> False
    convert subst = \case
      TVarT n -> M.lookup n subst
      TCon n ts -> foldl TAp (TC n) <$> mapM (convert subst) ts
      TTup ts -> TTupT <$> mapM (convert subst) ts
      _ -> Nothing

spine :: Core -> (Core,[Core])
spine = go [] where go as (CApp f a) = go (a:as) f; go as h = (h,as)
tySpine :: Type -> (Type,[Type])
tySpine = go [] where go as (TAp f a) = go (a:as) f; go as h = (h,as)

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
