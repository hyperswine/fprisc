-- Bounded uniqueness proofs for fresh constructors and private consuming entries.
-- Public calls remain borrowing. Only a fresh, nonescaping root can transfer
-- ownership; last syntactic use of a borrowed value is never sufficient.
module Reuse (reuseFresh, reuseProgram, reuseView, poolResetters) where
import Core.Syntax (Core(..), Prog)
import Core.Primitives (primArities,entryTickName)
import Core.Region.Runtime (Hook(..),hookName)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (isPrefixOf)
import Data.Maybe (mapMaybe, fromMaybe)

type Shape = (Int,Int,Int)
type Plans = M.Map String (Int,Shape,Int,String)

reuseView :: Core -> Maybe (String,[Core])
reuseView (CApp (CApp (CVar "$reuse.fresh") (CVar x)) (CMk _ _ fs)) = Just (x,fs)
reuseView _ = Nothing

reuseFresh :: Core -> Core
reuseFresh body = rewrite (poolResetters (M.singleton "$reuse.entry" ([],body))) M.empty S.empty body

-- A pool reset frees every object allocated in the pool before it. A reused
-- constructor writes into the old object's memory, so no reuse may span an
-- expression that can reset the pool: Sys.poolReset itself, or a call to a
-- function that reaches one (A.tidy's `boundary`, once inlining brought the
-- match and the rebuilt tuple into one body). A resetting CAF is evaluated at
-- a bare reference, too. Unknown callbacks and opaque foreign entries are
-- barriers: the source may legitimately stop using an old allocation before
-- the callback, while reuse would introduce a new write to it afterwards.
-- See docs/2026-10-27-FOLLOWUPS.md for the conservative supported contract.
poolResetters :: Prog -> S.Set String
poolResetters prog = go initial
  where
    base=S.fromList ("Sys.poolReset":map hookName [CallLeave,LoopLeave,Cycle,ReceiveLoop])
    safe=S.fromList (entryTickName:map fst primArities++map hookName [CallPending,SequenceNumber,Open,PoolMark,HasRoom])
    facts=M.map (\(ps,b)->references (S.fromList ps) b) prog
    calls=M.map fst facts
    unknown=S.unions (M.elems calls) S.\\ (M.keysSet prog `S.union` safe)
    initial=base `S.union` unknown `S.union` M.keysSet (M.filter snd facts)
    go known = let next = known `S.union` M.keysSet (M.filter (not . S.null . S.intersection known) calls)
               in if next == known then known else go next
    references bound e=case e of
      CVar f | f `S.notMember` bound->(S.singleton f,False)
      CLet x rhs body->merge (references bound rhs) (references (S.insert x bound) body)
      CLam ps body->references (bound `S.union` S.fromList ps) body
      CApp {}->let (head',args)=spine e
                   dynamic=case head' of CVar f->f `S.member` bound;_->True
               in foldr merge (S.empty,dynamic) (map (references bound) (head':args))
      _->foldr merge (S.empty,False) (map (references bound) (children e))
    merge (a,x) (b,y)=(a `S.union` b,x || y)

-- Each clone consumes one parameter and returns that same allocation (or
-- fails). Other parameters remain borrowing. No wrapper, descriptor or exported
-- ABI is changed. Bodies and call sites are in the same compilation unit.
reuseProgram :: S.Set String -> S.Set String -> Prog -> (Prog,[String])
reuseProgram resetting excluded prog = (rewritten `M.union` additions,
  ["# private consuming workers: "++show (M.size additions)])
  where
    choose (name,(ps,b))
      | "$worker." `isPrefixOf` name || S.member name excluded ||
        null ps || length ps>64 || not (bounded 256 b) = Nothing
      | otherwise = case mapMaybe (candidate name ps b) (zip [0..] ps) of
          p:_ -> Just (name,p)
          _ -> Nothing
    candidate name ps b (i,p) = do
      b' <- aliases p b
      shape <- resultShape b'
      -- Do not assume calls, closures or other parameters are disjoint from
      -- a borrowed input. The caller establishes disjointness for the clone.
      if readsOnly p (width shape) b'
        then do _ <- consume resetting M.empty (S.fromList ps) p shape b'
                pure (i,shape,length ps,"$worker.consume."++show i++"."++name)
        else Nothing
    plans = M.fromList (take 128 (mapMaybe choose (M.toAscList prog)))
    rewritten = M.map (\(ps,b)->(ps,rewrite resetting plans (S.fromList ps) b)) prog
    used = S.fromList [f | (_,(_,b))<-M.toList rewritten, e<-nodes b,
                          (CVar f,_)<-[spine e], "$worker.consume." `isPrefixOf` f]
    additions = M.fromList [(worker,(ps,out)) |
      (name,(i,shape,_,worker))<-M.toList plans, S.member worker used,
      let (ps,b)=prog M.! name,
      Just b'<-[aliases (ps!!i) b],
      Just out<-[consume resetting M.empty (S.fromList ps) (ps!!i) shape b']]

rewrite :: S.Set String -> Plans -> S.Set String -> Core -> Core
rewrite resetting plans = go
  where
    go locals e = case e of
      CLet x a b ->
        let a'=go locals a; scope=S.insert x locals; b'=go scope b
        in CLet x a' $ case resultShape a' of
          Just shape -> tryRoot resetting plans scope x shape b'
          _ -> b'
      CIf a b c -> CIf (go locals a) (go locals b) (go locals c)
      CApp a b -> CApp (go locals a) (go locals b)
      CMk t v fs -> CMk t v (map (go locals) fs)
      CProj k a -> CProj k (go locals a)
      CTagEq t v a -> CTagEq t v (go locals a)
      -- Never move a uniqueness proof into a closure.
      _ -> e

tryRoot :: S.Set String -> Plans -> S.Set String -> String -> Shape -> Core -> Core
tryRoot resetting plans locals x shape b = fromMaybe b $ do
  if bounded 256 b then pure () else Nothing
  b' <- aliases x b
  useRoot resetting plans locals x shape b'

-- Every successful path returns the original allocation, directly or through a
-- proven consuming callee. A non-tail transfer is allowed only if no old alias
-- survives into its continuation; its result becomes the next unique root.
consume :: S.Set String -> Plans -> S.Set String -> String -> Shape -> Core -> Maybe Core
consume resetting plans locals x shape e = case e of
  CMk t v fs | shape==(t,v,length fs), all ro fs ->
    Just (CApp (CApp (CVar "$reuse.fresh") (CVar x)) e)
  CVar y | x==y -> Just e
  CLet y a b | y/=x ->
    if ro a then CLet y a <$> consume resetting plans (S.insert y locals) x shape b
    else if not (mentions x b) then do
      a' <- consume resetting plans locals x shape a
      b' <- aliases y b
      CLet y a' <$> consume resetting plans (S.insert y locals) y shape b'

    else Nothing
  CIf c a b | ro c -> CIf c <$> consume resetting plans locals x shape a <*> consume resetting plans locals x shape b
  CErr _ -> Just e
  _ -> case spine e of
    (CVar f,args) | S.notMember f locals,
      Just (i,s,arity,worker)<-M.lookup f plans, s==shape, length args==arity,
      args!!i==CVar x, and [ro a | (j,a)<-zip [0..] args,j/=i] ->
        Just (foldl CApp (CVar worker) args)
    _ -> Nothing
  where ro e' = readsOnly x (width shape) e' && not (resets resetting locals e')

-- A last-use transfer may feed an arbitrary continuation, but that does not
-- prove that the entire expression returns the unique root. Keep this separate
-- from consume, whose return-shape guarantee permits subsequent transfers.
useRoot :: S.Set String -> Plans -> S.Set String -> String -> Shape -> Core -> Maybe Core
useRoot resetting plans locals x shape e = case consume resetting plans locals x shape e of
  Just out -> Just out
  Nothing -> case e of
    CLet y a b | y/=x ->
      if ro a then CLet y a <$> useRoot resetting plans (S.insert y locals) x shape b
      else if not (mentions x b) then do
        a' <- consume resetting plans locals x shape a
        pure (CLet y a' (tryRoot resetting plans (S.insert y locals) y shape b))
      else Nothing
    CIf c a b | ro c -> CIf c <$> useRoot resetting plans locals x shape a <*> useRoot resetting plans locals x shape b
    _ | ro e -> Just e
    _ -> Nothing
  where ro e' = readsOnly x (width shape) e' && not (resets resetting locals e')

-- Does evaluating e call something that may reset the pool?
resets :: S.Set String -> S.Set String -> Core -> Bool
resets resetting bound e=case e of
  CVar f->f `S.member` resetting
  CLet x rhs body->resets resetting bound rhs || resets resetting (S.insert x bound) body
  CApp {}->let (head',args)=spine e
               dynamic=case head' of CVar f->f `S.member` bound;_->True
           in dynamic || any (resets resetting bound) (head':args)
  CLam _ _->False -- constructing a closure does not execute its body
  _->any (resets resetting bound) (children e)

-- Only constructor-producing exits establish freshness. Error exits do not
-- return. The bounded search rejects differing branch shapes and bare aliases.
resultShape :: Core -> Maybe Shape
resultShape e | not (bounded 256 e) = Nothing
resultShape e = case shapes e of
  Just ss | [s@(t,v,n)]<-S.toList ss, n>0, n<=64 -> Just (t,v,n)
  _ -> Nothing
  where
    shapes (CMk t v fs) = Just (S.singleton (t,v,length fs))
    shapes (CLet _ _ b) = shapes b
    shapes (CIf _ a b) = S.union <$> shapes a <*> shapes b
    shapes (CErr _) = Just S.empty
    shapes _ = Nothing
width :: Shape -> Int
width (_,_,n)=n

-- Canonicalize aliases of this root only. The root is not rebound anywhere in
-- its scope; alias substitutions respect lexical shadowing. This includes
-- separate branch scopes, without claiming that arbitrary joins are unique.
aliases :: String -> Core -> Maybe Core
aliases x b | rebinds x b = Nothing
aliases x b = Just (go S.empty b)
  where
    go env e = case e of
      CVar y | S.member y env -> CVar x
      CLet y a rest ->
        let a'=go env a; env'=S.delete y env
        in if a'==CVar x then go (S.insert y env') rest
           else CLet y a' (go env' rest)
      CIf c a d -> CIf (go env c) (go env a) (go env d)
      CApp a d -> CApp (go env a) (go env d)
      CMk t v fs -> CMk t v (map (go env) fs)
      CProj k a -> CProj k (go env a)
      CTagEq t v a -> CTagEq t v (go env a)
      CLam ps a -> CLam ps (go (foldr S.delete env ps) a)
      _ -> e

-- Children may escape: a freshly allocated parent cannot be reachable from
-- its pre-existing children. Whole-parent uses and captures are rejected.
readsOnly :: String -> Int -> Core -> Bool
readsOnly x n = go
  where
    go (CVar y) = x/=y
    go (CProj k (CVar y)) | x==y = k>=0 && k<n
    go (CTagEq _ _ (CVar y)) | x==y = True
    go (CLet y a b) = x/=y && go a && go b
    go (CLam ps b) = x `notElem` ps && not (mentions x b)
    go e = all go (children e)
mentions :: String -> Core -> Bool
mentions x (CVar y) = x==y
mentions x e = any (mentions x) (children e)
rebinds :: String -> Core -> Bool
rebinds x (CLet y a b) = x==y || rebinds x a || rebinds x b
rebinds x (CLam ps b) = x `elem` ps || rebinds x b
rebinds x e = any (rebinds x) (children e)
spine :: Core -> (Core,[Core])
spine = go [] where go xs (CApp f a)=go (a:xs) f; go xs f=(f,xs)
bounded :: Int -> Core -> Bool
bounded n e = length (take (n+1) (nodes e))<=n
nodes :: Core -> [Core]
nodes e=e:concatMap nodes (children e)
children :: Core -> [Core]
children (CApp a b) = [a,b]
children (CLet _ a b) = [a,b]
children (CIf c a b) = [c,a,b]
children (CMk _ _ fs) = fs
children (CProj _ a) = [a]
children (CTagEq _ _ a) = [a]
children (CLam _ b) = [b]
children _ = []
