-- Private Base worker/wrapper conventions. Public arities and function values
-- stay general. This pass runs after all source safety/ownership checking.
module Workers (workerize, workerizeWithSignatures, ScalarSignatures, internalWorker, scalarPrimitives) where

import FPRISC (Core(..), Prog)
import KernelKinds (Kind(..), signatureStrict)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isPrefixOf)
import Data.Maybe (mapMaybe)
import Data.Graph (SCC(..), stronglyConnComp)

prefix :: String
prefix = "$worker."
internalWorker :: String -> Bool
internalWorker = isPrefixOf prefix
scalarPrimitives :: [(String,Int)]
scalarPrimitives = [("$scalar."++op,2) | op <- ops] ++
                   [("$scalar.unbox",1),("$scalar.box",1),("$scalar.isInt",1)]
ops :: [String]
ops = ["+","-","*","/","==","!=","<",">","<=",">="]
spine :: Core -> (Core,[Core])
spine = go [] where go xs (CApp f a) = go (a:xs) f; go xs f = (f,xs)
app :: String -> [Core] -> Core
app f = foldl CApp (CVar f)
size :: Core -> Int
size e = 1 + sum (map size (children e))
children :: Core -> [Core]
children e = case e of
  CApp a b -> [a,b]; CLet _ a b -> [a,b]; CIf a b c -> [a,b,c]
  CMk _ _ xs -> xs; CTagEq _ _ x -> [x]; CProj _ x -> [x]
  CLam _ x -> [x]; _ -> []
walk :: (Core -> Core) -> Core -> Core
walk f = go where
  go e = f $ case e of
    CApp a b -> CApp (go a) (go b)
    CLet n a b -> CLet n (go a) (go b)
    CIf a b c -> CIf (go a) (go b) (go c)
    CMk t v xs -> CMk t v (map go xs)
    CTagEq t v x -> CTagEq t v (go x)
    CProj k x -> CProj k (go x)
    CLam ps x -> CLam ps (go x)
    _ -> e
-- Core binders are lexical. Only substitute free occurrences.
subst :: String -> Core -> Core -> Core
subst n value = go where
  go (CVar x) | x == n = value
  go (CLet x a b) = CLet x (go a) (if x == n then b else go b)
  go (CLam ps b) | n `elem` ps = CLam ps b
  go e = case e of
    CApp a b -> CApp (go a) (go b); CIf a b c -> CIf (go a) (go b) (go c)
    CMk t v xs -> CMk t v (map go xs); CTagEq t v x -> CTagEq t v (go x)
    CProj k x -> CProj k (go x); CLam ps b -> CLam ps (go b); _ -> e
-- The generated pattern aliases refer only to locals, never effectful CAFs.
aliases :: S.Set String -> Core -> Core
aliases locals e = case e of
  CLet n (CVar x) b | S.member x locals, not (rebinds x b) -> aliases locals (subst n (CVar x) b)
  CLet n a b -> CLet n (aliases locals a) (aliases (S.insert n locals) b)
  CIf a b c -> CIf (aliases locals a) (aliases locals b) (aliases locals c)
  CApp a b -> CApp (aliases locals a) (aliases locals b)
  CMk t v xs -> CMk t v (map (aliases locals) xs)
  CTagEq t v x -> CTagEq t v (aliases locals x)
  CProj k x -> CProj k (aliases locals x)
  _ -> e
rebinds :: String -> Core -> Bool
rebinds x e = case e of
  CLet n _ _ | n==x -> True
  CLam ps _ | x `elem` ps -> True
  _ -> any (rebinds x) (children e)
reduce :: Core -> Core
reduce = walk $ \e -> case e of
  CProj k (CMk _ _ xs) | k >= 0, k < length xs, all fieldVar xs -> xs !! k
  CTagEq t v (CMk t' v' xs) | all fieldVar xs -> CMk 1 (if (t,v)==(t',v') then 1 else 0) []
  CIf (CMk 1 1 []) a _ -> a
  CIf (CMk 1 0 []) _ b -> b
  _ -> e
  where fieldVar (CVar n) = (prefix++"field.") `isPrefixOf` n
        fieldVar _ = False

-- Preserve the existing vector kernel tier: its arithmetic-closure analysis
-- must continue to see original callbacks, not our general-entry guards.
vectorCallbacks :: Prog -> S.Set String
vectorCallbacks prog = close roots
  where
    nodes e = e : concatMap nodes (children e)
    calls ps b = S.fromList [f | e<-nodes b, (CVar f,args)<-[spine e],
                                 not (null args), f `notElem` ps, M.member f prog]
    roots = S.fromList [f | (_,(_,b))<-M.toList prog, e<-nodes b,
                            (CVar op,args)<-[spine e], "Vec." `isPrefixOf` op,
                            a<-args, (CVar f,_)<-[spine a], M.member f prog]
    close seen = let next=seen `S.union` S.unions [calls ps b | f<-S.toList seen, let (ps,b)=prog M.! f]
                 in if next==seen then seen else close next

workerize :: Bool -> Bool -> Prog -> (Prog,[String])
workerize fields scalars prog =
  let (p, notes, _) = workerizeWithSignatures fields scalars prog
  in (p, notes)

-- Ordered parameter/result representations, recorded when the worker is
-- chosen. Consumers must not infer this ABI from an already-rewritten body.
type ScalarSignatures = M.Map String ([Kind], Kind)

workerizeWithSignatures :: Bool -> Bool -> Prog -> (Prog,[String],ScalarSignatures)
workerizeWithSignatures fields scalars prog =
  let (p,nf) = if fields then fieldWorkers prog else (prog,0)
      (q,sigs) = if scalars then scalarWorkers p else (p,M.empty)
  in (q,["# private workers: fields="++show nf++" scalar="++show (M.size sigs)],sigs)

-- One fixed-width constructor parameter per function. The expanded arity
-- must fit the native ABI (8 registers plus 56 per-hart spill cells).
-- Whole-value uses must forward to the same recursive parameter. Returning
-- the original accumulator would require a new allocation at a general entry, so it
-- stays general too. Explicit constructor results retain their original cost.
fieldWorkers :: Prog -> (Prog,Int)
fieldWorkers input = (M.map (\(ps,b)->(ps,rewrite (S.fromList ps) b)) combined,M.size plans)
  where
    prog = M.map (\(ps,b)->(ps,aliases (S.fromList ps) b)) input
    arities = M.fromListWith S.union [( (t,v), S.singleton (length xs)) |
                 (_,(_,b)) <- M.toList prog, CMk t v xs <- nodes b]
    nodes e = e : concatMap nodes (children e)
    blocked = vectorCallbacks prog
    choose (name,(ps,b))
      | S.member name blocked = Nothing
      | null ps || length ps > 64 || size b > 8192 || internalWorker name = Nothing
      | otherwise = case mapMaybe (candidate name ps b) (zip [0..] ps) of
          (i,tv,width):_ -> Just (name,(i,tv,width,prefix++"fields."++name))
          _ -> Nothing
    candidate name ps b (i,p) = do
      let tags = S.fromList [(t,v) | CTagEq t v (CVar x) <- nodes b, x==p]
          -- Record projections may test several shapes sharing a field name.
          -- Prefer a unique reconstructed recursive shape; the general wrapper
          -- checks that shape before entering the worker. Other shape tests
          -- then reduce against the known constructor without losing branches
          -- at the general entry.
          rebuilt = S.fromList [(t,v) | e<-nodes b, (CVar f,args)<-[spine e],
                                f==name, length args==length ps, CMk t v _<-[args!!i]]
      tv <- case (S.toList rebuilt, S.toList tags) of
              ([one], _) -> Just one
              (_, [one]) -> Just one
              _ -> Nothing
      width <- case M.lookup tv arities of
        Just widths | [n] <- S.toList widths -> Just n
        _ -> Nothing
      -- Discard only branches excluded by the guarded constructor shape.
      -- A shared record field can have different offsets in other shapes;
      -- those unreachable projections must not veto this worker.
      let narrowed = narrow p tv b
          projections = [k | CProj k (CVar x) <- nodes narrowed, x==p]
      if width < 2 || length ps - 1 + width > 64 || size narrowed > 1024 || null projections ||
         any (\k -> k < 0 || k >= width) projections ||
         name `elem` ps || rebinds name b || rebinds p b ||
         not (uses name i p width narrowed) ||
         size (snd (makeBody name ps b i tv width)) > 1024 ||
         not (any (recursive name (length ps) i tv width) (nodes narrowed))
        then Nothing else Just (i,tv,width)
    narrow p tv = walk $ \e -> case e of
      CTagEq t v (CVar x) | x==p -> CMk 1 (if tv==(t,v) then 1 else 0) []
      CIf (CMk 1 1 []) a _ -> a
      CIf (CMk 1 0 []) _ b -> b
      _ -> e
    recursive name arity i (t,v) width e = case spine e of
      (CVar f,args) | f==name, length args==arity -> case args!!i of
        CMk t' v' xs -> (t,v)==(t',v') && length xs==width; _ -> False
      _ -> False
    uses name i p width e = case e of
      CVar x | x==p -> False
      CProj k (CVar x) | x==p -> k >= 0 && k < width
      CTagEq _ _ (CVar x) | x==p -> True
      CLet x a b -> uses name i p width a && (x==p || uses name i p width b)
      CIf c a b -> uses name i p width c && uses name i p width a && uses name i p width b
      _ -> case spine e of
        (CVar f,args@(_:_)) | f==name -> and [if j==i && a==CVar p then True else uses name i p width a | (j,a)<-zip [0..] args]
        _ -> all (uses name i p width) (children e)
    -- Bound both the source scan (8192 nodes, allowing record shape chains)
    -- and the actual cloned body (1024 nodes, including expanded forwarding).
    -- All selected calls remain saturated; at most 128 workers per unit.
    plans = M.fromList (take 128 (mapMaybe choose (M.toAscList prog)))
    additions = M.fromList [(worker,makeBody name ps b i tv width) |
                   (name,(i,tv,width,worker))<-M.toList plans, let (ps,b)=prog M.! name]
    makeBody name ps b i (t,v) width =
      let p=ps!!i; fields=[prefix++"field."++show k++"."++name | k<-[0..width-1]]
          params=take i ps++fields++drop (i+1) ps
      in (params,reduce (subst p (CMk t v (map CVar fields)) b))
    wrapped = M.mapWithKey (\name def@(ps,b) -> case M.lookup name plans of
      Nothing -> input M.! name
      Just (i,(t,v),width,worker) -> let p=CVar (ps!!i) in
        (ps,CIf (CTagEq t v p) (app worker (map CVar (take i ps)++[CProj k p | k<-[0..width-1]]++map CVar (drop (i+1) ps))) b)) prog
    combined = M.union wrapped additions
    -- Rewrite a complete spine once, preserving strict field/argument order.
    rewrite bound e = case spine e of
      (CVar f,args@(_:_)) | S.notMember f bound, Just (i,(t,v),width,worker) <- M.lookup f plans,
                           length args == length (fst (prog M.! f)),
                           CMk t' v' xs <- args!!i, (t,v)==(t',v'), length xs==width ->
          app worker (map (rewrite bound) (take i args++xs++drop (i+1) args))
      _ -> case e of
        CApp a b -> CApp (rewrite bound a) (rewrite bound b); CLet n a b -> CLet n (rewrite bound a) (rewrite (S.insert n bound) b)
        CIf a b c -> CIf (rewrite bound a) (rewrite bound b) (rewrite bound c)
        CMk t v xs -> CMk t v (map (rewrite bound) xs); CTagEq t v x -> CTagEq t v (rewrite bound x)
        CProj k x -> CProj k (rewrite bound x); _ -> e

scalarWorkers :: Prog -> (Prog,ScalarSignatures)
scalarWorkers prog = (M.union wrapped workers,M.mapKeys worker chosen)
  where
    -- The fragment has no allocation, managed projections, unknown callbacks
    -- or foreign calls. Bool values retain the normal immutable ABI.
    admissible bound e = case spine e of
      (CVar h,args@(_:_)) | not (S.member h bound),
        (M.member h prog && length args==length (fst (prog M.! h))) ||
        (M.notMember h prog && h `elem` ops && length args==2) -> all (admissible bound) args
      _ -> case e of
        CVar n -> S.member n bound; CInt _ -> True; CMk 1 _ [] -> True
        CTagEq 1 _ x -> admissible bound x
        CLet n a b -> admissible bound a && admissible (S.insert n bound) b
        CIf a b c -> all (admissible bound) [a,b,c]; CErr _ -> True; _ -> False
    calls ps b = S.fromList [h | e <- nodes b, let (head0,args)=spine e,
                           CVar h <- [head0], not (null args), h `notElem` ps, M.member h prog]
    nodes e = e : concatMap nodes (children e)
    blocked = vectorCallbacks prog
    candidates = M.fromList [(n,(ks,r)) | (n,(ps,b)) <- M.toAscList prog,
      S.notMember n blocked, not (null ps), length ps<=8, size b<=1024, admissible (S.fromList ps) b,
      Just (ks,r)<-[signatureStrict prog ps b], all (`elem` [KI,KB]) (r:ks), KI `elem` ks]
    closed set = let next=M.filterWithKey (\n _ -> let (ps,b)=prog M.! n in calls ps b `S.isSubsetOf` M.keysSet set) set
                 in if M.size next==M.size set then set else closed next
    -- Bound total cloned Core as well as count. Prune incomplete call graphs.
    budget _ [] = []
    budget left ((n,sig):rest) | cost<=left = (n,sig):budget (left-cost) rest
                             | otherwise = budget left rest
      where cost=size (snd (prog M.! n))
    eligible = closed candidates
    edges n = let (ps,b)=prog M.! n in calls ps b
    loops = S.fromList (concat [ns | CyclicSCC ns <- stronglyConnComp
              [(n,n,S.toList (edges n)) | n<-M.keys eligible]])
    reachable seen = let next=seen `S.union` S.unions (map edges (S.toList seen))
                     in if next==seen then seen else reachable next
    -- Entry guards amortize over loops. Do not add a worker/wrapper call to
    -- every tiny nonrecursive scalar helper in ordinary application code.
    chosen = closed (M.fromList (budget 20000 (take 128 (M.toAscList (M.restrictKeys eligible (reachable loops))))))
    worker n = prefix++"scalar."++n
    raw (CInt n) = app "$scalar.unbox" [CInt n]
    raw e = case spine e of
      (CVar h,args@(_:_)) | M.member h chosen -> app (worker h) (map raw args)
      (CVar h,[a,b]) | M.notMember h prog, h `elem` ops -> app ("$scalar."++h) [raw a,raw b]
      _ -> case e of
        CLet n a b -> CLet n (raw a) (raw b); CIf a b c -> CIf (raw a) (raw b) (raw c)
        CTagEq t v x -> CTagEq t v (raw x); _ -> e
    workers = M.fromList [(worker n,(ps,raw b)) | (n,_)<-M.toList chosen, let (ps,b)=prog M.! n]
    wrapped = M.mapWithKey (\n def@(ps,b) -> case M.lookup n chosen of
      Nothing -> def
      Just (ks,r) ->
        let boolValue p=CIf (CTagEq 1 1 (CVar p)) (CMk 1 1 []) (CMk 1 0 [])
            args=[if k==KI then app "$scalar.unbox" [CVar p] else boolValue p | (p,k)<-zip ps ks]
            result=app (worker n) args
            boxed=if r==KI then app "$scalar.box" [result] else result
            valid p KI=app "$scalar.isInt" [CVar p]
            valid p _=CIf (CTagEq 1 0 (CVar p)) (CMk 1 1 []) (CTagEq 1 1 (CVar p))
            -- Bool equality in a worker is pointer equality. Base codegen
            -- must emit these CMk Bools as the SAME runtime singletons used
            -- by comparisons, including across separately compiled units.
            condition=foldr (\(p,k) yes -> CIf (valid p k) yes (CMk 1 0 [])) (CMk 1 1 []) (zip ps ks)
            guarded=CIf condition boxed b
        in (ps,guarded)) prog
