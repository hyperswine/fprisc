{-# LANGUAGE LambdaCase #-}

-- A tail-recursive receive SCC becomes a trampoline of value-only PAPs.
-- This runs AFTER checking source types and BEFORE specialization/inlining.
-- The private runtime protocol is existential: (True, next PAP) or
-- (False, the original result). It is not a polymorphic source primitive.
module ReceiveTurns (receiveTurns) where

import Data.Graph (SCC (..), stronglyConnComp)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC
import Infer (Type (..), Row (..))

receiveTurns :: M.Map Name Type -> [STop] -> Prog -> Prog -> (Prog, [String])
receiveTurns types tops context prog = (M.union rewritten prog, notes)
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
    transform ns
      | any (`S.member` managed) ns = Left "explicit region management; unchanged"
      | not (all typed ns) = Left "state/result is mutable, functional, polymorphic or lacks type evidence; unchanged"
      | any (\n -> let ar = length (fst (prog M.! n)) in ar == 0 || ar > 64) ns = Left "requires a parameterized call after arity spilling; unchanged"
      | otherwise = do
          bodies <- mapM (\n -> let (ps,b) = prog M.! n in (,) n <$> tailE (S.fromList ps) b) ns
          pure (M.fromList (concatMap make bodies))
      where
        group = S.fromList ns
        helper n = "$receive.turn." ++ n
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
                    next = CApp (CVar (helper n)) (pack (map CVar saved))
                 in Right (foldr (\(v,a) b -> CLet v a b) (CMk 4 0 [CMk 1 1 [], next]) (zip saved args))
            | not (mentions bound e) -> Right (CMk 4 0 [CMk 1 0 [], e])
            | otherwise -> Left "non-tail, partial or escaping recursive call; unchanged"
        make (n,b) =
          let ps = fst (prog M.! n)
              thunk = CApp (CVar (helper n)) (pack (map CVar ps))
              unpacked = foldr (\(i,p) body -> CLet p (if length ps == 1 then CVar "$receive.state" else CProj i (CVar "$receive.state")) body) b (zip [0..] ps)
           in [(n, (ps, CApp (CVar "$receiveLoop") thunk)),
               (helper n, (["$receive.state", "$receive.unit"], unpacked))]

    -- Only closed, first-order value types justify copying arbitrary state.
    -- Unknown variables and function captures must not silently smuggle a
    -- Vector into the trampoline. Nominal definitions are checked recursively.
    typed n = case M.lookup n types of
      Just ty -> let (as,r) = split (length (fst (prog M.! n))) ty
                  in length as == length (fst (prog M.! n)) && all (value S.empty) as
                     && (value S.empty r || neverReturns (M.findWithDefault S.empty n membership) (S.fromList (fst (prog M.! n))) (snd (prog M.! n)))
      Nothing -> False
    -- An infinite actor often has a polymorphic bottom result. It needs no
    -- copyable result type when EVERY terminal path is a saturated SCC call
    -- or a compiler trap: the trampoline can never return a False payload.
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
    value seen = \case
      TTupT ts -> all (value seen) ts
      TRec r -> row seen r
      t -> case tySpine t of
        (TC n,as)
          | n `elem` ["Int","String","Bool","Unit","Atom","I64","Word"] -> null as
          | n `elem` ["List","Result"] -> length as == (if n == "List" then 1 else 2) && all (value seen) as
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
pack [x] = x
pack xs = CMk (case length xs of 2 -> 4; 3 -> 5; n | n <= 8 -> n + 6; n -> tupWideBase + n) 0 xs
