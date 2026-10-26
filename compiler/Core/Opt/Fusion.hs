module Core.Opt.Fusion (fuseVecFix,fuseVecFixWithImports,fuseCompatibilityWithImports) where
import Core.Syntax
import Core.Utils
import Core.Primitives (primArities)
import Core.Analysis.FusionSafety
import Core.Opt.Vector (nestPipelinesWithImports)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (foldl', nub)

-- Checked source already composed its callbacks before erasure. The remaining
-- layout pipeline canonicalizer still consumes physical Core; only explicit
-- compatibility owners may create erased callback composites here.
fuseCompatibilityWithImports :: S.Set Name -> Prog -> Prog -> (Prog,[String])
fuseCompatibilityWithImports checked imports source=
  let planned=nestPipelinesWithImports imports source
      retained=M.restrictKeys planned checked
      (changed,notes)=fuseVecFixWithImports (retained `M.union` imports) (M.withoutKeys planned checked)
  in (retained `M.union` changed,notes)

-- run fusion to a FIXPOINT: a 3+ chain's outer pair fuses in round 1,
-- the composite-over-inner pair in round 2, and so on until no pair is
-- left.  Each round's composites get a round-tagged name so rounds
-- never collide; the plan-level machinery already composes through
-- composites (soaDualMap0 recognizes the f(g el) body shape
-- recursively), so a fully collapsed chain still dualizes.  The bound
-- is a backstop, not a budget: a chain of length n needs n-1 rounds
-- and real programs stop far short of it.
fuseVecFix :: Prog -> (Prog, [String])
fuseVecFix=fuseVecFixWithImports M.empty
fuseVecFixWithImports :: Prog -> Prog -> (Prog,[String])
fuseVecFixWithImports imports prog = go (0 :: Int) (nestPipelinesWithImports imports prog)
  where
    go r p
      | r >= 16 = (p, [])
      | otherwise =
          let (p', notes) = fuseVec r imports p
           in if M.size p' == M.size p then (p', nub notes) else let (p'', more) = go (r + 1) p' in (p'', nub (notes ++ more))

fuseVec :: Int -> Prog -> Prog -> (Prog, [String])
fuseVec round' imports prog = (M.union extras (M.map (\(ps,b) -> (ps,rewrite b)) prog), nub notes)
  where
    universe=prog `M.union` imports
    apps = foldl' CApp
    opAt e = case spineOf e of
      (CVar op,[fe,v]) | op `elem` ["Vec.map","Vec.filter"],
        (CVar f,caps) <- spineOf fe,
        Just (ps,_) <- M.lookup f universe, length ps == length caps + 1 -> Just ((op,f,caps),v)
      _ -> Nothing
    -- Moving capture evaluation across a pass requires the same effect/trap
    -- judgement as moving callbacks. Locals and pure expressions are safe.
    capSafe e = fusionSafe (M.insert "$capture" (locals,e) universe) "$capture"
      where locals = [n | n <- freeVars e, M.notMember n universe, n `notElem` prims]
            prims = map fst primArities
    fusedAt e = do
      ((op,f,fc),v1) <- opAt e
      ((op',g,gc),v) <- opAt v1
      if op == op' && fusionSafe universe f && fusionSafe universe g && all capSafe (fc++gc)
         && length fc + length gc <= 7 then Just () else Nothing
      pure ((op,f,g,length fc,length gc),fc++gc,v)
    -- accumulator form: `e : concatMap walk (children e)` ended in
    -- `walk lastChild ++ []`, which copies the deep child's whole list at
    -- every level of a let chain or a list literal (quadratic)
    walk e0 = walkInto e0 []
    walkInto e0 acc = let e = seeLet e0 in e : foldr walkInto acc (children e)
    children (CApp a b) = [a,b]
    children (CLet _ a b) = [a,b]
    children (CIf c a b) = [c,a,b]
    children (CMk _ _ fs) = fs
    children (CTagEq _ _ x) = [x]
    children (CProj _ x) = [x]
    children (CLam _ x) = [x]
    children _ = []
    nodes = concat [walk b | (_,b) <- M.elems prog]
    keys = S.toList (S.fromList [k | e <- nodes, Just (k,_,_) <- [fusedAt e]])
    names = M.fromList [(k,"_vfuse_" ++ show round' ++ "_" ++ show i) | (i,k) <- zip [0::Int ..] keys]
    extras = M.fromList [(names M.! k,composite k) | k <- keys]
    composite (op,f,g,nf,ng) =
      let ps = ["$fc" ++ show i | i <- [0..nf+ng-1]]
          x = CVar "$fe"
          outer = apps (CVar f) (map CVar (take nf ps) ++ [x])
          inner = apps (CVar g) (map CVar (drop nf ps) ++ [x])
          body | op == "Vec.map" = apps (CVar f) (map CVar (take nf ps) ++ [inner])
               | otherwise = CIf (CTagEq 1 1 inner) outer (CMk 1 0 [])
       in (ps ++ ["$fe"],body)
    notes = ["vec note: " ++ op ++ " `" ++ f ++ "` after " ++ op ++ " `" ++ g
               ++ "` is NOT fused: " ++ why ++ " -- the two passes run in order, each over the whole vector"
            | e <- nodes ++ concatMap letCandidates nodes, Just ((op,f,fc),v) <- [opAt e], Just ((op',g,gc),_) <- [opAt v], op == op',
              Nothing <- [fusedAt e],
              let why = case [(n,r) | (n,Just r) <- [(g,fusionUnsafeReason universe g),(f,fusionUnsafeReason universe f)]] of
                          (n,r):_ -> "`" ++ n ++ "` uses " ++ r
                          [] | not (all capSafe (fc++gc)) -> "capture evaluation can have effects or fail"
                             | otherwise -> "combined capture budget exceeded"]
    rewrite e0 = let e = seeLet e0 in case fusedAt e of
      Just (key,caps,v) -> let (op,_,_,_,_) = key
                          in apps (CVar op) [apps (CVar (names M.! key)) (map rewrite caps),rewrite v]
      _ -> case e of
        CApp a b -> CApp (rewrite a) (rewrite b)
        CLet x a b -> CLet x (rewrite a) (rewrite b)
        CIf c a b -> CIf (rewrite c) (rewrite a) (rewrite b)
        CMk t v fs -> CMk t v (map rewrite fs)
        CTagEq t v x -> CTagEq t v (rewrite x)
        CProj k x -> CProj k (rewrite x)
        CLam ps x -> CLam ps (rewrite x)
        _ -> e
    seeLet (CLet x ve b) | Just ((op,_,_),_) <- opAt ve =
      let next m = case opAt m of
            Just ((op',_,caps),CVar v) -> op == op' && v == x && all (not . elem x . freeVars) caps &&
              case fusedAt (plug m) of Just _ -> True; Nothing -> False
            _ -> False
          plug m = case spineOf m of (CVar h,[fe,_]) -> apps (CVar h) [fe,ve]; _ -> m
       in case b of
            _ | next b -> seeLet (plug b)
            CLet y inner rest | next inner, x `notElem` freeVars rest -> seeLet (CLet y (plug inner) rest)
            _ -> CLet x ve b
    seeLet e = e
    letCandidates (CLet x ve b) | Just ((op,_,_),_) <- opAt ve =
      [apps (CVar op) [fe,ve] | m <- b : (case b of CLet _ inner rest | x `notElem` freeVars rest -> [inner]; _ -> []),
         (CVar op',[fe,CVar v]) <- [spineOf m], op == op', v == x]
    letCandidates _ = []

