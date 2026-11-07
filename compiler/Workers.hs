-- Private Base worker/wrapper conventions. Public arities and function values
-- stay general. This pass runs after all source safety/ownership checking.
module Workers (workerize, workerizeWithSignatures, workerizeWithOptions, workerizeWithProducts, ScalarSignatures, internalWorker, scalarPrimitives,
               Agreement(..), scalarWorkersWith) where

import Codegen.IR (arityCeiling)
import Core.Primitives (scalarPrimitives, entryTickName)
import Core.Syntax (Core(..), Prog)
import Core.Opt.ProductParameters
import KernelKinds (Kind(..), componentSignatures)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (foldl',isPrefixOf,sortOn)
import Data.Maybe (mapMaybe)
import Data.Graph (SCC(..), flattenSCC, stronglyConnComp)

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
usedOnlyAsCallArg :: (String -> Bool) -> String -> Core -> Bool
usedOnlyAsCallArg selected x body = mentions x body && go body
  where
    go e | not (mentions x e) = True
    go e = case spine e of
      (CVar f, args@(_ : _))
        | selected f ->
            let hits = length [() | CVar y <- args, y == x]
                otherUses = any (\a -> a /= CVar x && mentions x a) args
             in hits == 1 && not otherUses
      _ -> case e of
        CLet y a b
          | y == x -> not (mentions x a)
          | otherwise -> not (mentions x a) && go b
        CIf c t f ->
          not (mentions x c)
            && go t && go f
        -- Region adapters may surround the selected call. Its arguments are
        -- still evaluated in place; only the fresh seed's box disappears.
        CApp f a -> go f && go a
        _ -> False
prepRecArgLets :: String -> [String] -> Core -> Core
prepRecArgLets name=prepCallArgLets (==name)
prepCallArgLets :: (String -> Bool) -> [String] -> Core -> Core
prepCallArgLets selected ps = go
  where
    paramSet = S.fromList ps
    go e = case e of
      CLet n a b ->
        let a' = go a
            b' = go b
         -- Most lets bind scalar computations. Reject those before scanning
         -- their entire continuation for capture and single-call use; repeated
         -- field expansion otherwise pays that scan at every worker round.
         in if not (S.null (ctorTags a')) && not (rebinds n b') && usedOnlyAsCallArg selected n b'
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
      CMk t v xs | not (null xs), length xs <= 64 ->
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
  let (p, notes, _) = workerizeWithSignatures fields scalars prog
  in (p, notes)

-- Ordered parameter/result representations, recorded when the worker is
-- chosen. Consumers must not infer this ABI from an already-rewritten body.
type ScalarSignatures = M.Map String ([Kind], Kind)

-- A worker's fuel ticks are placed after lowering (Codegen.Placement).
workerizeWithSignatures :: Bool -> Bool -> Prog -> (Prog,[String],ScalarSignatures)
workerizeWithSignatures fields scalars prog =
  workerizeWithOptions fields True scalars prog

workerizeWithOptions :: Bool -> Bool -> Bool -> Prog -> (Prog,[String],ScalarSignatures)
workerizeWithOptions=workerizeWithProducts emptyProductParameters

workerizeWithProducts :: ProductParameters -> Bool -> Bool -> Bool -> Prog -> (Prog,[String],ScalarSignatures)
workerizeWithProducts products fields tupleScalars scalars prog =
  let (p,nf,fieldNotes) = if fields then fieldWorkers products tupleScalars prog else (prog,0,[])
      (q,sigs,bridge) = if scalars then scalarWorkers (checkedKinds p products) p else (p,M.empty,noAgreement)
  -- forced with the result, so the agreement check runs whether or not the
  -- notes are printed
  in bridge `seq` (q,["# private workers: fields="++show nf++" scalar="++show (M.size sigs)]
        ++ [bridgeNote bridge | scalars] ++ fieldNotes, sigs)

-- P2 signature bridge (docs/2026-11-08-P2-SIGNATURE-BRIDGE.md). Slice 2: a
-- scalar worker's signature comes from its checked interface. KernelKinds
-- still solves the same component from erased Core, as an assertion:
--   agreed      the checked kinds give the signature and KernelKinds agrees;
--   guarded     a member's checked type is not all raw words (a type
--               variable, say), so KernelKinds' solution is used, and it must
--               agree with every checked raw position; the wrapper's runtime
--               test still selects the general body (semantic policy Rule 2);
--   unchecked   no checked interface: KernelKinds' solution is used;
--   checkedOnly the checked kinds admit a component KernelKinds declines. Not
--               admitted in this slice, so generated code keeps its shape
--               (the roadmap reviews representation changes separately).
-- A disagreement on a checked raw position stops the compile.
data Agreement = Agreement { agreed :: !Int, guarded :: !Int, unchecked :: !Int, checkedOnly :: !Int }

noAgreement :: Agreement
noAgreement = Agreement 0 0 0 0

-- Every position the checked interface fixes must match KernelKinds' kind.
-- Right True: every position is checked. Right False: some are not raw words.
agreeWith :: CheckedKinds -> String -> ([Kind], Kind) -> Either String Bool
agreeWith checked name (ks, r) = case M.lookup name checked of
  Just (cks, cr) | length cks == length ks ->
    let positions = zip (cr : cks) (r : ks)
    in if or [c /= k | (Just c, k) <- positions]
         then Left ("signature bridge: KernelKinds solved " ++ show (ks, r) ++ " for " ++ name
                    ++ " but its checked interface says " ++ show (cks, cr))
         else Right (all ((/= Nothing) . fst) positions)
  _ -> Right False

-- For tests: the scalar worker pass with explicit checked kinds.
scalarWorkersWith :: CheckedKinds -> Prog -> (Prog,ScalarSignatures,Agreement)
scalarWorkersWith = scalarWorkers

bridgeNote :: Agreement -> String
bridgeNote a = "# signature bridge: agreed=" ++ show (agreed a) ++ " guarded=" ++ show (guarded a)
  ++ " unchecked=" ++ show (unchecked a) ++ " checked_only=" ++ show (checkedOnly a)

-- Successive field plans need not publish a quadratic chain of general
-- fallback bodies. A generated guard entry used ONLY by its parent can join
-- that parent's guard. The parent's original fallback remains authoritative:
-- under the parent guard, the child's fallback is its field-expanded body.
-- Keep each removed entry's fuel tick, evaluated only when its parent guard
-- succeeds. No arbitrary function, escape, recursive worker or effectful
-- argument can supply this provenance.
coalesceFieldGuards :: M.Map String String -> Prog -> (Prog,Int)
coalesceFieldGuards lineages input=foldl combine (input,0) (sortOn length (M.keys input))
  where
    descends child parent=go S.empty child
      where
        go seen name | S.member name seen=False
        go seen name=case M.lookup name lineages of
          Just source->source==parent || go (S.insert name seen) source
          Nothing->False
    references=M.fromListWith (+) [(n,1::Int) | (_,body)<-M.elems input,CVar n<-nodes body]
    nodes e=e:concatMap nodes (children e)
    projection ps e=case e of
      CVar n->n `elem` ps
      CProj k a->k>=0 && projection ps a
      _->False
    guard ps e=case e of
      CTagEq _ _ a->projection ps a
      CMk 1 v []->v==0 || v==1
      CIf c a b->all (guard ps) [c,a,b]
      CLet n (CApp (CVar tick) (CInt 0)) b->tick==entryTickName && not (mentions n b) && guard ps b
      _->False
    combine (prog,removed) name=case M.lookup name prog of
      Just (ps,CIf condition yes fallback)
        | guard ps condition,
          (CVar child,args)<-spine yes,
          descends child name,M.lookup child references==Just 1,
          Just (qs,CIf childCondition childYes _)<-M.lookup child prog,
          length args==length qs,all (projection ps) args,guard qs childCondition,
          (CVar grand,grandArgs)<-spine childYes,descends grand child,
          all (projection qs) grandArgs ->
            let substitution=M.fromList (zip qs args)
                instantiate=walk (\e->case e of CVar n->M.findWithDefault e n substitution;_->e)
                tickName=prefix++"guard.tick."++child
                condition'=CIf condition
                  (CLet tickName (app entryTickName [CInt 0]) (instantiate childCondition)) (CMk 1 0 [])
                body=CIf condition' (app grand (map instantiate grandArgs)) fallback
                next=M.insert name (ps,body) (M.delete child prog)
            in combine (next,removed+1) name
      _->(prog,removed)

-- Fixed-width constructor parameters. The expanded arity must fit the native
-- ABI (8 registers plus 56 per-hart spill cells). Whole-value uses must
-- forward to the same recursive parameter. Returning the original accumulator
-- would require a new allocation at a general entry, so it stays general too.
-- When tupleScalars is enabled (default; FPR_NO_TUPLE_SCALARS=1 disables),
-- recursive arguments may also be let/if trees ending in constructors (such as
-- an inlined step helper after CaseKnown), and multiple tuple/record parameters
-- unbox across successive rounds.
-- One-field wrappers use the same guarded entry and boxed escape convention;
-- their payload remains an ordinary Base value, including heap references.
-- A finite rank of observed parameter paths, not a cloning/depth budget.
-- Aliases and projection-bound lets preserve the root parameter. Duplicating
-- a branch does not create a new path; unknown calls/joins supply no evidence.
-- Every admitted round maps each source to at most one child, never increases
-- a child's rank, and strictly decreases the sum across the new frontier.
projectionRank :: [String] -> Core -> Int
projectionRank ps body = sum [length path | (_,path)<-S.toList (visit initial body)]
  where
    initial=M.fromList [(p,(i,[])) | (i,p)<-zip [0::Int ..] ps]
    path env e=case e of
      CVar n->M.lookup n env
      CProj k x->do (root,indices)<-path env x;pure (root,indices++[k])
      _->Nothing
    visit env e=case e of
      CLet n a b->visit env a `S.union` visit
        (maybe (M.delete n env) (\p->M.insert n p env) (path env a)) b
      CLam ns b->visit (foldr M.delete env ns) b
      _->let here=case e of CProj _ _->maybe S.empty S.singleton (path env e);_->S.empty
         in here `S.union` S.unions (map (visit env) (children e))

fieldWorkers :: ProductParameters -> Bool -> Prog -> (Prog,Int,[String])
fieldWorkers products tupleScalars input
  | not tupleScalars = let (p,added,_) = fieldWorkersStep products False S.empty input in (p,M.size added,[])
  | otherwise = go products S.empty 0 0 M.empty input
  where
    summary removed=["# private field guards coalesced: "++show removed | removed>0]
    go evidence allowed total removed lineages prog =
      let (prog',added,evidence') = fieldWorkersStep evidence True allowed prog
          transitions=[(projectionRank ps body,projectionRank qs after) |
            (worker,source)<-M.toList added,
            Just (ps,body)<-[M.lookup source prog],Just (qs,after)<-[M.lookup worker prog']]
          finite=length transitions==M.size added && all (uncurry (>=)) transitions &&
            sum (map snd transitions)<sum (map fst transitions)
       in if M.null added then (prog,total,summary removed)
          else if finite then
            let lineages'=M.union added lineages
                (compact,discarded)=coalesceFieldGuards lineages' prog'
            in go evidence' (M.keysSet added) (total+M.size added-discarded) (removed+discarded) lineages' compact
          else (prog,total,summary removed++["# private field workers: declined round without decreasing structural projection-path rank"])

fieldWorkersStep :: ProductParameters -> Bool -> S.Set String -> Prog -> (Prog,M.Map String String,ProductParameters)
fieldWorkersStep products tupleScalars allowedWorkers input =
  (M.map (\(ps,b)->(ps,rewrite (S.fromList ps) (if tupleScalars && not (M.null plans) then prepCallArgLets (`M.member` plans) ps (aliases (S.fromList ps) b) else b))) combined,
   M.fromList [(w,n) | (n,(_,_,_,w))<-M.toList plans],
   M.foldlWithKey' transport products plans)
  where
    prep name (ps,b) =
      let b0 = aliases (S.fromList ps) b
       in (ps,if tupleScalars then aliases (S.fromList ps) (prepRecArgLets name ps b0) else b0)
    prog = M.mapWithKey prep input
    arities = M.fromListWith S.union [( (t,v), S.singleton (length xs)) |
                 (_,(_,b)) <- M.toList prog, CMk t v xs <- nodes b]
    nodes e = e : concatMap nodes (children e)
    blocked = vectorCallbacks prog
    -- Only pay for a new nonrecursive entry when this artifact contains a
    -- constructor call it can remove. This scan is lexical, including strict
    -- let-bound constructors; the existing rewrite separately proves movement.
    supplied = S.unions [sites (S.fromList ps) M.empty b | (ps,b)<-M.elems prog]
    sites bound known e = case e of
      CLet n a b -> sites bound known a `S.union`
        sites (S.insert n bound) (case shapeOf known a of
          Just s | not (rebinds n b), usedOnlyAsCallArg (`M.member` prog) n b->M.insert n s known
          _->M.delete n known) b
      CLam ps b->sites (bound `S.union` S.fromList ps) (foldr M.delete known ps) b
      _ -> let here=case spine e of
                 (CVar f,args) | f `S.notMember` bound,Just (ps,_)<-M.lookup f prog,length args==length ps ->
                   S.fromList [(f,i,s) | (i,a)<-zip [0..] args,Just s<-[shapeOf known a]]
                 _->S.empty
           in here `S.union` S.unions (map (sites bound known) (children e))
    shapeOf known e=case e of
      CMk t v xs->Just (t,v,length xs)
      CVar x->M.lookup x known
      CLet n a b->shapeOf (case shapeOf known a of Just s->M.insert n s known;Nothing->M.delete n known) b
      CIf _ a b->do x<-shapeOf known a;y<-shapeOf known b;if x==y then Just x else Nothing
      _->Nothing
    eligibleName name
      | S.null allowedWorkers = not (internalWorker name)
      | otherwise = S.member name allowedWorkers
    choose (name,(ps,b))
      | S.member name blocked = Nothing
      | null ps || length ps > arityCeiling || not (eligibleName name) = Nothing
      | otherwise = case mapMaybe (candidate name ps b) [(i,p) | (i,p)<-zip [0..] ps,S.member p projected] of
          (i,tv,width):_ -> Just (name,(i,tv,width,prefix++"fields."++name))
          _ -> Nothing
      where
        -- A projection is already a mandatory admission condition. Index it
        -- once, rather than rescanning tags/recursive calls for every scalar
        -- parameter introduced by earlier rounds of a wide product plan.
        projected=S.fromList [p | CProj _ (CVar p)<-nodes b]
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
          checked=parameterProduct products name ps i
      (tv,width) <- case checked of
        Just (t,v,w) | maybe True (==S.singleton w) (M.lookup (t,v) arities)->Just ((t,v),w)
        Just _->Nothing
        Nothing->do
          tv<-case (S.toList rebuilt,S.toList tags) of
            ([one],_)->Just one
            (_,[one])->Just one
            _->Nothing
          width<-case M.lookup tv arities of
            Just widths | [n]<-S.toList widths->Just n
            _->Nothing
          Just (tv,width)
      -- Discard only branches excluded by the guarded constructor shape.
      -- A shared record field can have different offsets in other shapes;
      -- those unreachable projections must not veto this worker.
      let narrowed = narrow p tv b
          projections = [k | CProj k (CVar x) <- nodes narrowed, x==p]
      if width < 1 || length ps - 1 + width > arityCeiling || null projections ||
         any (\k -> k < 0 || k >= width) projections ||
         name `elem` ps || rebinds name b || rebinds p b ||
         not ((if tupleScalars then usesTail else uses) name i p width narrowed) ||
         not (any (recursive name (length ps) i p tv width) (nodes narrowed) ||
              (tupleScalars && checked/=Nothing &&
               not (mentions name b) && S.member (name,i,(fst tv,snd tv,width)) supplied))
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
    -- Returning the accumulator is a boundary, not an observation inside the
    -- loop. The field worker reconstructs it once at that exit; unknown calls,
    -- captures and whole-value uses in operands still decline.
    usesTail name i p width e=case e of
      CVar x | x==p->True
      CLet x a b->uses name i p width a && (x==p || usesTail name i p width b)
      CIf c a b->uses name i p width c && usesTail name i p width a && usesTail name i p width b
      _->uses name i p width e
    -- Every source contributes at most one entry to this finite round.
    -- The outer driver proves progress before publishing it. Target arity and
    -- final image admission, plus compiler-cost gates, bound resource use.
    loopPlans = M.fromList (mapMaybe choose (M.toAscList prog))
    plans = if tupleScalars then forwardPlans loopPlans else loopPlans
    forwarding = [(name,ps,b,sites) | (name,(ps,b))<-M.toAscList prog,
      eligibleName name,name `S.notMember` blocked,not (null ps),length ps<=arityCeiling,
      let sites=[(f,args) | e<-nodes b,(CVar f,args@(_:_))<-[spine e],
                    Just (qs,_)<-[M.lookup f prog],length args==length qs],
      not (any ((==name) . fst) sites)]
    -- Monotonically add original names, never generated names, within this
    -- round. No fixed chain length or helper count can truncate the closure.
    forwardPlans known
      | M.null known=known
      | otherwise=
          let added=M.fromList (mapMaybe (chooseForward known) forwarding)
          in if M.null added then known else forwardPlans (known `M.union` added)
    chooseForward known (name,ps,b,sites)
      | M.member name known || not (any (\(f,_)->M.member f known) sites)=Nothing
      | not (S.null (M.keysSet known `S.intersection` (S.fromList ps `S.union` boundIn b)))=Nothing
      | otherwise=case mapMaybe candidateForward [(i,p) | (i,p)<-zip [0..] ps,S.member p forwarded] of
          (i,tv,width):_->Just (name,(i,tv,width,prefix++"fields."++name))
          _->Nothing
      where
        forwarded=S.fromList [p | (f,args)<-sites,Just (i,_,_,_)<-[M.lookup f known],CVar p<-[args!!i]]
        candidateForward (i,p)=do
          (tv,width)<-case S.toList (S.fromList [(shape,w) | (f,args)<-sites,
            Just (j,shape,w,_)<-[M.lookup f known],args!!j==CVar p]) of
              [shape]->Just shape
              _->Nothing
          let body=narrow p tv b
          if length ps-1+width>arityCeiling || rebinds p b ||
             not (forwardUses known p tv width True body)
            then Nothing else Just (i,tv,width)
    forwardUses known p tv width tailPosition e=case e of
      CVar x | x==p->tailPosition
      CProj k (CVar x) | x==p->k>=0 && k<width
      CTagEq _ _ (CVar x) | x==p->True
      CLet x a b->plain a && (x==p || forwardUses known p tv width tailPosition b)
      CIf c a b->plain c && forwardUses known p tv width tailPosition a && forwardUses known p tv width tailPosition b
      _->case spine e of
        (CVar f,args@(_:_)) | Just (i,shape,w,_)<-M.lookup f known,
          shape==tv,w==width,length args==length (fst (prog M.! f))->
            and [if j==i then argument a else plain a | (j,a)<-zip [0..] args]
        _->all plain (children e)
      where
        plain=forwardUses known p tv width False
        argument a=case a of
          CVar x | x==p->True
          CLet x rhs b->plain rhs && (x==p || argument b)
          CIf c a b->plain c && argument a && argument b
          _->plain a
    transport evidence name (i,(t,v),width,worker)=
      expandProductParameter name (fst (prog M.! name)) worker (fst (additions M.! worker)) i (t,v,width) evidence
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

scalarWorkers :: CheckedKinds -> Prog -> (Prog,ScalarSignatures,Agreement)
scalarWorkers checked prog = (M.union wrapped workers,M.mapKeys worker chosen,bridge)
  where
    -- The fragment has no allocation, managed projections, unknown callbacks
    -- or foreign calls. Bool values retain the normal immutable ABI.
    dependencies bound e = case spine e of
      (CVar h, args@(_:_)) | S.notMember h bound,
        Just (params, _) <- M.lookup h prog, length args == length params,
        S.notMember (worker h) bound -> S.insert h <$> arguments args
      (CVar h, [a,b]) | S.notMember h bound, M.notMember h prog, h `elem` ops -> arguments [a,b]
      (CVar h, [CInt _]) | h == entryTickName, S.notMember h bound -> Just S.empty
      _ -> case e of
        CVar n | S.member n bound -> Just S.empty
        CInt _ -> Just S.empty
        CMk 1 _ [] -> Just S.empty
        CTagEq 1 _ x -> dependencies bound x
        CLet n a b -> S.union <$> dependencies bound a <*> dependencies (S.insert n bound) b
        CIf c a b -> arguments [c,a,b]
        CErr _ -> Just S.empty
        _ -> Nothing
      where arguments xs = S.unions <$> traverse (dependencies bound) xs

    blocked = vectorCallbacks prog
    candidate n (ps,b)
      | S.member n blocked || null ps || length ps > arityCeiling || M.member (worker n) prog = Nothing
      | otherwise = dependencies (S.fromList ps) b
    graph = M.mapMaybeWithKey candidate prog
    edges n = graph M.! n
    components = stronglyConnComp [(n,n,S.toList callees) | (n,callees) <- M.toAscList graph]

    -- Process recursive components together, with callees first. A loop
    -- that reaches a foreign, unsupported or untyped callee stays general.
    closed allowed = foldl' keep S.empty components
      where
        keep accepted component
          | members `S.isSubsetOf` allowed && external `S.isSubsetOf` accepted = S.union members accepted
          | otherwise = accepted
          where members = S.fromList (flattenSCC component)
                external = S.unions (map edges (S.toList members)) `S.difference` members
    eligible = closed (M.keysSet graph)
    loops = [n | CyclicSCC ns <- components, n <- ns, S.member n eligible]
    reachable seen [] = seen
    reachable seen (n:rest)
      | S.member n seen = reachable seen rest
      | otherwise = reachable (S.insert n seen) (S.toList (edges n) ++ rest)

    -- Solve kinds only for functions used by eligible scalar loops. Each
    -- source has one worker at most. The hosted compiler-cost gate applies
    -- regardless of function names, body size or the number of peers.
    wanted = reachable S.empty loops
    (signatures, bridge) = foldl' solve (M.empty, noAgreement) components
    solve (known, b) component
      | S.disjoint members wanted = (known, b)
      | M.size imports /= S.size external = (known, b)
      | otherwise = case (fromChecked, inferred) of
          (Just sigs, Just ks)
            | sigs == ks -> (M.union sigs known, b { agreed = agreed b + M.size sigs })
            | otherwise -> error ("signature bridge: KernelKinds solved " ++ show ks
                                  ++ " but the checked interfaces say " ++ show sigs)
          (Just sigs, Nothing) -> (known, b { checkedOnly = checkedOnly b + M.size sigs })
          (Nothing, Just ks) -> case traverse (uncurry (agreeWith checked)) (M.toList ks) of
            Left err -> error err
            Right _
              | any (`M.member` checked) names -> (M.union ks known, b { guarded = guarded b + M.size ks })
              | otherwise -> (M.union ks known, b { unchecked = unchecked b + M.size ks })
          (Nothing, Nothing) -> (known, b)
      where names = flattenSCC component
            members = S.fromList names
            external = S.unions (map edges names) `S.difference` members
            imports = M.restrictKeys known external
            scalarKinds (ks,r) = KI `elem` ks && all (`elem` [KI,KB]) (r:ks)
            -- the authority: every member's checked interface is all raw words
            fromChecked = do
              sigs <- M.fromList <$> traverse full names
              if all scalarKinds (M.elems sigs) then Just sigs else Nothing
            full n = do
              (cks, cr) <- M.lookup n checked
              (ps, _) <- M.lookup n prog
              ks <- sequence cks
              r <- cr
              if length ks == length ps then Just (n, (ks, r)) else Nothing
            -- the assertion: KernelKinds' solution from erased Core
            inferred = do
              sigs <- componentSignatures prog names imports
              if all scalarKinds (M.elems sigs) then Just sigs else Nothing
    chosen = M.restrictKeys signatures (reachable S.empty (filter (`M.member` signatures) loops))
    worker n = prefix++"scalar."++n
    raw (CInt n) = app "$scalar.unbox" [CInt n]
    raw e = case spine e of
      (CVar h,args@(_:_)) | M.member h chosen -> app (worker h) (map raw args)
      (CVar h,[a,b]) | M.notMember h prog, h `elem` ops -> app ("$scalar."++h) [raw a,raw b]
      _ -> case e of
        CLet n a b -> CLet n (raw a) (raw b); CIf a b c -> CIf (raw a) (raw b) (raw c)
        CTagEq t v x -> CTagEq t v (raw x); _ -> e
    -- A worker that calls itself keeps one tick per iteration: Codegen.Placement
    -- drops the inlined callees' ticks after lowering.
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

-- A scalar worker that calls itself keeps one tick per iteration: its entry
-- tick is emitted by codegen, and Codegen.Placement drops the inlined callees'
-- ticks after lowering, for workers and non-worker self loops alike.
