-- Private constructor returns for hosted Base. A unary wrapper returns its
-- ordinary tagged payload; wider products use the private register ABI.
-- The original tagged entry
-- remains available for escapes and unsupported target widths. This is a
-- call-site allocation optimization, not checked builtin aggregate storage.
module Core.Opt.PairReturns (pairReturnProgram, productReturnProgram, productReturnProgramWithVariants, productWorkerWidth, pairWorker, pairWorkerName) where
import Core.Syntax (Core(..), Prog, Name)
import Core.Utils (spineOf)
import qualified Core.Opt.VariantReturns as Variant
import Core.Opt.ProductParameters (VariantLayout)
import qualified Core.Opt.NestedReturns as Nested
import Control.Applicative ((<|>))
import Workers (ScalarSignatures)
import KernelKinds (Kind(..))
import Data.Graph (flattenSCC, stronglyConnComp)
import Data.List (foldl', isPrefixOf, stripPrefix)
import Text.Read (readMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

productWorkerName :: Int -> Name -> Name
productWorkerName n f = "$worker.ret" ++ show n ++ "." ++ f

productWorkerWidth :: Name -> Maybe Int
productWorkerWidth name = do
  rest <- stripPrefix "$worker.ret" name
  let (digits, suffix) = break (== '.') rest
  n <- readMaybe digits
  -- ret1 deliberately uses the ordinary value convention, not TProduct 1.
  if n >= 2 && n <= 8 && not (null suffix) && digits == show n then Just n else Nothing

pairWorker :: Name -> Bool
pairWorker = isPrefixOf "$worker.ret2."

pairWorkerName :: Name -> Name
pairWorkerName = productWorkerName 2

type Shape = (Int, Int, Int)

data Leaf = Make Shape | Call Name Int (S.Set Name) | Trap

-- where a function's result comes from; Nothing for any other result
leaves :: Int -> S.Set Name -> Core -> Maybe [Leaf]
leaves width bound e = case e of
  CLet x _ b -> leaves width (S.insert x bound) b
  CIf _ t f -> (++) <$> leaves width bound t <*> leaves width bound f
  CMk t v xs | not (null xs) && length xs <= width -> Just [Make (t, v, length xs)]
  CErr _ -> Just [Trap]
  _ -> case spineOf e of
    (CVar h, args@(_ : _)) | S.notMember h bound -> Just [Call h (length args) bound]
    _ -> Nothing

-- the functions that answer a product of one constructor, with that constructor
productFunctions :: Int -> Prog -> M.Map Name Shape
productFunctions width prog = foldl' admit M.empty components
  where
    candidates = M.mapMaybe candidate prog
    candidate ([], _) = Nothing
    candidate (ps, b) = leaves width (S.fromList ps) b
    components = map flattenSCC $ stronglyConnComp
      [(name, name, [h | Call h _ _ <- paths]) | (name, paths) <- M.toList candidates]

    -- Every member of a recursive component reaches every other member.
    -- Its possible results are its own constructors plus the results of
    -- calls leaving the component. Process callees first, and admit all
    -- members together only when those successful paths agree.
    admit known names = case traverse evidence paths of
      Just answers | [shape@(_, _, fields)] <- S.toList (S.fromList (concat answers)),
                     all (available fields) names, all (uncaptured fields) paths ->
        foldl' (\m n -> M.insert n shape m) known names
      _ -> known
      where
        members = S.fromList names
        paths = concatMap (candidates M.!) names
        evidence Trap = Just []
        evidence (Make shape) = Just [shape]
        evidence (Call h k _) = do
          (ps, _) <- M.lookup h prog
          if length ps /= k then Nothing else
            if S.member h members then Just [] else (:[]) <$> M.lookup h known
        available fields n = M.notMember (productWorkerName fields n) prog
        uncaptured fields (Call h _ bound) = S.notMember (productWorkerName fields h) bound
        uncaptured _ _ = True

children :: Core -> [Core]
children e = case e of
  CApp a b -> [a, b]; CLet _ a b -> [a, b]; CIf a b c -> [a, b, c]
  CMk _ _ xs -> xs; CTagEq _ _ x -> [x]; CProj _ x -> [x]
  CLam _ x -> [x]; _ -> []

mentions :: Name -> Core -> Bool
mentions x (CVar y) = x == y
mentions x (CLet y a b) = mentions x a || (y /= x && mentions x b)
mentions x (CLam ps b) = x `notElem` ps && mentions x b
mentions x e = any (mentions x) (children e)

-- `t` is read at least once and only as the test of its own constructor and as
-- a field within the known product width: the body with the tests decided, or Nothing when `t` is unused
-- or used any other way (it escapes, is rebound, or is captured by a lambda)
productUses :: Shape -> Name -> Core -> Maybe Core
productUses (tid, var, width) t body = do
  (body', used) <- go body
  if used then Just body' else Nothing
  where
    go e = case e of
      CVar x | x == t -> Nothing
      CIf (CTagEq t' v' (CVar x)) a b | x == t ->
        if (t', v') == (tid, var)
          then (\(a', _) -> (a', True)) <$> go a
          else if t' == tid
            then (\(b', _) -> (b', True)) <$> go b
            else Nothing
      CProj i (CVar x) | x == t ->
        if i >= 0 && i < width
          then Just (if width == 1 then CVar x else e, True)
          else Nothing
      CLet y a b | y == t -> Nothing
                 | otherwise -> do
                     (a', u1) <- go a
                     (b', u2) <- go b
                     Just (CLet y a' b', u1 || u2)
      CLam ps b | t `elem` ps || mentions t b -> Nothing
                | otherwise -> Just (CLam ps b, False)
      CApp a b -> do
        (a', u1) <- go a
        (b', u2) <- go b
        Just (CApp a' b', u1 || u2)
      CIf c a b -> do
        (c', u1) <- go c
        (a', u2) <- go a
        (b', u3) <- go b
        Just (CIf c' a' b', u1 || u2 || u3)
      CMk i v xs -> do
        rs <- mapM go xs
        Just (CMk i v (map fst rs), any snd rs)
      CTagEq i v x -> do
        (x', u) <- go x
        Just (CTagEq i v x', u)
      CProj i x -> do
        (x', u) <- go x
        Just (CProj i x', u)
      _ -> Just (e, False)

-- every saturated let that binds a product function's call and reads it as above
-- calls the twin instead
rewriteLets :: Prog -> M.Map Name Variant.Plan -> M.Map Name Int -> M.Map Name Shape -> M.Map Name Nested.Nested -> S.Set Name -> Core -> (Core, Int)
rewriteLets prog variants arities products nested = go
  where
    go bound e = case e of
      CLet t a b
        | Just rewritten <- binding bound t a b -> rewritten
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
    -- A strict argument prefix can hide the producer at the end of a let
    -- RHS. Extend its binders' scopes only when they cannot capture the
    -- consumer. Keep every prefix in its original order, and publish the
    -- reshaping only if the final call and consumer pass normal admission.
    binding bound t rhs body = case rhs of
      CLet x a rest | x /= t, not (mentions x body) -> do
        (next,n) <- binding (S.insert x bound) t rest body
        let (a',na) = go bound a
        Just (CLet x a' next,n+na)
      CApp (CApp (CVar "$callLeave") (CVar tok)) call
        | S.member tok bound, (CVar q,args) <- spineOf call, Just plan <- M.lookup q variants -> do
          let entry=Variant.entry plan
          if S.member q bound || S.member entry bound || M.lookup q arities/=Just (length args) then Nothing else do
            body' <- Variant.reader prog bound plan t body
            let (args',n1)=goAll bound args
                (body'',n2)=go (S.insert t bound) body'
            rhs' <- Variant.regionResult prog bound plan t tok (foldl CApp (CVar entry) args')
            Just (CLet t rhs' body'',1+n1+n2)
      _ | (CVar q,args) <- spineOf rhs, q `S.notMember` bound,
          Just ar <- M.lookup q arities, length args == ar,
          let productSite = do
                shape@(_,_,width) <- M.lookup q products
                let deep = do plan <- M.lookup q nested
                              use (Nested.nestedName plan) (Nested.nestedReader plan t body)
                deep <|> use (productWorkerName width q) (productUses shape t body)
              variant = do plan <- M.lookup q variants
                           use (Variant.entry plan) (Variant.reader prog bound plan t body)
              use name readBody = if S.member name bound then Nothing else (,) name <$> readBody,
          Just (entry,body') <- productSite <|> variant ->
            let (args',n1) = goAll bound args
                (body'',n2) = go (S.insert t bound) body'
            in Just (CLet t (foldl CApp (CVar entry) args') body'',1+n1+n2)
        | otherwise -> Nothing
    goAll bound xs = let rs = map (go bound) xs in (map fst rs, sum (map snd rs))

-- the twin's body: the saturated calls it ends in go to the callees' twins
twinBody :: M.Map Name Int -> M.Map Name Shape -> S.Set Name -> Core -> Core
twinBody arities products = go
  where
    go bound e = case e of
      CLet x a b -> CLet x a (go (S.insert x bound) b)
      CIf c t f -> CIf c (go bound t) (go bound f)
      -- The single result field still evaluates in place, including effects,
      -- failures and owned values. Only its enclosing constructor disappears.
      CMk _ _ [x] -> x
      _ -> case spineOf e of
        (CVar h, args@(_ : _))
          | h `S.notMember` bound, Just (_,_,width) <- M.lookup h products,
            Just ar <- M.lookup h arities, length args == ar ->
              foldl CApp (CVar (productWorkerName width h)) args
        _ -> e

pairReturnProgram :: Prog -> ScalarSignatures -> (Prog, ScalarSignatures, [String])
pairReturnProgram = productReturnProgram 2

productReturnProgram :: Int -> Prog -> ScalarSignatures -> (Prog, ScalarSignatures, [String])
productReturnProgram=productReturnProgramWithVariants M.empty

productReturnProgramWithVariants :: M.Map Name VariantLayout -> Int -> Prog -> ScalarSignatures -> (Prog,ScalarSignatures,[String])
productReturnProgramWithVariants checked width prog sigs
  | (M.null products && M.null variants) || sites == 0 = (prog, sigs, [])
  | otherwise = (prog', sigs', [note])
  where
    arities = M.map (length . fst) prog
    products = productFunctions (min 8 width) prog
    twinName f = let (_,_,n) = products M.! f in productWorkerName n f
    (nested,adapters) = Nested.nestedPlans (min 8 width) prog (M.keysSet products)
    (variants,variantTwins)=Variant.plans (min 8 width) prog checked
    rewritten = M.mapWithKey (\_ (ps, b) -> let (b', n) = rewriteLets prog variants arities products nested (S.fromList ps) b in ((ps, b'), n)) prog
    sites = sum (map snd (M.elems rewritten))
    bodies = M.map fst rewritten
    allTwins = M.unions [variantTwins,adapters, M.fromList [(Nested.nestedName plan,Nested.nestedCode plan) | plan<-M.elems nested], shallowTwins]
    shallowTwins = M.fromList
      [ (twinName f, (ps, twinBody arities products (S.fromList ps) b))
      | (f, (ps, b)) <- M.toList bodies, M.member f products ]
    -- only the twins a rewritten call reaches, through the twins' own calls
    reach seen [] = seen
    reach seen (n : ns)
      | S.member n seen = reach seen ns
      | otherwise = reach (S.insert n seen) (maybe [] (twinsIn . snd) (M.lookup n allTwins) ++ ns)
    twinsIn e = collect e []
    collect e rest = case e of
      CVar h@('$':_) | M.member h allTwins -> h:rest
      CLet _ a b -> collect a (collect b rest)
      CApp a b -> collect a (collect b rest)
      CIf c a b -> collect c (collect a (collect b rest))
      CMk _ _ xs -> foldr collect rest xs
      CLam _ b -> collect b rest
      CProj _ a -> collect a rest
      CTagEq _ _ a -> collect a rest
      _ -> rest
    needed = reach S.empty (concat [twinsIn b | (_, b) <- M.elems bodies])
    twins = M.restrictKeys allTwins needed
    prog' = M.union bodies twins
    twinSigs = M.fromList
      [ (entry, (ks, KB))
      | (f, (ks, r)) <- M.toList sigs, M.member f products, r == KB,
        entry <- twinName f : maybe [] ((:[]) . Nested.nestedName) (M.lookup f nested), M.member entry twins ]
    sigs' = M.union sigs twinSigs
    note = "# pair returns: functions=" ++ show (M.size products) ++ " twins=" ++ show (M.size twins) ++ " sites=" ++ show sites
