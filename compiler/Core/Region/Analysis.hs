{-# LANGUAGE LambdaCase #-}
-- Region dataflow facts over an explicitly owned representation projection.
-- No source types are inferred here. Typed control producers retain the input
-- and recheck these facts if a later pass changes the logical source graph.
module Core.Region.Analysis (liveParameters,invariantParameters,nonReturning) where
import Core.Syntax
import Data.List (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S

invariantParameters prog ns = S.fromList [slot | slot <- M.keys cls, S.member (rep slot) good]
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

liveParameters members prog = settle (M.map (const S.empty) prog)
  where
    settle known =
      let next = M.mapWithKey (\n (ps,b) -> S.fromList ps `S.intersection` needed known (S.fromList ps) b) prog
       in if next == known then known else settle next
    needed known bound e
      | (CVar n,as) <- spine e, n `S.member` members,
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

nonReturning prog group=all (\n->let (ps,b)=prog M.! n in never (S.fromList ps) b) (S.toList group)
  where
    never bound = \case
      CLet x _ b->never (S.insert x bound) b
      CIf _ a b->never bound a && never bound b
      CErr _->True
      e->case spine e of
        (CVar g,args)->g `S.member` group && g `S.notMember` bound && length args==length (fst (prog M.! g))
        _->False
spine=go [] where go args (CApp f a)=go (a:args) f;go args e=(e,args)
