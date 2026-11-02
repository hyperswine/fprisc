-- Two-register returns for functions that answer a pair.
--
-- A function every result of which is a two-field constructor allocates that
-- cell only for its caller to read the fields back and drop it. The pass adds
-- a private twin, `$worker.ret2.<f>`, that native lowering answers in two
-- registers (Codegen.Lower: TRet2, OCall2), and sends to it every call whose
-- result is bound and read only through `case` on the constructor and field
-- projections. `f` itself is unchanged, so its address, its public arity and
-- every other caller keep the ordinary convention.
--
-- The twin's Core is `f`'s Core with its tail calls renamed to the twins of
-- the callees, so it still means exactly what `f` means; only the ABI that
-- lowering gives it differs.
module Core.Opt.PairReturns (pairReturnProgram, pairWorker, pairWorkerName) where
import Core.Syntax (Core(..), Prog, Name)
import Core.Utils (spineOf)
import Workers (ScalarSignatures)
import KernelKinds (Kind(..))
import Data.List (isPrefixOf, nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

pairPrefix :: String
pairPrefix = "$worker.ret2."

pairWorker :: Name -> Bool
pairWorker = isPrefixOf pairPrefix

pairWorkerName :: Name -> Name
pairWorkerName = (pairPrefix ++)

-- the work a twin copies is bounded as the scalar workers' bodies are
bodyBound :: Int
bodyBound = 1024

type Shape = (Int, Int)

data Leaf = Make Shape | Call Name Int | Trap

-- where a function's result comes from; Nothing for any other result
leaves :: Core -> Maybe [Leaf]
leaves e = case e of
  CLet _ _ b -> leaves b
  CIf _ t f -> (++) <$> leaves t <*> leaves f
  CMk t v [_, _] -> Just [Make (t, v)]
  CErr _ -> Just [Trap]
  _ -> case spineOf e of
    (CVar h, args@(_ : _)) -> Just [Call h (length args)]
    _ -> Nothing

-- the functions that answer a pair of one constructor, with that constructor
pairFunctions :: Prog -> M.Map Name Shape
pairFunctions prog = go (M.mapMaybe candidate prog)
  where
    candidate (ps, b)
      | null ps || size b > bodyBound = Nothing
      | otherwise = leaves b
    go cands =
      let shapes = fixShapes cands
          keep n ls = and
            [ case l of
                Call h k -> maybe False ((== k) . fst) (M.lookup h arities) && M.member h cands && M.member h shapes
                _ -> True
            | l <- ls ]
            && fmap length (M.lookup n shapes) == Just 1
          cands' = M.filterWithKey keep cands
       in if M.size cands' == M.size cands
            then M.mapMaybe (\ss -> case ss of [s] -> Just s; _ -> Nothing) shapes
            else go cands'
    arities = M.map (\(ps, _) -> (length ps, ())) prog
    -- the constructors a function can answer, through the calls it ends in
    fixShapes cands = iter (M.map (const []) cands) (0 :: Int)
      where
        direct = M.map (\ls -> nub [s | Make s <- ls]) cands
        callees = M.map (\ls -> [h | Call h _ <- ls]) cands
        iter acc n =
          let next = M.mapWithKey (\f d -> nub (d ++ concat [M.findWithDefault [] g acc | g <- M.findWithDefault [] f callees])) direct
           in if next == acc || n > M.size cands then next else iter next (n + 1)

size :: Core -> Int
size e = 1 + sum (map size (children e))

children :: Core -> [Core]
children e = case e of
  CApp a b -> [a, b]; CLet _ a b -> [a, b]; CIf a b c -> [a, b, c]
  CMk _ _ xs -> xs; CTagEq _ _ x -> [x]; CProj _ x -> [x]
  CLam _ x -> [x]; _ -> []

-- `t` is read only as the test of its own constructor and as field 0 or 1:
-- the body with the tests decided, or Nothing when `t` is used any other way
-- (it escapes, is rebound, or is captured by a lambda)
pairUses :: Shape -> Name -> Core -> Maybe Core
pairUses (tid, var) t = go
  where
    go e = case e of
      CVar x | x == t -> Nothing
      CIf (CTagEq t' v' (CVar x)) a _ | x == t -> if (t', v') == (tid, var) then go a else Nothing
      CProj i (CVar x) | x == t -> if i == 0 || i == 1 then Just e else Nothing
      CLet y a b | y == t -> Nothing
                 | otherwise -> CLet y <$> go a <*> go b
      CLam ps b | t `elem` ps || t `elem` freeIn b -> Nothing
                | otherwise -> Just (CLam ps b)
      CApp a b -> CApp <$> go a <*> go b
      CIf c a b -> CIf <$> go c <*> go a <*> go b
      CMk i v xs -> CMk i v <$> mapM go xs
      CTagEq i v x -> CTagEq i v <$> go x
      CProj i x -> CProj i <$> go x
      _ -> Just e
    freeIn b = case b of
      CVar x -> [x]
      _ -> concatMap freeIn (children b)

-- every let that binds a pair function's call and reads it as above calls the
-- twin instead
rewriteLets :: M.Map Name Shape -> S.Set Name -> Core -> (Core, Int)
rewriteLets pairs = go
  where
    go bound e = case e of
      CLet t a b
        | (CVar q, args) <- spineOf a, q `S.notMember` bound, Just shape <- M.lookup q pairs,
          Just b' <- pairUses shape t b ->
            let (args', n1) = goAll bound args
                (b'', n2) = go (S.insert t bound) b'
             in (CLet t (foldl CApp (CVar (pairWorkerName q)) args') b'', 1 + n1 + n2)
        | otherwise ->
            let (a', n1) = go bound a
                (b', n2) = go (S.insert t bound) b
             in (CLet t a' b', n1 + n2)
      CApp a b -> let (a', n1) = go bound a; (b', n2) = go bound b in (CApp a' b', n1 + n2)
      CIf c a b -> let (c', n1) = go bound c; (a', n2) = go bound a; (b', n3) = go bound b in (CIf c' a' b', n1 + n2 + n3)
      CLam ps b -> let (b', n) = go (S.union (S.fromList ps) bound) b in (CLam ps b', n)
      CMk i v xs -> let (xs', n) = goAll bound xs in (CMk i v xs', n)
      CTagEq i v x -> let (x', n) = go bound x in (CTagEq i v x', n)
      CProj i x -> let (x', n) = go bound x in (CProj i x', n)
      _ -> (e, 0)
    goAll bound xs = let rs = map (go bound) xs in (map fst rs, sum (map snd rs))

-- the twin's body: the calls it ends in go to the callees' twins
twinBody :: M.Map Name Shape -> S.Set Name -> Core -> Core
twinBody pairs = go
  where
    go bound e = case e of
      CLet x a b -> CLet x a (go (S.insert x bound) b)
      CIf c t f -> CIf c (go bound t) (go bound f)
      _ -> case spineOf e of
        (CVar h, args@(_ : _)) | h `S.notMember` bound, M.member h pairs -> foldl CApp (CVar (pairWorkerName h)) args
        _ -> e

pairReturnProgram :: Prog -> ScalarSignatures -> (Prog, ScalarSignatures, [String])
pairReturnProgram prog sigs
  | M.null pairs || sites == 0 = (prog, sigs, [])
  | otherwise = (prog', sigs', [note])
  where
    pairs = pairFunctions prog
    rewritten = M.mapWithKey (\_ (ps, b) -> let (b', n) = rewriteLets pairs (S.fromList ps) b in ((ps, b'), n)) prog
    sites = sum (map snd (M.elems rewritten))
    bodies = M.map fst rewritten
    allTwins = M.fromList
      [ (pairWorkerName f, (ps, twinBody pairs (S.fromList ps) b))
      | (f, (ps, b)) <- M.toList bodies, M.member f pairs ]
    -- only the twins a rewritten call reaches, through the twins' own calls
    reach seen [] = seen
    reach seen (n : ns)
      | S.member n seen = reach seen ns
      | otherwise = reach (S.insert n seen) (maybe [] (twinsIn . snd) (M.lookup n allTwins) ++ ns)
    twinsIn e = [h | CVar h <- universe e, M.member h allTwins]
    universe e = e : concatMap universe (children e)
    needed = reach S.empty (concat [twinsIn b | (_, b) <- M.elems bodies])
    twins = M.restrictKeys allTwins needed
    prog' = M.union bodies twins
    twinSigs = M.fromList
      [ (pairWorkerName f, (ks, KB))
      | (f, (ks, r)) <- M.toList sigs, M.member f pairs, r == KB, M.member (pairWorkerName f) twins ]
    sigs' = M.union sigs twinSigs
    note = "# pair returns: functions=" ++ show (M.size pairs) ++ " twins=" ++ show (M.size twins) ++ " sites=" ++ show sites
