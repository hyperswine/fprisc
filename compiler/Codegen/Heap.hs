{-# LANGUAGE LambdaCase #-}
-- Cumulative allocation requests over the final verified builtin ARC IR.
-- Counts and requested bytes are separate upper bounds. No source annotation
-- supplies authority here; an unknown boundary never receives a zero cost.
module Codegen.Heap
  ( Demand(..), Equation(..), Key(..), Bound(..), fromFn, analyse, zero, plus, runtimeDemand, arenaBytes, admit ) where

import qualified Codegen.IR as I
import Codegen.Symbol (CodeSymbol(..))
import Codegen.Target.Common (calleeCodeSymbol,functionSymbol)
import Codegen.Target.RV.ScalarAdapters (scalarAdapter)
import Data.Graph (SCC(..),stronglyConnComp)
import Data.List (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Demand = Demand { requests :: Integer, requestedBytes :: Integer } deriving (Eq,Ord,Show)
zero :: Demand
zero = Demand 0 0
plus :: Demand -> Demand -> Demand
plus (Demand n b) (Demand m c) = Demand (n+m) (b+c)
maximumDemand :: [Demand] -> Demand
maximumDemand ds = Demand (maximum (0:map requests ds)) (maximum (0:map requestedBytes ds))
data Key = Entry CodeSymbol | Block CodeSymbol I.BId deriving (Eq,Ord,Show)
-- All calls execute in sequence; flow successors are alternatives.
data Equation = Equation { key :: Key, own :: Demand, calls :: [Key], flow :: [Key], unknown :: [String] }
  deriving (Eq,Show)
data Bound = Bounded Demand | Unproved [String] deriving (Eq,Show)

-- This constructor is valid only for builtin RV64 ARC selection: OMake calls
-- fpr_builtin_alloc_adt(8+8*fields). Other profiles need their own contract.
-- The caller provides the actual emitted visibility, not a source-name guess.
fromFn :: Bool -> I.Fn -> [Equation]
fromFn weak fn = Equation (Entry symbol) zero [] [local (I.fnEntry fn)]
  ["interposable-entry:"++codeName symbol | weak] : map block (I.fnBlocks fn)
  where
    symbol=CodeSymbol (functionSymbol (I.fnName fn))
    local=Block symbol
    block b = Equation (local (I.bId b)) (foldl' plus zero ds) cs successors ps
      where
        events=map (event . op) (I.bInstrs b) ++ case I.bTerm b of
          I.TTailCall c args -> [transfer c args]
          I.TUnreachable _ -> [(zero,[],["runtime:panic"])]
          _ -> []
        op (I.Instr _ o)=o
        ds=[d | (d,_,_)<-events]
        cs=concat [c | (_,c,_)<-events]
        ps=concat [p | (_,_,p)<-events]
        successors=map (local . fst) (I.termSuccs (I.bTerm b))
    transfer c args | Just _<-scalarAdapter c (length args) = (zero,[],[])
    transfer c _ = case I.calleeKind c of
      I.Foreign name -> case runtimeDemand (CodeSymbol name) of
        Just d -> (d,[],[])
        Nothing -> (zero,[],["runtime:"++name])
      _ -> (zero,[Entry (calleeCodeSymbol c)],[])
    event = \case
      I.OMake _ _ fs -> (Demand 1 (8+8*toInteger (length fs)),[],[])
      I.OCall c args -> transfer c args
      I.OCallProduct c args -> transfer c args
      I.OResult {} -> none
      I.OReuse {} -> none
      I.OLoad {} -> none
      I.OLoadByte {} -> none
      I.OStore {} -> none
      I.OSetField {} -> none
      o | I.opEffect o==I.Pure -> none
        | otherwise -> (zero,[],["unsupported-op:"++takeWhile (/=' ') (show o)])
    none=(zero,[],[])

-- Solve nonnegative cost equations by SCC. Acyclic components have exact
-- sum/max composition. Cycles are accepted only when their complete reachable
-- allocation demand is zero; positive or unknown cycles remain unproved.
-- This intentionally does not borrow source termination measures or infer
-- iteration counts from the presence of a back edge.
analyse :: [Equation] -> M.Map Key Bound
analyse equations
  | M.size table/=length equations = M.map (const (Unproved ["duplicate-allocation-key"])) table
  | otherwise = M.mapWithKey (\k _->results M.! (owners M.! k)) table
  where
    table=M.fromList [(key e,e) | e<-equations]
    deps e=calls e++flow e
    sccs=stronglyConnComp [(e,key e,deps e) | e<-equations]
    groups=M.fromList (zip [0::Int ..] [case s of AcyclicSCC e->[e];CyclicSCC es->es | s<-sccs])
    owners=M.fromList [(key e,i) | (i,es)<-M.toList groups,e<-es]
    results=foldl' (\m i->fst (visit m i)) M.empty (M.keys groups)
    visit memo i | Just b<-M.lookup i memo = (memo,b)
    visit memo i =
      let es=groups M.! i
          outside=[k | e<-es,k<-deps e,Just j<-[M.lookup k owners],j/=i]
          step m k=fst (visit m (owners M.! k))
          children=foldl' step memo outside
          boundOf k=children M.! (owners M.! k)
          localProblems=concatMap unknown es
            ++ ["negative-allocation-demand" | e<-es,requests (own e)<0 || requestedBytes (own e)<0]
            ++ ["missing:"++show k | e<-es,k<-deps e,M.notMember k table]
          problems=S.toAscList (S.fromList (localProblems++concat [p | k<-outside,Unproved p<-[boundOf k]]))
          recursive=length es>1 || any (\e->key e `elem` deps e) es
          positive=any ((/=zero) . own) es || any (\k->case boundOf k of Bounded d->d/=zero;_->False) outside
          cost e=foldl' plus (own e) [d | k<-calls e,Bounded d<-[boundOf k]]
            `plus` maximumDemand [d | k<-flow e,Bounded d<-[boundOf k]]
          answer | not (null problems) = Unproved problems
                 | recursive && positive = Unproved ["allocating-cycle:"++show (key (head es))]
                 | recursive = Bounded zero
                 | otherwise = Bounded (cost (head es))
      in (M.insert i answer children,answer)

-- Audited builtin C ARC contracts. Generic aggregate conversions and arbitrary
-- primitives are deliberately absent: they can allocate a data-dependent graph.
runtimeDemand :: CodeSymbol -> Maybe Demand
runtimeDemand (CodeSymbol name)
  | name `elem` map (prefix++) ["retain","release","setLayout","rawEq","rawNe",
      "uniformUnboxWord","uniformUnboxAddr","uniformUnboxF64","uniformUnboxF32",
      "uniformUnboxTagged","uniformUnboxText","uniformUnboxData","uniformProject"] = Just zero
  | name `elem` map (prefix++) ["uniformBoxWord","uniformBoxAddr","uniformBoxF64","uniformBoxF32"] = Just (Demand 1 24)
  | otherwise = Nothing
  where prefix="fpr_fn__x24arc_x2e"

-- Fresh aligned RV64 C heap: each ordinary request consumes at most its bytes
-- plus 80 prefix + 16 rounding/minimum + 80 unsplittable tail. All allocations,
-- including conversions, must be counted; realloc/regions are not admitted.
-- This cumulative bound is conservative, not a peak-liveness optimization.
arenaBytes :: Demand -> Either String Integer
arenaBytes (Demand n b)
  | n<0 || b<0 = Left "negative allocation demand"
  | n==0 && b/=0 = Left "bytes without allocation requests"
  | n==0 = Right 0
  | blocks>maxWord = Left "heap requirement exceeds RV64 address space"
  | otherwise = fit blocks
  where
    maxWord=2^(64::Int)-1
    align x=((x+15) `div` 16)*16
    blocks=align (b+176*n)
    bitmap spanBytes=align ((spanBytes+127) `div` 128)
    fit spanBytes
      | spanBytes>maxWord = Left "heap requirement exceeds RV64 address space"
      | next==spanBytes = Right spanBytes
      | otherwise = fit next
      where next=blocks+bitmap spanBytes

admit :: Integer -> [CodeSymbol] -> [Equation] -> Either String [(CodeSymbol,Demand,Integer)]
admit limit roots equations
  | limit<=0 || limit>=2^(64::Int) = Left "heap budget must fit a positive RV64 byte count"
  | null roots = Left "heap budget has no public callback entries"
  | length roots/=S.size (S.fromList roots) = Left "heap budget has duplicate public callback entries"
  | otherwise = traverse one roots
  where
    bounds=analyse equations
    one root = case M.lookup (Entry root) bounds of
      Nothing -> Left ("heap budget "++codeName root++": missing native entry")
      Just (Unproved reasons) -> Left ("heap budget "++codeName root++": UNPROVED "++show reasons)
      Just (Bounded d) -> do
        need<-arenaBytes d
        if need<=limit then Right (root,d,need)
          else Left ("heap budget "++codeName root++": needs "++show need++" bytes, limit "++show limit)
