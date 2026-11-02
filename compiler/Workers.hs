-- Private Base worker/wrapper conventions. Public arities and function values
-- stay general. This pass runs after all source safety/ownership checking.
module Workers (workerize, workerizeWithSignatures, workerizeWithOptions, ScalarSignatures, internalWorker, scalarPrimitives) where

import Core.Opt.Ticks (batchTicks)
import Core.Primitives (scalarPrimitives, entryTickName)
import Core.Syntax (Core(..), Prog)
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
mentions :: String -> Core -> Bool
mentions x (CVar y) = x == y
mentions x (CLet y a b) = mentions x a || (y /= x && mentions x b)
mentions x (CLam ps b) = x `notElem` ps && mentions x b
mentions x e = any (mentions x) (children e)
freeIn :: Core -> S.Set String
freeIn (CVar x) = S.singleton x
freeIn (CLet x a b) = freeIn a `S.union` S.delete x (freeIn b)
freeIn (CLam ps b) = foldr S.delete (freeIn b) ps
freeIn e = S.unions (map freeIn (children e))
boundIn :: Core -> S.Set String
boundIn (CLet x a b) = S.insert x (boundIn a `S.union` boundIn b)
boundIn (CLam ps b) = S.fromList ps `S.union` boundIn b
boundIn e = S.unions (map boundIn (children e))
deadBranch :: Core -> Bool
deadBranch (CErr _) = True
deadBranch (CLet _ _ b) = deadBranch b
deadBranch _ = False
ctorTags :: Core -> S.Set (Int,Int)
ctorTags (CMk t v xs) | not (null xs) = S.singleton (t,v)
ctorTags (CLet _ _ b) = ctorTags b
ctorTags (CIf _ a b) = ctorTags a `S.union` ctorTags b
ctorTags _ = S.empty
isCtorTree :: Maybe String -> (Int,Int) -> Int -> Core -> Bool
isCtorTree mp (t,v) width = go
  where
    go (CMk t' v' xs) = (t,v)==(t',v') && length xs==width
    go (CVar x) = Just x == mp
    go (CLet _ _ b) = go b
    go (CIf _ a b) = branch a && branch b && not (deadBranch a && deadBranch b)
    go _ = False
    branch e = deadBranch e || go e
usedOnlyAsRecArg :: String -> String -> Core -> Bool
usedOnlyAsRecArg name x = go False
  where
    go seen e = case spine e of
      (CVar f, args@(_ : _))
        | f == name ->
            let hits = length [() | CVar y <- args, y == x]
                otherUses = any (\a -> a /= CVar x && mentions x a) args
             in hits <= 1 && not otherUses && (seen || hits == 1)
      _ -> case e of
        CLet y a b
          | y == x -> not (mentions x a) && seen
          | otherwise -> not (mentions x a) && go seen b
        CIf c t f ->
          not (mentions x c)
            && (go seen t || (deadBranch t && not (mentions x t)))
            && (go seen f || (deadBranch f && not (mentions x f)))
            && (mentions x t || mentions x f)
        _ -> False
prepRecArgLets :: String -> [String] -> Core -> Core
prepRecArgLets name ps = go
  where
    paramSet = S.fromList ps
    go e = case e of
      CLet n a b ->
        let a' = go a
            b' = go b
         in if not (rebinds n b') && usedOnlyAsRecArg name n b' && not (S.null (ctorTags a'))
              then floatLet n a' b'
              else CLet n a' b'
      CApp a b -> CApp (go a) (go b)
      CIf c t f -> CIf (go c) (go t) (go f)
      CMk t v xs -> CMk t v (map go xs)
      CTagEq t v x -> CTagEq t v (go x)
      CProj k x -> CProj k (go x)
      CLam qs x -> CLam qs (go x)
      _ -> e
    floatLet n a b = case a of
      CLet m x y | m /= n, not (mentions m b) ->
        CLet m x (floatLet n y b)
      CIf cond t f | deadBranch f ->
        CIf cond (floatLet n t b) f
      CIf cond t f | deadBranch t ->
        CIf cond t (floatLet n f b)
      CIf cond t f
        | not (S.null (ctorTags t)) || isParamVar t,
          not (S.null (ctorTags f)) || isParamVar f,
          size b <= 64 ->
            CIf cond (floatLet n t b) (floatLet n f b)
      CMk t v xs | length xs >= 2, length xs <= 64 ->
        let fields = [prefix ++ "let." ++ show k ++ "." ++ n | k <- [0 .. length xs - 1]]
            b' = subst n (CMk t v (map CVar fields)) b
         in foldr (uncurry CLet) b' (zip fields xs)
      CVar p | S.member p paramSet ->
        subst n (CVar p) b
      _ -> CLet n a b
    isParamVar (CVar p) = S.member p paramSet
    isParamVar _ = False
reduce :: Core -> Core
reduce = walk $ \e -> case e of
  CProj k (CMk _ _ xs) | k >= 0, k < length xs, all fieldVar xs -> xs !! k
  CTagEq t v (CMk t' v' xs) | all fieldVar xs -> CMk 1 (if (t,v)==(t',v') then 1 else 0) []
  CIf (CMk 1 1 []) a _ -> a
  CIf (CMk 1 0 []) _ b -> b
  _ -> e
  where fieldVar (CVar n) = (prefix++"field.") `isPrefixOf` n || (prefix++"let.") `isPrefixOf` n
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
                 in if next==seen then next else close next

workerize :: Bool -> Bool -> Prog -> (Prog,[String])
workerize fields scalars prog =
  let (p, notes, _) = workerizeWithSignatures fields scalars True prog
  in (p, notes)

-- Ordered parameter/result representations, recorded when the worker is
-- chosen. Consumers must not infer this ABI from an already-rewritten body.
type ScalarSignatures = M.Map String ([Kind], Kind)

-- `batch` (FPR_NO_TICK_BATCH=1 turns it off): see `batchTicks`.
workerizeWithSignatures :: Bool -> Bool -> Bool -> Prog -> (Prog,[String],ScalarSignatures)
workerizeWithSignatures fields scalars batch prog =
  workerizeWithOptions fields True scalars batch prog

workerizeWithOptions :: Bool -> Bool -> Bool -> Bool -> Prog -> (Prog,[String],ScalarSignatures)
workerizeWithOptions fields tupleScalars scalars batch prog =
  let (p,nf) = if fields then fieldWorkers tupleScalars prog else (prog,0)
      (q,sigs) = if scalars then scalarWorkers batch p else (p,M.empty)
  in (q,["# private workers: fields="++show nf++" scalar="++show (M.size sigs)],sigs)

-- Fixed-width constructor parameters. The expanded arity must fit the native
-- ABI (8 registers plus 56 per-hart spill cells). Whole-value uses must
-- forward to the same recursive parameter. Returning the original accumulator
-- would require a new allocation at a general entry, so it stays general too.
-- When tupleScalars is enabled (default; FPR_NO_TUPLE_SCALARS=1 disables),
-- recursive arguments may also be let/if trees ending in constructors (such as
-- an inlined step helper after CaseKnown), and multiple tuple/record parameters
-- unbox across successive rounds.
fieldWorkers :: Bool -> Prog -> (Prog,Int)
fieldWorkers tupleScalars input
  | not tupleScalars = let (p,added) = fieldWorkersStep False S.empty input in (p,S.size added)
  | otherwise = go (4 :: Int) S.empty 0 input
  where
    go 0 _ total prog = (prog,total)
    go rounds allowed total prog =
      let (prog',added) = fieldWorkersStep True allowed prog
       in if S.null added
            then (prog',total)
            else go (rounds - 1) added (total + S.size added) prog'

fieldWorkersStep :: Bool -> S.Set String -> Prog -> (Prog,S.Set String)
fieldWorkersStep tupleScalars allowedWorkers input =
  (M.map (\(ps,b)->(ps,rewrite (S.fromList ps) b)) combined,M.fromList [(w,()) | (_,(_,_,_,w))<-M.toList plans] `seq` S.fromList [w | (_,(_,_,_,w))<-M.toList plans])
  where
    prep name (ps,b) =
      let b0 = aliases (S.fromList ps) b
       in (ps,if tupleScalars then aliases (S.fromList ps) (prepRecArgLets name ps b0) else b0)
    prog = M.mapWithKey prep input
    arities = M.fromListWith S.union [( (t,v), S.singleton (length xs)) |
                 (_,(_,b)) <- M.toList prog, CMk t v xs <- nodes b]
    nodes e = e : concatMap nodes (children e)
    blocked = vectorCallbacks prog
    eligibleName name
      | S.null allowedWorkers = not (internalWorker name)
      | otherwise = S.member name allowedWorkers
    choose (name,(ps,b))
      | S.member name blocked = Nothing
      | null ps || length ps > 64 || size b > 8192 || not (eligibleName name) = Nothing
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
                                f==name, length args==length ps,
                                (t,v)<-if tupleScalars then S.toList (ctorTags (args!!i))
                                       else [(t,v) | CMk t v _ <- [args!!i]]]
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
         not (any (recursive name (length ps) i p tv width) (nodes narrowed))
        then Nothing else Just (i,tv,width)
    narrow p tv = walk $ \e -> case e of
      CTagEq t v (CVar x) | x==p -> CMk 1 (if tv==(t,v) then 1 else 0) []
      CIf (CMk 1 1 []) a _ -> a
      CIf (CMk 1 0 []) _ b -> b
      _ -> e
    recursive name arity i p (t,v) width e = case spine e of
      (CVar f,args) | f==name, length args==arity ->
        if tupleScalars
          then not (S.null (ctorTags (args!!i))) && isCtorTree (Just p) (t,v) width (args!!i)
          else case args!!i of CMk t' v' xs -> (t,v)==(t',v') && length xs==width; _ -> False
      _ -> False
    uses name i p width e = case e of
      CVar x | x==p -> False
      CProj k (CVar x) | x==p -> k >= 0 && k < width
      CTagEq _ _ (CVar x) | x==p -> True
      CLet x a b -> uses name i p width a && (x==p || uses name i p width b)
      CIf c a b -> uses name i p width c && uses name i p width a && uses name i p width b
      _ -> case spine e of
        (CVar f,args@(_:_)) | f==name ->
          and [if j==i then usesArg name i p width a else uses name i p width a | (j,a)<-zip [0..] args]
        _ -> all (uses name i p width) (children e)
    usesArg name i p width a
      | a == CVar p = True
      | not tupleScalars = uses name i p width a
      | otherwise = case a of
          CLet x rhs body -> uses name i p width rhs && (x==p || usesArg name i p width body)
          CIf c t f -> uses name i p width c && usesArg name i p width t && usesArg name i p width f
          _ -> uses name i p width a
    -- Bound both the source scan (8192 nodes, allowing record shape chains)
    -- and the actual cloned body (1024 nodes, including expanded forwarding).
    -- All selected calls remain saturated; at most 128 workers per unit.
    plans = M.fromList (take 128 (mapMaybe choose (M.toAscList prog)))
    additions = M.fromList [(worker,makeBody name ps b i tv width) |
                   (name,(i,tv,width,worker))<-M.toList plans, let (ps,b)=prog M.! name]
    makeBody name ps b i (t,v) width =
      let p=ps!!i; fields=[prefix++"field."++show k++"."++name | k<-[0..width-1]]
          params=take i ps++fields++drop (i+1) ps
          body0=reduce (subst p (CMk t v (map CVar fields)) b)
          body1=if tupleScalars then aliases (S.fromList params) body0 else body0
      in (params,body1)
    wrapped = M.mapWithKey (\name (ps,b) -> case M.lookup name plans of
      Nothing -> input M.! name
      Just (i,(t,v),width,worker) -> let p=CVar (ps!!i) in
        (ps,CIf (CTagEq t v p) (app worker (map CVar (take i ps)++[CProj k p | k<-[0..width-1]]++map CVar (drop (i+1) ps))) (snd (input M.! name)))) prog
    combined = M.union wrapped additions
    -- Rewrite a complete spine once, preserving strict field/argument order.
    rewrite bound e = case spine e of
      (CVar f,args@(_:_)) | S.notMember f bound, Just (i,(t,v),width,worker) <- M.lookup f plans,
                           length args == length (fst (prog M.! f)) ->
        case args!!i of
          CMk t' v' xs | (t,v)==(t',v') && length xs==width ->
            app worker (map (rewrite bound) (take i args++xs++drop (i+1) args))
          argI | tupleScalars,
                 let argI' = rewrite bound argI
                     before = map (rewrite bound) (take i args)
                     after = map (rewrite bound) (drop (i+1) args),
                 isCtorTree Nothing (t,v) width argI',
                 S.null (boundIn argI' `S.intersection` S.unions (map freeIn after)) ->
            pushCall f worker before argI' after
          _ -> rewriteChildren bound e
      _ -> rewriteChildren bound e
    rewriteChildren bound e = case e of
      CApp a b -> CApp (rewrite bound a) (rewrite bound b)
      CLet n a b -> CLet n (rewrite bound a) (rewrite (S.insert n bound) b)
      CIf a b c -> CIf (rewrite bound a) (rewrite bound b) (rewrite bound c)
      CMk t v xs -> CMk t v (map (rewrite bound) xs)
      CTagEq t v x -> CTagEq t v (rewrite bound x)
      CProj k x -> CProj k (rewrite bound x)
      _ -> e
    pushCall f worker before argI after =
      let avoid = boundIn argI `S.union` S.unions (map freeIn (before ++ after))
          freshArg idx = head [n | k <- [idx, idx + 100 ..], let n = prefix ++ "arg." ++ show k ++ "." ++ f, S.notMember n avoid]
          bindBefore (idx, a)
            | isTrivial a && S.null (boundIn argI `S.intersection` freeIn a) = (id, a)
            | otherwise = let tmp = freshArg idx in (CLet tmp a, CVar tmp)
          (wraps, beforeVars) = unzip (map bindBefore (zip [0 :: Int ..] before))
          push (CMk _ _ xs) = app worker (beforeVars ++ xs ++ after)
          push (CLet n a b) = CLet n a (push b)
          push (CIf c a b) = CIf c (push a) (push b)
          push other = other
       in foldr ($) (push argI) wraps
    isTrivial (CInt _) = True
    isTrivial (CStr _) = True
    isTrivial (CMk _ _ []) = True
    isTrivial (CVar _) = True
    isTrivial _ = False

scalarWorkers :: Bool -> Prog -> (Prog,ScalarSignatures)
scalarWorkers batch prog = (M.union wrapped workers,M.mapKeys worker chosen)
  where
    -- The fragment has no allocation, managed projections, unknown callbacks
    -- or foreign calls. Bool values retain the normal immutable ABI.
    admissible bound e = case spine e of
      (CVar h,args@(_:_)) | not (S.member h bound),
        (M.member h prog && length args==length (fst (prog M.! h))) ||
        (M.notMember h prog && h `elem` ops && length args==2) -> all (admissible bound) args
      -- An inlined callee's entry tick stays in place; it touches no value.
      (CVar h,[CInt _]) | h == entryTickName -> True
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
                     in if next==seen then next else reachable next
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
    workers = M.fromList [(worker n,(ps,tickPolicy n (raw b))) | (n,_)<-M.toList chosen, let (ps,b)=prog M.! n]
    -- One fuel tick per loop iteration: a worker that calls itself keeps its
    -- own entry tick (every iteration, and every entry, still ticks once);
    -- the ticks of callees inlined into its body are dropped (Core.Opt.Ticks).
    tickPolicy n b | batch && S.member n (edges n) = batchTicks b
                   | otherwise = b
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

-- `batchTicks` (Core.Opt.Ticks) drops the inlined callees' entry ticks from a
-- scalar worker that calls itself; the worker's own entry tick is emitted by
-- codegen and remains. The same rule reaches non-worker self loops as its own
-- pipeline pass.
