-- Ordered Core transformations and their ABI metadata. A result can only be
-- obtained through the checked driver; consumers cannot pair a program with
-- signatures from another stage. This is a structural check, not Core typing.
module Core.Opt.Pipeline
  (OptimizationOptions(..), CorePass(..), PassReport(..), OptimizedCore,
   optimizeCore,optimizeCoreWithImports,optimizeCoreWithCheckedImports,optimizeCoreWithProducts, optimizedProgram, optimizedSignatures, optimizationNotes,
   optimizationReports, verifyPassResult) where
import Core.Syntax
import Core.Opt.Fusion (fuseCompatibilityWithImports)
import Core.Opt.Normalize (normIn)
import Core.Opt.PairReturns (productReturnProgramWithVariants)
import Workers (ScalarSignatures, workerizeWithResultFacts, internalWorker)
import Core.Opt.StoredLists (storeLists)
import Core.Opt.ProductParameters
import Reuse (reuseProgramWithImports, poolResetters)
import Control.Monad (foldM, unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Maybe (isJust)
import Compiler.DataLayout (tupWideBase)

data OptimizationOptions = OptimizationOptions
  { optFusion :: Bool, optWorkers :: Bool, optFieldWorkers :: Bool, optTupleScalars :: Bool,
    optScalarWorkers :: Bool, optPairReturns :: Bool, optProductWidth :: Int, optNormalize :: Bool, optReuse :: Bool,
    -- known pool resetters beyond this program and its imports (the linked
    -- program's, Reuse.poolResetters): reuse never spans a call to one
    optPoolResetters :: S.Set Name, optSpineBuilders :: M.Map Name (Int,Int),
    -- std/map's balance and node, from the linked program: the owned-map
    -- walker inlines them to rebuild a rebalanced node in place (Reuse)
    optMapBodies :: Prog }
  deriving (Eq, Show)

data CorePass = LocalProducts | FuseVectors | MakeWorkers | NormalizeForReuse | ReuseConstructors | BuildStrings | PairReturns
  deriving (Eq, Show)

data PassReport = PassReport
  { passName :: CorePass, passEnabled :: Bool, passNotes :: [String] }
  deriving (Eq, Show)

-- Use ordinary accessors rather than exported record fields: record updates
-- would otherwise let clients combine a program with unrelated signatures.
data OptimizedCore = OptimizedCore Prog ScalarSignatures [PassReport]

optimizedProgram :: OptimizedCore -> Prog
optimizedProgram (OptimizedCore p _ _) = p

optimizedSignatures :: OptimizedCore -> ScalarSignatures
optimizedSignatures (OptimizedCore _ sigs _) = sigs

optimizationReports :: OptimizedCore -> [PassReport]
optimizationReports (OptimizedCore _ _ reports) = reports

optimizationNotes :: OptimizedCore -> [String]
optimizationNotes = concatMap passNotes . optimizationReports

optimizeCore :: OptimizationOptions -> S.Set Name -> Prog -> Either String OptimizedCore
optimizeCore=optimizeCoreWithImports M.empty
optimizeCoreWithImports :: Prog -> OptimizationOptions -> S.Set Name -> Prog -> Either String OptimizedCore
optimizeCoreWithImports=optimizeCoreWithCheckedImports S.empty
optimizeCoreWithCheckedImports :: S.Set Name -> Prog -> OptimizationOptions -> S.Set Name -> Prog -> Either String OptimizedCore
optimizeCoreWithCheckedImports=optimizeCoreWithProducts emptyProductParameters
optimizeCoreWithProducts :: ProductParameters -> S.Set Name -> Prog -> OptimizationOptions -> S.Set Name -> Prog -> Either String OptimizedCore
optimizeCoreWithProducts products checked imports opts elide input = do
  verifyPassResult input input M.empty
  fst <$> foldM run (OptimizedCore input M.empty [],products)
    [LocalProducts, FuseVectors, MakeWorkers, NormalizeForReuse, ReuseConstructors, BuildStrings, PairReturns]
  where
    run (state,facts) pass = do
      let before = optimizedProgram state
          (workers,workerNotes,workerSigs,workerFacts) = workerizeWithResultFacts facts
            (optWorkers opts && optFieldWorkers opts) (optTupleScalars opts) (optWorkers opts && optScalarWorkers opts) before
          (after,sigs,notes,enabled) = case pass of
            -- a tuple built in each branch and taken apart at once: its
            -- fields, each from its own copy of the (cheap, pure) branches
            LocalProducts -> (if optReuse opts then localProducts before else before,optimizedSignatures state,[],optReuse opts)
            FuseVectors -> let (p,ns) = if optFusion opts then fuseCompatibilityWithImports (checkedKinds (M.union before imports) products) checked imports before else (before,[])
                           in (p,optimizedSignatures state,ns,optFusion opts)
            MakeWorkers -> let fields = optWorkers opts && optFieldWorkers opts
                               scalars = optWorkers opts && optScalarWorkers opts
                           in (workers,workerSigs,workerNotes,fields || scalars)
            NormalizeForReuse ->
              let enabled = optReuse opts && optNormalize opts
                  p = if enabled then M.map (\(ps,b)->(ps,normIn (S.fromList ps) b)) before else before
              in (p,optimizedSignatures state,[],enabled)
            ReuseConstructors -> let (p,ns) = if optReuse opts then reuseProgramWithImports (optSpineBuilders opts) (optMapBodies opts) imports (optPoolResetters opts `S.union` poolResetters (M.union before imports)) elide before else (before,[])
                                 in (p,optimizedSignatures state,ns,optReuse opts)
            -- strcat chains into one call over a tuple of the pieces; on
            -- where reuse is (64-bit, fuelled, no ARC: the runtime has it)
            BuildStrings -> let p=if optReuse opts then buildStrings before else before
                            in (p,optimizedSignatures state,["string pieces: "++n | (n,b)<-M.toList p, M.lookup n before /= Just b],optReuse opts)
            -- after every pass that reads call results: the twins are the last functions made
            PairReturns
              | optPairReturns opts ->
                  let width=optProductWidth opts
                      (stored,notes)=storeLists products width before
                      (out,ss,ns)=productReturnProgramWithVariants (variantResults before facts) width stored (optimizedSignatures state)
                  in (out,ss,notes++ns,True)
              | otherwise -> (before,optimizedSignatures state,[],False)
      case verifyPassResult before after sigs of
        Left err -> Left (show pass ++ ": " ++ err)
        Right () -> Right (OptimizedCore after sigs
          (optimizationReports state ++ [PassReport pass enabled notes]), if pass==MakeWorkers then workerFacts else facts)

-- Passes may add private functions, but must retain existing entry arities.
-- Workers record representations at creation time: check their names and
-- parameter counts instead of guessing those representations after rewriting.
verifyPassResult :: Prog -> Prog -> ScalarSignatures -> Either String ()
verifyPassResult before after sigs = do
  mapM_ retained (M.toList before)
  mapM_ parameters (M.toList after)
  mapM_ worker (M.toList sigs)
  where
    retained (n,(ps,_)) = case M.lookup n after of
      Nothing -> Left ("removed function " ++ n)
      Just (qs,_) -> unless (length ps == length qs) (Left ("changed entry arity of " ++ n))
    parameters (n,(ps,_)) = unless (length ps == S.size (S.fromList ps))
      (Left ("duplicate parameters in " ++ n))
    worker (n,(ks,_)) = do
      unless (internalWorker n) (Left ("scalar signature on non-worker " ++ n))
      case M.lookup n after of
        Nothing -> Left ("signature without worker " ++ n)
        Just (ps,_) -> unless (length ps == length ks) (Left ("worker signature arity for " ++ n))

-- An interpolation (a strcat chain of three or more pieces) becomes one
-- runtime call over a tuple of its pieces: one String and one copy, where
-- the chain made a String per piece and copied the front again at every
-- step. str comes off each piece: the runtime renders a non-String piece as
-- str would (a float piece is already its String: Infer's str! sites).
-- The tuple keeps the pieces in order, so they evaluate as before.
buildStrings :: Prog -> Prog
buildStrings=M.map (\fn@(ps,b)->if hasChain b then (ps,go b) else fn)
  where
    go e=case e of
      CApp (CApp (CVar "strcat") _) _ | leaves@(_:_:_:_)<-chain e ->
        CApp (CVar "$strcatT") (CMk (tupleTid (length leaves)) 0 (map (go . unstr) leaves))
      CApp f a -> CApp (go f) (go a)
      CLet k a b -> CLet k (go a) (go b)
      CIf c a b -> CIf (go c) (go a) (go b)
      CMk t v fs -> CMk t v (map go fs)
      CProj k a -> CProj k (go a)
      CTagEq t v a -> CTagEq t v (go a)
      CLam qs b -> CLam qs (go b)
      _ -> e
    -- most functions build no string: leave them untouched (no copy)
    hasChain x=case x of
      CApp (CApp (CVar "strcat") (CApp (CApp (CVar "strcat") _) _)) _ -> True
      CApp (CApp (CVar "strcat") _) (CApp (CApp (CVar "strcat") _) _) -> True
      CApp f a -> hasChain f || hasChain a
      CLet _ a b -> hasChain a || hasChain b
      CIf c a b -> hasChain c || hasChain a || hasChain b
      CMk _ _ fs -> any hasChain fs
      CProj _ a -> hasChain a
      CTagEq _ _ a -> hasChain a
      CLam _ b -> hasChain b
      _ -> False
    chain (CApp (CApp (CVar "strcat") a) b)=chain a++chain b
    chain x=[x]
    unstr (CApp (CVar "str") x)=x
    unstr x=x
    -- runtime/fpr.h: Tup2 4, Tup3 5, Tup4..Tup8 10..14, wider T_TUPN + n
    tupleTid n | n==2=4 | n==3=5 | n<=8=n+6 | otherwise=tupWideBase+n

-- Local products. A let whose value is a tree of lets and ifs ending in one
-- constructor shape (a tuple, a record), used only through projections,
-- never needs the cell: each field gets a let of its own, over a copy of
-- the tree that keeps that field. Only for trees that are cheap and pure
-- (arithmetic, comparisons, projections, tests, ticks; no call, no
-- allocation): the copies repeat that work instead of allocating. The
-- first copy evaluates what the original did up to its first field, so
-- the first trap is the original's. (An inlined pair-returning helper,
-- sim's bounce, leaves this shape.)
localProducts :: Prog -> Prog
localProducts=M.map (\fn@(ps,b)->if any isCandidate (lets b) then (ps,go (uses b) b) else fn)
  where
    lets b=[(t,rhs) | CLet t rhs _<-nodesOf b]
    nodesOf x=x:concatMap nodesOf (kids x)
    isCandidate (_,rhs)=case prefix rhs of (_,tree) -> isJust (shape tree)
    -- each variable's uses, in one walk: projected fields, shapes tested
    -- (as an if's condition), and whether it is used any other way
    uses b=M.fromListWith merge (walk b)
    merge (a1,b1,c1) (a2,b2,c2)=(max a1 a2,S.union b1 b2,c1 || c2)
    walk x=case x of
      CProj i (CVar y) -> [(y,(i,S.empty,i<0))]
      CIf (CTagEq tg v (CVar y)) a b -> (y,(-1,S.singleton (tg,v),False)):walk a++walk b
      CVar y -> [(y,(-1,S.empty,True))]
      _ -> concatMap walk (kids x)
    go info e=case e of
      -- the lets in front of the branches run once, outside (typed
      -- binders are unique: floating them captures nothing); only the
      -- branching part is copied
      CLet t rhs body | (front,tree)<-prefix rhs, Just sh@(tg,v,n)<-shape tree, n>=1, cheapTree tree,
                        size tree<=64, projectedOnly info t sh ->
        let names=[t++"#"++show i | i<-[0..n-1]]
            copies=[rename (t++"#"++show i++".") M.empty (leaves (!!i) tree) | i<-[0..n-1]]
            body'=subst t sh names body
        in go info (front (foldr (\(nm,c) b->CLet nm c b) body' (zip names copies)))
      CLet k a b -> CLet k (go info a) (go info b)
      CApp f a -> CApp (go info f) (go info a)
      CIf c a b -> CIf (go info c) (go info a) (go info b)
      CMk t v fs -> CMk t v (map (go info) fs)
      CProj k a -> CProj k (go info a)
      CTagEq t v a -> CTagEq t v (go info a)
      CLam qs b -> CLam qs (go info b)
      _ -> e
    prefix x=case x of
      CLet k a b | CIf _ _ _<-a -> (id,x)
                 | otherwise -> let (f,t')=prefix b in (CLet k a . f,t')
      _ -> (id,x)
    shape x=case x of
      CLet _ _ b -> shape b
      CIf _ a b -> case (shape a,shape b) of
        (Just sa,Just sb) | sa==sb -> Just sa
        (Just sa,Nothing) | isErr b -> Just sa
        (Nothing,Just sb) | isErr a -> Just sb
        _ -> Nothing
      CMk t v fs -> Just (t,v,length fs)
      _ -> Nothing
    isErr x=case x of CErr _ -> True; CLet _ _ b -> isErr b; _ -> False
    leaves f x=case x of
      CLet k a b -> CLet k a (leaves f b)
      CIf c a b -> CIf c (leaves f a) (leaves f b)
      CMk _ _ fs -> f fs
      _ -> x
    cheapTree x=case x of
      CLet _ a b -> cheap a && cheapTree b
      CIf c a b -> cheap c && cheapTree a && cheapTree b
      CMk _ _ fs -> all cheap fs
      CErr _ -> True
      _ -> False
    cheap x=case x of
      CVar _ -> True
      CInt _ -> True
      CProj _ a -> cheap a
      CTagEq _ _ a -> cheap a
      CLet _ a b -> cheap a && cheap b
      CIf c a b -> cheap c && cheap a && cheap b
      CApp (CVar "$fuel") (CInt _) -> True
      CApp (CApp (CVar op) a) b | op `elem` ["+","-","*","/","==","!=","<",">","<=",">="] -> cheap a && cheap b
      _ -> False
    size x=1+sum (map size (kids x))
    kids x=case x of
      CLet _ a b -> [a,b]; CIf c a b -> [c,a,b]; CApp f a -> [f,a]; CMk _ _ fs -> fs
      CProj _ a -> [a]; CTagEq _ _ a -> [a]; CLam _ b -> [b]; _ -> []
    -- every use of t a projection of one of its n fields, or a test of
    -- its shape (an if's condition: always true); typed binders are unique,
    -- so the function-wide walk speaks for t's scope
    projectedOnly info t (tg,v,n)=case M.lookup t info of
      Nothing -> True
      Just (maxField,shapes,other) -> not other && maxField<n && all (==(tg,v)) (S.toList shapes)
    subst t sh@(tg,v,_) names x=let subst' = subst t sh names in case x of
      CIf (CTagEq tg' v' (CVar y)) a _ | y==t, (tg',v')==(tg,v) -> subst' a
      CProj i (CVar y) | y==t -> CVar (names!!i)
      CLet k a b -> CLet k (subst' a) (subst' b)
      CApp f a -> CApp (subst' f) (subst' a)
      CIf c a b -> CIf (subst' c) (subst' a) (subst' b)
      CMk tg2 v2 fs -> CMk tg2 v2 (map subst' fs)
      CProj k a -> CProj k (subst' a)
      CTagEq tg2 v2 a -> CTagEq tg2 v2 (subst' a)
      CLam qs b -> CLam qs (subst' b)
      _ -> x
    -- a copy's binders under a prefix of its own (binders stay unique)
    rename pre env x=case x of
      CVar v -> CVar (M.findWithDefault v v env)
      CLet k a b -> let k'=pre++k in CLet k' (rename pre env a) (rename pre (M.insert k k' env) b)
      CApp f a -> CApp (rename pre env f) (rename pre env a)
      CIf c a b -> CIf (rename pre env c) (rename pre env a) (rename pre env b)
      CMk tg v fs -> CMk tg v (map (rename pre env) fs)
      CProj k a -> CProj k (rename pre env a)
      CTagEq tg v a -> CTagEq tg v (rename pre env a)
      _ -> x
