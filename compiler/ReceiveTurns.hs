{-# LANGUAGE LambdaCase #-}

-- A tail-recursive receive SCC becomes a trampoline of value-only PAPs.
-- This runs AFTER checking source types and BEFORE specialization/inlining.
-- The private runtime protocol is existential: (True, next PAP) or
-- (False, the original result). It is not a polymorphic source primitive.
module ReceiveTurns (receiveTurns) where

import Data.List (intercalate)
import Data.Graph (SCC (..), stronglyConnComp)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC
import Infer (Type (..), Row (..))

receiveTurns :: M.Map Name Type -> [STop] -> Prog -> S.Set Name -> Prog -> (Prog, [String])
receiveTurns types tops context joins prog = (M.union rewritten prog, notes)
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
    receivers = effect ["receive", "receiveFrom", "receiveRes", "receiveNow", "receiveFromRes"]
    managed = effect ["Sys.poolReset", "Sys.arena", "Sys.loop", "Sys.loopWith", "$receiveLoop"]
    groups = [ns | CyclicSCC ns <- stronglyConnComp
                  [(n, n, S.toList (refs ps b `S.intersection` M.keysSet prog)) | (n,(ps,b)) <- M.toList prog],
                  any (`S.member` receivers) ns]
    membership = M.fromList [(n,S.fromList ns) | ns <- groups, n <- ns]
    results = map transform groups
    rewritten = M.unions [p | Right p <- results]
    notes = ["receive-turns: " ++ unwords ns ++ ": " ++ either id (const "automatic value-state turn regions") r
            | (ns,r) <- zip groups results]
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
    entries ns = close seeds S.\\ joins
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
      | not (null problems) = Left ("state/result is mutable, functional, polymorphic or lacks type evidence; unchanged (" ++ intercalate "; " problems ++ ")")
      | any (\n -> length (fst (prog M.! n)) > 64) ns = Left "requires at most 64 parameters after arity spilling; unchanged"
      | otherwise = do
          bodies <- mapM (\n -> let (ps,b) = prog M.! n in (,) n <$> tailE (S.fromList ps) b) ns
          pure (M.fromList (concatMap make bodies))
      where
        group = S.fromList ns
        boundaries = entries ns
        problems = concatMap typedProblems (S.toList boundaries)
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
               in [(n, (ps, CApp (CVar "$receiveLoop") thunk)),
                   (helper n, (["$receive.state", "$receive.unit"], unpacked))]

    -- Only live, closed first-order values cross a turn. Unknown captures
    -- still cannot smuggle a Vector into state; generated joins stay inside
    -- the current scratch arena. Nominal declarations are checked deeply.
    typedProblems n = case M.lookup n types of
      Just ty -> let ps = fst (prog M.! n)
                     (as,r) = split (length ps) ty
                  in if length as /= length ps then [n ++ ": parameter arity lacks type evidence"] else
                     [n ++ ": live parameter " ++ show i ++ " has " ++ show a
                      | (i,p,a) <- zip3 [1::Int ..] ps as, p `elem` kept n, not (value S.empty a)]
                     ++ [n ++ ": result has " ++ show r
                        | not (value S.empty r || nonReturning n)]
      Nothing -> [n ++ ": no checked source interface"]
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
          | n `elem` ["Int","String","Bool","Unit","Atom","I64","Word"] -> null as
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
