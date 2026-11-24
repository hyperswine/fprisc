{-# LANGUAGE LambdaCase, TupleSections #-}
-- Codegen.RawInts: raw machine words for the Ints of a loop, by versioning
-- (docs/2026-11-22-RAW-INTS.md; v1.0 core spec §1.2: raw words only for
-- locals proven small).
--
-- Exact Int lowers every + - * / and ordering to OArithVal / OCmpVal on
-- tagged words, with a bignum slow path; a running value is retagged at
-- every step because that path may have made a bignum. Here a loop's region
-- (its header and every block the header dominates) is copied once. In the
-- copy the Int values the loop computes with are raw TInt words:
--
--  * a value tagged from a raw Int is that Int;
--  * + - * of two raw values is `OArithFits` then `OArithU`: the fit test
--    branches away when the exact result leaves the small range, and
--    Codegen.Interval removes the test where the operands' bounds prove
--    the result fits (the old no-overflow proof, which sees TInt again);
--  * any other Int the copy uses (a division, a call's answer, a load, an
--    operation on a value not known small) is computed as before and tested
--    with `OIsInt`, then untagged;
--  * comparisons and equality of two raw values are OCmp on the words;
--  * a header parameter or a value from outside the region is tested once,
--    on the way in; any failure enters the original loop instead.
--
-- A failed test leaves the copy in the middle of an iteration. Each test
-- point splits the original block right after the same instruction, and
-- the exit jumps there with every live value retagged (the failing
-- operation's exact result computed on the generic path), so the original
-- loop carries on from that point: exact semantics, only slower. The
-- original blocks a split point reaches without passing the header take
-- their live values as block parameters, so SSA dominance holds on the
-- new edges.
--
-- Soundness rests on one rule: a value is raw in the copy only when it is
-- an Int that is small at run time. A tag of a TInt is (TInt values are
-- small); a fit-tested or tag-tested result is; a parameter is when every
-- edge into it passes a raw value (induction around the loop). Which TVal
-- values are Ints is inferred from their uses; a wrong guess fails a
-- tag test and runs the original loop, never a wrong answer.
module Codegen.RawInts (versionRawInts) where

import Codegen.ControlFlow
import Codegen.IR
import Control.Monad (forM, forM_, replicateM, unless, zipWithM)
import Control.Monad.State.Strict
import Data.Containers.ListUtils (nubOrd)
import Data.List (foldl')
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- a region larger than this is not copied (the copy and the split
-- original together are a little over twice its size)
regionLimit :: Int
regionLimit = 1200

versionRawInts :: Fn -> Fn
versionRawInts fn0
  | not (any exact [op | b <- fnBlocks fn0, Instr _ op <- bInstrs b]) = fn0
  | otherwise =
      let fn = fromMaybe fn0 (loopEntry fn0)
          out = versionTops fn
       in if out == fn then fn0 else out
  where
    exact = \case OArithVal {} -> True; OCmpVal {} -> True; OBitVal {} -> True; _ -> False

-- A self tail call jumps to the entry block, which has no way in to guard.
-- Such a loop gets a new entry that only checks the stack and jumps to the
-- old one, now a plain header (its safepoint still ticks every iteration;
-- the stack does not grow around a loop). Kept only when a copy is made.
loopEntry :: Fn -> Maybe Fn
loopEntry fn = case [b | b <- fnBlocks fn, bId b == fnEntry fn] of
  [e] | any (\b -> fnEntry fn `elem` map fst (termSuccs (bTerm b))) (fnBlocks fn) ->
    let (checks, rest) = span (\case Instr Nothing OStackCheck -> True; _ -> False) (bInstrs e)
        nextV = 1 + maximum (0 : [n | b <- fnBlocks fn, (VId n, _) <- blockDefs b])
        newId = BId (1 + maximum (0 : [n | b <- fnBlocks fn, BId n <- [bId b]]))
        ps = [(VId (nextV + i), t) | (i, (_, t)) <- zip [0 ..] (bParams e)]
        entry = Block newId ps checks (TBr (bId e) (map fst ps))
     in Just fn {fnEntry = newId, fnBlocks = entry : e {bInstrs = rest} : [b | b <- fnBlocks fn, bId b /= bId e]}
  _ -> Nothing

versionTops :: Fn -> Fn
versionTops fn = foldl' (\f h -> fromMaybe f (versionAt f h)) fn tops
  where
    flow = analyze fn
    doms = dominators flow
    headers = [loopHeader l | l <- naturalLoops fn flow, loopHeader l /= fnEntry fn]
    dominates a b = S.member a (M.findWithDefault S.empty b doms)
    -- the outermost loops: their regions are disjoint, and an inner loop
    -- is copied with its outer loop's region
    tops = nubOrd [h | h <- headers, not (any (\g -> g /= h && dominates g h) headers)]

-- how the copy holds an original value
data Rep = Same VId | Raw VId | Both VId VId -- raw word, and its tagged word

data St = St
  { stV :: !Int,
    stB :: !Int,
    stCv :: M.Map VId Rep,
    stTags :: M.Map VId VId, -- tags made in the current original block
    stCur :: BId,
    stParams :: [(VId, Ty)],
    stAcc :: [Instr],
    stOut :: [Block]
  }

type Build = State St

freshV :: Build VId
freshV = state (\s -> (VId (stV s), s {stV = stV s + 1}))

freshB :: Build BId
freshB = state (\s -> (BId (stB s), s {stB = stB s + 1}))

emit :: Ty -> Op -> Build VId
emit t op = do
  v <- freshV
  modify (\s -> s {stAcc = Instr (Just (v, t)) op : stAcc s})
  pure v

emitBare :: Op -> Build ()
emitBare op = modify (\s -> s {stAcc = Instr Nothing op : stAcc s})

openBlock :: BId -> [(VId, Ty)] -> Build ()
openBlock b ps = modify (\s -> s {stCur = b, stParams = ps, stAcc = []})

closeBlock :: Term -> Build ()
closeBlock t = modify (\s -> s {stOut = Block (stCur s) (stParams s) (reverse (stAcc s)) t : stOut s})

setCv :: VId -> Rep -> Build ()
setCv v r = modify (\s -> s {stCv = M.insert v r (stCv s)})

-- the values a block needs on entry (of `tracked`), given what it must
-- leave live; `from` skips the instructions before that index
liveFrom :: S.Set VId -> Block -> Int -> S.Set VId -> S.Set VId
liveFrom tracked b from out = foldr step (S.union out (track (termUses (bTerm b)))) (drop from (bInstrs b))
  where
    step (Instr d op) live = S.union (maybe live (\(v, _) -> S.delete v live) d) (track (opUses op))
    track = S.fromList . filter (`S.member` tracked)

liveIns :: S.Set VId -> [Block] -> M.Map BId (S.Set VId)
liveIns tracked blocks = go (M.fromList [(bId b, S.empty) | b <- blocks])
  where
    go m =
      let m' = foldr (\b acc -> M.insert (bId b) (inOf acc b) acc) m blocks
       in if m' == m then m else go m'
    inOf m b = S.difference (liveFrom tracked b 0 (outOf m b)) (S.fromList (map fst (bParams b)))
    outOf m b = S.unions [M.findWithDefault S.empty t m | (t, _) <- termSuccs (bTerm b)]

versionAt :: Fn -> BId -> Maybe Fn
versionAt fn h
  | h == fnEntry fn || M.notMember h byId = Nothing
  | regionSize > regionLimit = Nothing
  | null outsideEdges = Nothing
  | not gain = Nothing
  | otherwise = Just (evalState build (St nextV nextB M.empty M.empty h [] [] []))
  where
    flow = analyze fn
    doms = dominators flow
    live = reachable flow
    dom a b = S.member a (M.findWithDefault S.empty b doms)
    byId = M.fromList [(bId b, b) | b <- fnBlocks fn]
    hBlock = byId M.! h
    region = S.fromList [bId b | b <- fnBlocks fn, S.member (bId b) live, dom h (bId b)]
    inRegion b = S.member b region
    regionBlocks = [b | b <- fnBlocks fn, inRegion (bId b)]
    regionSize = sum [length (bInstrs b) + 1 | b <- regionBlocks]
    defBlock = M.fromList [(v, bId b) | b <- fnBlocks fn, (v, _) <- blockDefs b]
    defTy = M.fromList [(v, t) | b <- fnBlocks fn, (v, t) <- blockDefs b]
    defOp = M.fromList [(v, op) | b <- fnBlocks fn, Instr (Just (v, _)) op <- bInstrs b]
    tyOf v = M.findWithDefault TVal v defTy
    inR v = maybe False inRegion (M.lookup v defBlock)
    outsideEdges = [() | b <- fnBlocks fn, S.member (bId b) live, not (inRegion (bId b)), (t, _) <- termSuccs (bTerm b), t == h]
    nextV = 1 + maximum (0 : [n | b <- fnBlocks fn, (VId n, _) <- blockDefs b])
    nextB = 1 + maximum (0 : [n | BId n <- M.keys byId])

    -- every edge's arguments, by the parameter they bind
    argsOf = M.fromListWith (++)
      [ (p, [(bId b, a)])
      | b <- fnBlocks fn, S.member (bId b) live, (t, as) <- termSuccs (bTerm b)
      , Just tb <- [M.lookup t byId], ((p, _), a) <- zip (bParams tb) as ]
    paramBlock = M.fromList [(p, bId b) | b <- fnBlocks fn, (p, _) <- bParams b]

    -- Which tagged words are Ints: the operands and results of the exact
    -- operations, tags of raw Ints, untagged words, and what flows into or
    -- out of a parameter with them or is compared equal to one.
    intVals = grow S.empty (S.toList seeds)
      where
        seeds = S.fromList (concat [intSeeds d op | b <- fnBlocks fn, Instr d op <- bInstrs b])
        intSeeds d op = case op of
          OArithVal _ a b -> a : b : res d
          OBitVal _ a b -> a : b : res d
          OCmpVal _ a b -> [a, b]
          OUntag a -> [a]
          OTag _ -> res d
          _ -> []
        res (Just (v, TVal)) = [v]
        res _ = []
        pairs = [(a, b) | blk <- fnBlocks fn, Instr _ (OEqVal _ a b) <- bInstrs blk]
          ++ [(p, a) | (p, as) <- M.toList argsOf, tyOf p == TVal, (_, a) <- as, tyOf a == TVal]
        links = M.fromListWith (++) (concat [[(a, [b]), (b, [a])] | (a, b) <- pairs])
        grow seen [] = seen
        grow seen (x : xs)
          | S.member x seen = grow seen xs
          | otherwise = grow (S.insert x seen) (M.findWithDefault [] x links ++ xs)
    isInt v = tyOf v == TVal && S.member v intVals

    -- the Ints the region computes with, and everything flowing into them
    -- around the region (a header parameter's entry value is tested as the
    -- parameter, so that edge is not followed)
    intUses = \case
      OArithVal _ a b -> [a, b]
      OBitVal _ a b -> [a, b]
      OCmpVal _ a b -> [a, b]
      OUntag a -> [a]
      OEqVal _ a b | isInt a || isInt b -> [a, b]
      _ -> []
    wanted = grow S.empty [u | b <- regionBlocks, Instr _ op <- bInstrs b, u <- intUses op, tyOf u == TVal]
      where
        grow seen [] = seen
        grow seen (x : xs)
          | S.member x seen = grow seen xs
          | otherwise = grow (S.insert x seen) (more x ++ xs)
        more x = case M.lookup x paramBlock of
          Just pb | inRegion pb -> [a | (src, a) <- M.findWithDefault [] x argsOf, inRegion src, tyOf a == TVal]
          _ -> []
    taggedResults = S.fromList
      [v | b <- regionBlocks, Instr (Just (v, TVal)) op <- bInstrs b, case op of OArithVal {} -> True; OBitVal {} -> True; OTag {} -> True; _ -> False]
    -- a product's results are one packet: no test may split it
    testable v = not (inR v) || case M.lookup v defOp of
      Just (OCallProduct {}) -> False
      Just (OResult {}) -> False
      _ -> True
    candidates = S.union (S.filter testable wanted) taggedResults

    -- where each tested value's test splits its block
    positions = M.fromList
      [ (v, (b, k))
      | b <- regionBlocks, (k, Instr (Just (v, TVal)) op) <- zip [0 ..] (bInstrs b)
      , case op of OTag {} -> False; _ -> True ]
    regionDefs = S.fromList [v | b <- regionBlocks, (v, _) <- blockDefs b]
    liveIn0 = liveIns regionDefs regionBlocks
    liveAfter b k = liveFrom regionDefs b (k + 1)
      (S.unions [M.findWithDefault S.empty t liveIn0 | (t, _) <- termSuccs (bTerm b)])
    -- a split carries the live values as parameters: tagged and raw words
    -- only (no predicate or derived address crosses a new edge)
    splittable b k = all (\x -> tyOf x `elem` [TVal, TInt]) (S.toList (liveAfter b k))
    keep s v
      | Just pb <- M.lookup v paramBlock, inRegion pb =
          all (\(src, a) -> not (inRegion src) || S.member a s) (M.findWithDefault [] v argsOf)
      | Just (b, k) <- M.lookup v positions = splittable b k
      | otherwise = True
    rawSet = settle candidates
      where settle s = let s' = S.filter (keep s) s in if s' == s then s else settle s'
    raw v = S.member v rawSet
    guardedOutside = [v | v <- S.toList rawSet, not (inR v)]
    -- worth a copy: some exact operation sees two operands that are raw
    -- without a tag test of their own: tags of raw words (a counter, an
    -- index, a column of raw Ints), parameters and values tested once on the
    -- way in, and results computed from those. A loop whose Ints only come
    -- and go through tagged memory (read a field, add, store) runs as fast
    -- on tagged words, and its copy would only cost code
    gain = pairGain || accumulates
    pairGain = or
      [ cheap a && cheap b
      | b' <- regionBlocks, Instr _ op <- bInstrs b'
      , (a, b) <- case op of
          OArithVal _ x y -> [(x, y)]
          OBitVal _ x y -> [(x, y)]
          OCmpVal _ x y -> [(x, y)]
          OEqVal _ x y -> [(x, y)]
          _ -> [] ]

    -- also worth a copy: an accumulator, a + - * whose result goes around
    -- the loop into a raw header parameter with one cheap operand (that
    -- parameter, a counter, an invariant). The other operand may be tested
    -- on the way (a list element, a field): the running value stays raw
    -- from one iteration to the next instead of being untagged, retagged
    -- and tag-tested at every step. This is std List.fold's monomorphised
    -- worker (`a + x * k`, `a + x`, `a * x` over list cells), which has no
    -- operation with two cheap operands and ran tagged
    -- (docs/2026-11-22-RAW-INTS.md, "Accumulators")
    accumulates = or
      [ cheap a || cheap c
      | b' <- regionBlocks, Instr (Just (v, _)) (OArithVal o a c) <- bInstrs b'
      , o `elem` [Add, Sub, Mul], raw v, raw a, raw c, S.member v carried ]
    -- what reaches a raw header parameter around the loop, through the raw
    -- parameters of the region's join blocks on the way
    carried = grow S.empty [p | (p, _) <- bParams hBlock, raw p]
      where
        grow seen [] = seen
        grow seen (x : xs)
          | S.member x seen = grow seen xs
          | otherwise = grow (S.insert x seen) (more x ++ xs)
        more x = case M.lookup x paramBlock of
          Just pb | inRegion pb, raw x -> [a | (src, a) <- M.findWithDefault [] x argsOf, inRegion src]
          _ -> []

    cheapSet = grow (S.filter (\v -> raw v && seed v) rawSet)
      where
        seed v = case M.lookup v defOp of
          Nothing -> True -- a parameter, or a value tested on the way in
          Just (OTag _) -> True
          _ -> False
        grow c =
          let c' = S.union c (S.fromList [v | v <- S.toList rawSet, Just (a, b) <- [case M.lookup v defOp of Just (OArithVal _ x y) -> Just (x, y); Just (OBitVal _ x y) -> Just (x, y); _ -> Nothing], S.member a c, S.member b c])
           in if c' == c then c else grow c'
    cheap v = S.member v cheapSet

    checks = M.fromList
      [ (bId b, [k | (k, Instr (Just (v, _)) op) <- zip [0 ..] (bInstrs b), raw v, case op of OTag {} -> False; _ -> True])
      | b <- regionBlocks ]

    build :: Build Fn
    build = do
      -- 1. the original region, split after every test point
      splits <- forM regionBlocks $ \b -> do
        let ks = M.findWithDefault [] (bId b) checks
        ids <- replicateM (length ks) freshB
        let chunks = cut 0 ks (bInstrs b)
            segIds = bId b : ids
            terms = [TBr i [] | i <- ids] ++ [bTerm b]
            segs = [Block i (if i == bId b then bParams b else []) is t | (i, is, t) <- zip3 segIds chunks terms]
        pure (bId b, segs, M.fromList [((bId b, k), i) | (k, i) <- zip ks ids])
      let contOf = M.unions [m | (_, _, m) <- splits]
          generic0 = concat [segs | (_, segs, _) <- splits]
          genericIds = S.fromList (map bId generic0)
          genById = M.fromList [(bId b, b) | b <- generic0]
          conts = M.elems contOf
          -- reached from a split point without passing the header
          rc = reach S.empty conts
          reach seen [] = seen
          reach seen (x : xs)
            | S.member x seen || x == h || S.notMember x genericIds = reach seen xs
            | otherwise = reach (S.insert x seen) (maybe [] (map fst . termSuccs . bTerm) (M.lookup x genById) ++ xs)
          liveG = liveIns regionDefs generic0
          extra x = S.toList (M.findWithDefault S.empty x liveG)
      -- 2. those blocks take their live values as parameters
      hats <- fmap M.fromList $ forM [(x, v) | x <- S.toList rc, v <- extra x] $ \k -> (k,) <$> freshV
      let hat x v = hats M.! (x, v)
          nameAt y v = if S.member y rc && S.member v (M.findWithDefault S.empty y liveG) then hat y v else v
          formed b =
            let y = bId b
                ren v = if S.member y rc && M.member (y, v) hats then hat y v else v
                params = bParams b ++ (if S.member y rc then [(hat y v, tyOf v) | v <- extra y] else [])
                instrs = [Instr d (mapOpUses ren op) | Instr d op <- bInstrs b]
                add t as = if S.member t rc then as ++ map (nameAt y) (extra t) else as
                term = case mapTermUses ren (bTerm b) of
                  TBr t as -> TBr t (add t as)
                  TCondBr c t as e bs -> TCondBr c t (add t as) e (add e bs)
                  other -> other
             in Block y params instrs term
          generic = map formed generic0

      -- 3. the way in: outside edges enter a test chain; any failure enters
      -- the original header with the same values
      g0 <- freshB
      fallback <- freshB
      hhat <- forM (bParams hBlock) (\(_, t) -> (,t) <$> freshV)
      rawIds <- M.fromList <$> forM regionBlocks (\b -> (bId b,) <$> freshB)
      openBlock g0 hhat
      let tests = [ph | ((p, _), (ph, _)) <- zip (bParams hBlock) hhat, raw p] ++ guardedOutside
      forM_ tests $ \g -> do
        p <- emit TPred (OIsInt g)
        nxt <- freshB
        closeBlock (TCondBr p nxt [] fallback [])
        openBlock nxt []
      forM_ guardedOutside $ \u -> do
        r <- emit TInt (OUntag u)
        setCv u (Both r u)
      hargs <- forM (zip (bParams hBlock) hhat) $ \((p, _), (ph, _)) ->
        if raw p then emit TInt (OUntag ph) else pure ph
      closeBlock (TBr (rawIds M.! h) hargs)
      unless (null tests) $ do
        openBlock fallback []
        closeBlock (TBr h (map fst hhat))

      -- 4. the copy, dominators first
      forM_ rpo $ \b -> do
        ps <- forM (bParams b) $ \(p, t) -> do
          p' <- freshV
          if raw p then setCv p (Raw p') >> pure (p', TInt) else setCv p (Same p') >> pure (p', t)
        openBlock (rawIds M.! bId b) ps
        modify (\s -> s {stTags = M.empty})
        forM_ (zip [0 ..] (bInstrs b)) (copyInstr contOf extra b)
        t' <- copyTerm rawIds (bTerm b)
        closeBlock t'

      out <- gets stOut
      let segParent = M.fromList [(bId sg, o) | (o, segs, _) <- splits, sg <- segs]
          segOf g = M.findWithDefault (bId g) (bId g) segParent
          originalOrder = concatMap (\b -> if inRegion (bId b) then [g | g <- generic, segOf g == bId b] else [retarget g0 b]) (fnBlocks fn)
      -- with nothing to test on the way in, the original loop is reached
      -- only from the copy's exits, perhaps not at all
      let whole = fn {fnBlocks = originalOrder ++ reverse out}
          reached = reachable (analyze whole)
      pure whole {fnBlocks = [b | b <- fnBlocks whole, S.member (bId b) reached]}

    retarget g0 b = b {bTerm = case bTerm b of
      TBr t as | t == h -> TBr g0 as
      TCondBr c t as e bs -> TCondBr c (if t == h then g0 else t) as (if e == h then g0 else e) bs
      other -> other}

    -- the region's blocks in reverse postorder from the header
    rpo = map (byId M.!) (snd (visit (S.empty, []) h))
      where
        visit (seen, acc) b
          | S.member b seen || not (inRegion b) = (seen, acc)
          | otherwise =
              let (seen', acc') = foldl' visit (S.insert b seen, acc) (map fst (termSuccs (bTerm (byId M.! b))))
               in (seen', b : acc')

    cut _ [] is = [is]
    cut from (k : ks) is = let (a, b) = splitAt (k + 1 - from) is in a : cut (k + 1) ks b

    rawOf :: VId -> Build VId
    rawOf v = gets (M.lookup v . stCv) >>= \case
      Just (Raw r) -> pure r
      Just (Both r _) -> pure r
      _ -> error ("Codegen.RawInts: no raw word for " ++ show v)

    -- the tagged word of an original TVal value, tagging a raw one once per block
    valOf :: VId -> Build VId
    valOf v = gets (M.lookup v . stCv) >>= \case
      Nothing -> pure v
      Just (Same x) -> pure x
      Just (Both _ t) -> pure t
      Just (Raw r) -> gets (M.lookup v . stTags) >>= \case
        Just t -> pure t
        Nothing -> do
          t <- emit TVal (OTag r)
          modify (\s -> s {stTags = M.insert v t (stTags s)})
          pure t

    sameOf :: VId -> Build VId
    sameOf v = gets (M.lookup v . stCv) >>= \case
      Just (Same x) -> pure x
      Just (Raw r) -> pure r
      Just (Both r _) -> pure r
      Nothing -> pure v

    useOf v = if tyOf v == TVal then valOf v else sameOf v

    mapOpM op = do
      let us = nubOrd (opUses op)
      vs <- mapM useOf us
      let m = M.fromList (zip us vs)
      pure (mapOpUses (\u -> M.findWithDefault u u m) op)

    -- branch on p: on true carry on in a new block, on false run `exit`
    -- in a block of its own (tags it makes stay there)
    checkThen p exit = do
      next <- freshB
      ex <- freshB
      closeBlock (TCondBr p next [] ex [])
      saved <- gets stTags
      openBlock ex []
      exit
      openBlock next []
      modify (\s -> s {stTags = saved})

    -- leave the copy for the original block's split point after
    -- instruction k, with v's exact value g and every live value tagged
    exitTo contOf extra b k v g = do
      let c = contOf M.! (bId b, k)
      args <- forM (extra c) $ \x -> if x == v then pure g else useOf x
      closeBlock (TBr c args)

    copyInstr contOf extra b (k, Instr d op) = case d of
      Nothing -> mapOpM op >>= emitBare
      Just (v, t) -> case op of
        OTag x | raw v -> sameOf x >>= setCv v . Raw
        OUntag a | raw a -> rawOf a >>= setCv v . Same
        OArithVal o a c | raw v, raw a, raw c, o `elem` [Add, Sub, Mul] -> do
          ra <- rawOf a
          rc' <- rawOf c
          p <- emit TPred (OArithFits o ra rc')
          checkThen p $ do
            ta <- valOf a
            tc <- valOf c
            g <- emit TVal (OArithVal o ta tc)
            exitTo contOf extra b k v g
          r <- emit TInt (OArithU o ra rc')
          setCv v (Raw r)
        OBitVal o a c | raw v, raw a, raw c -> do
          ra <- rawOf a
          rc' <- rawOf c
          r <- emit TInt (OBit o ra rc')
          setCv v (Raw r)
        OCmpVal o a c | raw a, raw c -> do
          ra <- rawOf a
          rc' <- rawOf c
          emit TPred (OCmp o ra rc') >>= setCv v . Same
        OEqVal e a c | raw a, raw c -> do
          ra <- rawOf a
          rc' <- rawOf c
          emit TPred (OCmp (if e then Eq else Ne) ra rc') >>= setCv v . Same
        _ | raw v -> do
          g <- mapOpM op >>= emit TVal
          p <- emit TPred (OIsInt g)
          checkThen p (exitTo contOf extra b k v g)
          r <- emit TInt (OUntag g)
          setCv v (Both r g)
        _ -> do
          op' <- mapOpM op
          emit t op' >>= setCv v . Same

    copyTerm rawIds term = case term of
      TBr t as -> uncurry TBr <$> edge t as
      TCondBr p t as e bs -> do
        p' <- sameOf p
        (t', as') <- edge t as
        (e', bs') <- edge e bs
        pure (TCondBr p' t' as' e' bs')
      TRet v -> TRet <$> useOf v
      TRetProduct vs -> TRetProduct <$> mapM useOf vs
      TTailCall c as -> TTailCall c <$> mapM useOf as
      TUnreachable m -> pure (TUnreachable m)
      where
        edge t as
          | inRegion t = do
              as' <- zipWithM (\(p, _) a -> if raw p then rawOf a else useOf a) (bParams (byId M.! t)) as
              pure (rawIds M.! t, as')
          | otherwise = (t,) <$> mapM useOf as
