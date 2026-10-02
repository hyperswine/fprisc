{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
-- Function-argument specialization on lifted Core. Unknown/escaping functions
-- retain the open-world callable ABI. Budgets always fall back to original calls.
module Mono (specializeFunctions, qualifyAux, references) where

import FPRISC (Core(..), Name, Prog, freeVars)
import Data.Graph (SCC(..), stronglyConnComp)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- A callback's code identity and the expressions for its already supplied args.
type Known = (Name, [Core])
type Scope = M.Map Name (Maybe Known)
type Key = (Name, [(Int, Name, Int)])
data Work = Work { clones :: Prog, seen :: M.Map Key Name, serial :: Int, weight :: Int }

-- Auxiliaries have compiler-generated names, not source/module identities.
-- Copies imported into a caller must not collide with its own lifted names.
qualifyAux :: String -> S.Set Name -> Prog -> Prog
qualifyAux prefix source p = M.fromList
  [(ren n, (ps, renameGlobals mapping (S.fromList ps) b)) | (n,(ps,b)) <- M.toList p]
  where
    mapping = M.fromList [(n, prefix ++ n) | n <- M.keys p, n `S.notMember` source]
    ren n = M.findWithDefault n n mapping

specializeFunctions :: String -> M.Map Name Int -> Prog -> Prog -> Prog
specializeFunctions namespace arities external input = includeAux result
  where
    -- Global callback identities must stay global even if the caller later
    -- shadows their spelling after binding an alias to the function value.
    localize n (ps,b) =
      let freshLocal local = "$spec.local." ++ namespace ++ "." ++ n ++ "." ++ local
          renamed = map freshLocal ps
      in (renamed, alpha (M.fromList (zip ps renamed)) freshLocal b)
    localInput = M.mapWithKey localize input
    universe = M.union localInput external
    ars = M.union (M.map (length . fst) universe) arities
    demand = callbackParameters universe
    groups = M.fromList [(n,S.fromList ns) | component <- stronglyConnComp
      [(n,n,S.toList (references ps b `S.intersection` M.keysSet universe)) | (n,(ps,b)) <- M.toList universe],
      let ns = case component of AcyclicSCC n -> [n]; CyclicSCC names -> names, n <- ns]
    stable g i = stableCallback universe demand (M.findWithDefault (S.singleton g) g groups) g i
    initial = Work M.empty M.empty 0 0
    (out, st) = runState (M.traverseWithKey (\_ (ps,b) -> (ps,) <$> walk 0 (blocked ps) b) localInput) initial
    result = M.union out (clones st)
    -- Only private imported helpers referenced by emitted bodies are copied.
    -- Ordinary imported globals still link against their cached home units.
    aux = M.filterWithKey (\n _ -> "$specaux." `prefixOf` n) external
    includeAux p = let missing = S.unions [references ps b | (ps,b) <- M.elems p] S.\\ M.keysSet p
                       extra = M.restrictKeys aux missing
                   in if M.null extra then p else includeAux (M.union p extra)
    blocked = M.fromList . map (,Nothing)
    fresh :: String -> State Work Name
    fresh stem = do
      s <- get
      put s { serial = serial s + 1 }
      pure ("$spec." ++ namespace ++ "." ++ stem ++ "." ++ show (serial s))
    known scope e = case spine e of
      (CVar h, xs) -> case M.lookup h scope of
        Just (Just (g, cs)) -> valid g (cs ++ xs)
        Just Nothing -> Nothing
        Nothing -> valid h xs
      _ -> Nothing
      where valid h cs = case M.lookup h ars of
              Just n | n > length cs -> Just (h,cs)
              _ -> Nothing
    walk :: Int -> Scope -> Core -> State Work Core
    walk depth scope = \case
      CLet n a b -> do
        a' <- walk depth scope a
        case known scope a' of
          Just (h,cs) -> do
            saved <- mapM (const (fresh "capture")) cs
            let target = (h, map CVar saved)
            b' <- walk depth (M.insert n (Just target) scope) b
            let body = if n `elem` freeVars b' then CLet n (app h (snd target)) b' else b'
            pure (lets (zip saved cs) body)
          Nothing -> CLet n a' <$> walk depth (M.insert n Nothing scope) b
      e@(CApp _ _) -> do
        let (head0, args0) = spine e
        -- Rebuild the entire spine: visiting partial prefixes would create
        -- clones/PAPs before we know whether the call is saturated.
        args <- mapM (walk depth scope) args0
        let hd = case head0 of CVar n -> maybe head0 (uncurry app) (M.lookup n scope >>= id); _ -> head0
        hd' <- case hd of CVar _ -> pure hd; CApp _ _ -> pure hd; _ -> walk depth scope hd
        let (head1, leading) = spine hd'
            allArgs = leading ++ args
        case head1 of
          CVar g | M.notMember g scope, Just (ps,_) <- M.lookup g universe, length ps == length allArgs -> do
            let choices = [(i,h,cs) | (i,a) <- zip [0..] allArgs,
                            Just (h,cs) <- [known scope a],
                            i `S.member` M.findWithDefault S.empty g demand, stable g i]
            if null choices then pure (app g allArgs) else do
              clone <- getClone depth g choices
              case clone of
                Nothing -> pure (app g allArgs)
                Just name -> do
                  -- Strict left-to-right evaluation, including capture effects
                  -- at exactly the callback argument's original position.
                  bindings <- mapM (\(i,a) -> case lookup i [(j,cs) | (j,_,cs) <- choices] of
                    Just cs -> do ns <- mapM (const (fresh "arg")) cs; pure (zip ns cs, map CVar ns)
                    Nothing -> do n <- fresh "arg"; pure ([(n,a)], [CVar n])) (zip [0..] allArgs)
                  pure (lets (concatMap fst bindings) (app name (concatMap snd bindings)))
          _ -> pure (foldl CApp hd' args)
      CLam ps b -> CLam ps <$> walk depth (M.union (blocked ps) scope) b
      CIf c t f -> CIf <$> walk depth scope c <*> walk depth scope t <*> walk depth scope f
      CMk t v fs -> CMk t v <$> mapM (walk depth scope) fs
      CTagEq t v x -> CTagEq t v <$> walk depth scope x
      CProj i x -> CProj i <$> walk depth scope x
      CVar n -> pure (CVar n)
      e -> pure e
    getClone :: Int -> Name -> [(Int,Name,[Core])] -> State Work (Maybe Name)
    getClone depth g choices = do
      s <- get
      let key = (g, [(i,h,length cs) | (i,h,cs) <- choices])
          (ps,body) = universe M.! g
      case M.lookup key (seen s) of
        Just n -> pure (Just n)
        Nothing | length ps - length choices + sum [length cs | (_,_,cs) <- choices] > 64 || depth >= 12 || M.size (seen s) >= 256 || weight s + nodes body > 60000 -> pure Nothing
        Nothing -> do
          name <- fresh (g ++ ".mono")
          let renamed = map (name ++) ps
              renamedBody = alpha (M.fromList (zip ps renamed)) (name ++) body
          captures <- mapM (\(i,h,cs) -> do ns <- mapM (const (fresh "param")) cs; pure (i,h,ns)) choices
          let replacement = M.fromList [(renamed !! i, app h (map CVar ns)) | (i,h,ns) <- captures]
              params = concat [maybe [p] (\(_,_,ns) -> ns) (findIndex i captures) | (i,p) <- zip [0..] renamed]
              fixed = substitute replacement renamedBody
          -- Register before visiting the clone, so self and mutual recursion
          -- converge to the same identities rather than unrolling.
          modify (\w -> w {seen = M.insert key name (seen w), weight = weight w + nodes body})
          b <- walk (depth+1) (blocked params) fixed
          modify (\w -> w {clones = M.insert name (params,b) (clones w)})
          pure (Just name)
    findIndex i = foldr (\x@(j,_,_) r -> if i == j then Just x else r) Nothing

app :: Name -> [Core] -> Core
app n = foldl CApp (CVar n)
lets :: [(Name,Core)] -> Core -> Core
lets bs body = foldr (uncurry CLet) body bs
spine :: Core -> (Core,[Core])
spine = go [] where go xs (CApp f a) = go (a:xs) f; go xs f = (f,xs)
prefixOf :: String -> String -> Bool
prefixOf a b = take (length a) b == a
references :: [Name] -> Core -> S.Set Name
references ps b = S.fromList (freeVars b) S.\\ S.fromList ps
nodes :: Core -> Int
nodes = \case
  CApp f a -> 1 + nodes f + nodes a
  CLet _ a b -> 1 + nodes a + nodes b
  CLam _ b -> 1 + nodes b
  CIf c t f -> 1 + nodes c + nodes t + nodes f
  CMk _ _ xs -> 1 + sum (map nodes xs)
  CTagEq _ _ x -> 1 + nodes x
  CProj _ x -> 1 + nodes x
  _ -> 1
substitute :: M.Map Name Core -> Core -> Core
substitute m = \case
  CVar n -> M.findWithDefault (CVar n) n m
  CApp f a -> CApp (substitute m f) (substitute m a)
  CLet n a b -> CLet n (substitute m a) (substitute (M.delete n m) b)
  CLam ps b -> CLam ps (substitute (foldr M.delete m ps) b)
  CIf c t f -> CIf (substitute m c) (substitute m t) (substitute m f)
  CMk t v xs -> CMk t v (map (substitute m) xs)
  CTagEq t v x -> CTagEq t v (substitute m x)
  CProj i x -> CProj i (substitute m x)
  e -> e
renameGlobals :: M.Map Name Name -> S.Set Name -> Core -> Core
renameGlobals m bound = substitute (M.map CVar (foldr M.delete m (S.toList bound)))

-- Alpha-renaming before callback substitution prevents a callee-local binder
-- from capturing the global callback supplied by the caller.
alpha :: M.Map Name Name -> (Name -> Name) -> Core -> Core
alpha m fresh = \case
  CVar n -> CVar (M.findWithDefault n n m)
  CApp f a -> CApp (alpha m fresh f) (alpha m fresh a)
  CLet n a b -> CLet (fresh n) (alpha m fresh a) (alpha (M.insert n (fresh n) m) fresh b)
  CLam ps b -> CLam (map fresh ps) (alpha (M.union (M.fromList [(p,fresh p) | p <- ps]) m) fresh b)
  CIf c t f -> CIf (alpha m fresh c) (alpha m fresh t) (alpha m fresh f)
  CMk t v xs -> CMk t v (map (alpha m fresh) xs)
  CTagEq t v x -> CTagEq t v (alpha m fresh x)
  CProj i x -> CProj i (alpha m fresh x)
  e -> e

-- Demand flows backwards through forwarding wrappers and recursive groups.
-- Analysis uses distinct parameter tokens so lexical shadowing cannot make
-- a local function look like a callee parameter or a global.
callbackParameters :: Prog -> M.Map Name (S.Set Int)
callbackParameters p = fix (M.map (const S.empty) p)
  where
    fix old = let new = M.map (\(ps,b) -> S.fromList
                    [i | (i,param) <- zip [0..] ps,
                         any (uses (token param)) (calls ps b)]) p
                  uses param (h,args) = h == param ||
                    any (\j -> j < length args && args !! j == CVar param)
                      (S.toList (M.findWithDefault S.empty h old))
              in if new == old then new else fix new

stableCallback :: Prog -> M.Map Name (S.Set Int) -> S.Set Name -> Name -> Int -> Bool
stableCallback p demand group g i = visit S.empty [(g,i)]
  where
    visit _ [] = True
    visit visited (role@(n,j):rest)
      | role `S.member` visited = visit visited rest
      | otherwise =
          let (ps,b) = p M.! n
              param = token (ps !! j)
              edges = [(h,k,a) | (h,args) <- calls ps b, h `S.member` group,
                       k <- S.toList (M.findWithDefault S.empty h demand),
                       k < length args, let a = args !! k]
              changed (h,k,a) = a /= CVar param &&
                (param `elem` freeVars a || (h,k) `S.member` S.insert role visited)
              forwarded = [(h,k) | (h,k,CVar a) <- edges, a == param]
          in not (any changed edges) && visit (S.insert role visited) (forwarded ++ rest)

token :: Name -> Name
token = ("$analysis.param." ++)
calls :: [Name] -> Core -> [(Name,[Core])]
calls ps = go (M.fromList [(n,CVar (token n)) | n <- ps])
  where
    go scope e = case e of
      CApp _ _ ->
        let (h,args) = spine e
            normalized = map (substitute scope) args
            site = case substitute scope h of CVar n -> [(n,normalized)]; _ -> []
        in site ++ concatMap (go scope) (h:args)
      CLet n a b ->
        let rhs = substitute scope a
            alias = case rhs of CVar _ -> rhs; _ -> CVar ("$analysis.local." ++ n)
        in go scope a ++ go (M.insert n alias scope) b
      CLam names b -> go (M.union (M.fromList [(n,CVar ("$analysis.local." ++ n)) | n <- names]) scope) b
      CIf c t f -> concatMap (go scope) [c,t,f]
      CMk _ _ xs -> concatMap (go scope) xs
      CTagEq _ _ x -> go scope x
      CProj _ x -> go scope x
      _ -> []
