-- A private flat result is valid only across a proven producer/reader pair.
-- Public entries and readers which need a nominal subobject stay tagged.
module Core.Opt.NestedReturns (Nested(..), nestedPlans, nestedReader) where

import Core.Syntax (Core(..), Name, Prog, freeVars, occurs)
import Core.Utils (spineOf)
import Core.ProductABI (packName)
import Control.Monad (guard, foldM, zipWithM)
import Control.Monad.State.Strict (StateT, runStateT, get, put, modify', lift)
import Data.Graph (flattenSCC, stronglyConnComp)
import Data.List (foldl')
import qualified Data.Map.Lazy as Env
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Layout = Slot | Node Int Int Int [Layout] deriving (Eq,Show)
wordsIn :: Layout -> Int
wordsIn Slot = 1
wordsIn (Node _ _ width _) = width

data Nested = Nested { nestedName :: Name, nestedLayout :: Layout, nestedCode :: ([Name],Core), adapterWidths :: M.Map Name Int }

app :: Name -> [Core] -> Core
app f = foldl' CApp (CVar f)
packet :: [Core] -> Core
packet [x] = x
packet xs = app (packName (length xs)) xs
wordAt :: Name -> Int -> Int -> Core
wordAt x 1 _ = CVar x
wordAt x _ i = CProj i (CVar x)

worker :: String -> Layout -> Name -> Name
worker kind layout name = "$worker.ret" ++ show (wordsIn layout) ++ ".$nested." ++ kind ++ "." ++ name

type Constructors = M.Map Name (Int,Int,Int)
constructor :: Constructors -> S.Set Name -> Core -> Maybe (Name,Int,Int,[Core])
constructor constructors bound e = do
  let (headExpr,args) = spineOf e
  CVar f <- pure headExpr
  guard (S.notMember f bound)
  (t,v,n) <- M.lookup f constructors
  guard (length args == n)
  pure (f,t,v,args)

-- Record only finite constructor syntax. Cap an over-wide child at its
-- nominal slot so shared let-bound trees never expand exponentially.
node :: Int -> Int -> Int -> [Layout] -> Layout
node capacity t v fields
  | null fields || n > capacity = Slot
  | width > capacity = Node t v n (replicate n Slot)
  | otherwise = Node t v width fields
  where n = length fields; width = sum (map wordsIn fields)

common :: Layout -> Layout -> Layout
common (Node t v _ xs) (Node u w _ ys)
  | (t,v,length xs)==(u,w,length ys) = let fs=zipWith common xs ys in Node t v (sum (map wordsIn fs)) fs
common _ _ = Slot

data Exit = Returns Layout | Forward Name Int | Traps

exits :: Int -> Constructors -> [Name] -> Core -> [Exit]
exits capacity constructors params = walk (S.fromList params) Env.empty
  where
    walk bound env expr = case expr of
      CLet x a b -> walk (S.insert x bound) (Env.insert x (value bound env a) env) b
      CIf _ yes no -> walk bound env yes ++ walk bound env no
      CErr _ -> [Traps]
      _ | Just (_,t,v,args) <- constructor constructors bound expr -> [Returns (fields bound env t v args)]
        | (CVar f,args@(_:_)) <- spineOf expr, S.notMember f bound -> [Forward f (length args)]
        | otherwise -> [Returns (value bound env expr)]
    fields bound env t v = node capacity t v . map (value bound env)
    value bound env expr = case expr of
      CMk t v args -> fields bound env t v args
      CLet x a b -> value (S.insert x bound) (Env.insert x (value bound env a) env) b
      CVar x -> Env.findWithDefault Slot x env
      CIf _ (CErr _) b -> value bound env b
      CIf _ a (CErr _) -> value bound env a
      CIf _ a b -> common (value bound env a) (value bound env b)
      _ | Just (_,t,v,args) <- constructor constructors bound expr -> fields bound env t v args
        | otherwise -> Slot

nestedPlans :: Int -> Prog -> S.Set Name -> (M.Map Name Nested, Prog)
nestedPlans capacity prog eligible = (plans,adapters)
  where
    constructors = M.mapMaybe simple (M.restrictKeys prog eligible)
    simple (ps,CMk t v fields) | not (null ps), fields == map CVar ps = Just (t,v,length ps)
    simple _ = Nothing
    candidates = M.map (uncurry (exits capacity constructors)) (M.restrictKeys prog eligible)
    groups = map flattenSCC $ stronglyConnComp [(f,f,[g|Forward g _<-xs]) | (f,xs)<-M.toList candidates]
    plans = foldl' admit M.empty groups
    admit known names = maybe known (`M.union` known) $ do
      let local = S.fromList names
          evidence Traps = Just []
          evidence (Returns layout) = Just [layout]
          evidence (Forward f k) = do
            (ps,_) <- M.lookup f prog
            guard (length ps == k)
            if S.member f local then Just [] else (:[]) . nestedLayout <$> M.lookup f known
      first:rest <- concat <$> traverse evidence (concatMap (candidates M.!) names)
      let layout = foldl' common first rest
      Node _ _ _ children <- pure layout
      guard (any (/=Slot) children)
      let target f | S.member f local = Just layout
                   | otherwise = nestedLayout <$> M.lookup f known
          build f = do
            let entry = worker "result" layout f
                (ps,b) = prog M.! f
            guard (M.notMember entry prog)
            (code,required) <- flatten prog constructors target layout ps b
            pure (f,Nested entry layout (ps,code) required)
      M.fromList <$> traverse build names
    -- Exact constructor helpers keep their call and entry fuel. The adapter
    -- takes the already evaluated leaf words and returns them in order.
    adapters = M.map adapter (M.unions (map adapterWidths (M.elems plans)))
    adapter width = let ps=["$nested.word."++show i | i<-[0..width-1]]
                    in (ps,packet (map CVar ps))

-- A strict local may change representation only if every use agrees. Record
-- demands backwards through lets, but emit their RHS at its original point.
type Uses = M.Map Name Layout
type Build = StateT (Int, M.Map Name Int) Maybe
ordinary :: Core -> Uses
ordinary = M.fromList . map (\x -> (x,Slot)) . freeVars
combine :: [Uses] -> Build Uses
combine = foldM merge M.empty
  where merge a b = do
          guard (and (M.elems (M.intersectionWith (==) a b)))
          pure (M.union a b)

flatten :: Prog -> Constructors -> (Name -> Maybe Layout) -> Layout -> [Name] -> Core -> Maybe (Core,M.Map Name Int)
flatten prog constructors target layout ps body = do
  (code,(_,required)) <- runStateT build (0,M.empty)
  pure (code,required)
  where
    build = do
      (code,uses) <- emit (S.fromList ps) layout body
      guard (all (==Slot) (M.elems uses))
      pure code
    taken = S.fromList (ps ++ names body)
    names e = case e of
      CVar x -> [x]; CLet x a b -> x:names a++names b; CLam xs a -> xs++names a
      CIf c a b -> names c++names a++names b; CApp a b -> names a++names b
      CMk _ _ xs -> concatMap names xs; CProj _ a -> names a; CTagEq _ _ a -> names a; _ -> []
    fresh :: Build Name
    fresh = do
      (i,required)<-get; put (i+1,required)
      let x="$nested.leaf."++show i
      if S.member x taken then fresh else pure x
    emit _ Slot e = pure (e,ordinary e)
    emit bound wanted@(Node t v _ fields) e = case e of
      CErr _ -> pure (e,M.empty)
      CVar x | S.member x bound -> pure (CVar x,M.singleton x wanted)
      CLet x a b -> do
        (b',ub) <- emit (S.insert x bound) wanted b
        (a',ua) <- emit bound (M.findWithDefault Slot x ub) a
        uses <- combine [ua,M.delete x ub]
        pure (CLet x a' b',uses)
      CIf c a b -> do
        (a',ua)<-emit bound wanted a; (b',ub)<-emit bound wanted b
        uses<-combine [ordinary c,ua,ub]; pure (CIf c a' b',uses)
      CMk tid variant xs | (tid,variant)==(t,v) -> do
        guard (wordsIn wanted == 1 || S.notMember (packName (wordsIn wanted)) bound && M.notMember (packName (wordsIn wanted)) prog)
        collect packet xs
      _ | Just (f,tid,variant,xs)<-constructor constructors bound e, (tid,variant)==(t,v) -> do
            let adapter=worker "ctor" wanted f
            guard (S.notMember adapter bound && M.notMember adapter prog)
            guard (wordsIn wanted == 1 || M.notMember (packName (wordsIn wanted)) prog)
            modify' (\(i,required) -> (i,M.insert adapter (wordsIn wanted) required))
            collect (app adapter) xs
        | (CVar f,args@(_:_))<-spineOf e, S.notMember f bound,
          Just (params,_)<-M.lookup f prog, length params==length args,
          target f==Just wanted, let entry=worker "result" wanted f, S.notMember entry bound ->
            pure (app entry args,ordinary e)
        | otherwise -> lift Nothing
      where
        collect finish xs = do
          guard (length xs==length fields)
          -- All leaf evaluations remain strict, once each, from left to right.
          bindings<-zipWithM (\field x->do (rhs,u)<-emit bound field x; n<-fresh; pure (n,rhs,u,wordsIn field)) fields xs
          uses<-combine [u | (_,_,u,_)<-bindings]
          let values=[wordAt n width i | (n,_,_,width)<-bindings, i<-[0..width-1]]
          pure (foldr (\(n,rhs,_,_) b->CLet n rhs b) (finish values) bindings,uses)

-- A view names a contiguous slice of the result words. Only checked tests,
-- projections and lexical aliases may consume a virtual constructor.
nestedReader :: Nested -> Name -> Core -> Maybe Core
nestedReader plan root body = do
  guard (occurs root body)
  go (M.singleton root (nestedLayout plan,0)) body
  where
    width=wordsIn (nestedLayout plan)
    view env (CVar x) = M.lookup x env
    view env (CProj i e) = do
      (Node _ _ _ fs,off)<-view env e
      guard (i>=0 && i<length fs)
      pure (fs!!i,off+sum (map wordsIn (take i fs)))
    view _ _ = Nothing
    go env e
      | Just (Slot,i)<-view env e = Just (wordAt root width i)
      | Just _<-view env e = Nothing
      | otherwise = case e of
          CLet x a b | x==root -> Nothing
                     | Just slice@(Node{},_)<-view env a -> go (M.insert x slice env) b
                     | otherwise -> CLet x <$> go env a <*> go (M.delete x env) b
          CIf (CTagEq t v test) a b | Just (Node tid var _ _,_)<-view env test -> do
            guard (tid==t); go env (if var==v then a else b)
          CLam args b | any (\x->x `notElem` args && occurs x b) (M.keys env) -> Nothing
                      | otherwise -> Just e
          CIf c a b -> CIf <$> go env c <*> go env a <*> go env b
          CApp f x -> CApp <$> go env f <*> go env x
          CProj i a -> CProj i <$> go env a
          CTagEq t v a -> CTagEq t v <$> go env a
          CMk t v xs -> CMk t v <$> traverse (go env) xs
          _ -> Just e
