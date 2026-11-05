-- Physical generated-code stack accounting, after allocation and layout.
-- This is a closed-unit bound, not an image/arena admission certificate:
-- runtime, foreign, imported and dynamic boundaries have no assumed cost.
module Codegen.Stack
  ( ABI(..), Edge(..), Frame(..), Bound(..), selectedFrame, analyse, admit, reportLine ) where

import Codegen.Call
import Codegen.Calling.Types (Transfer(..),TransferResult(..))
import Codegen.Frame (Layout(..))
import qualified Codegen.Opcode as O
import Codegen.Protocol (embedded,Embedded(..))
import Codegen.Selected
import Data.Graph (SCC(..),stronglyConnComp)
import Data.List (foldl',intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data ABI = LinkRegister | StackReturnAddress deriving (Eq,Show)
-- Retained bytes are relative to the same pre-call SP as the callee's
-- frame. A tail transfer restores that SP, including x64's shared return PC.
data Edge = Edge {edgeTarget :: CodeSymbol, edgeRetained :: Integer}
  deriving (Eq,Ord,Show)
data Frame = Frame
  { frameSymbol :: CodeSymbol,
    frameLocal :: Integer,
    frameEdges :: [Edge],
    frameUnknown :: [String]
  } deriving (Eq,Show)
data Bound = Bounded Integer | Unproved [String] deriving (Eq,Show)

-- The renderer owns the ABI, final layout and out-of-stream entry shims.
-- Explicit unknowns cover segmented-stack reservation and Darwin TLV calls.
-- Calls and argument packets come from the checked, allocated stream.
selectedFrame :: ABI -> Layout -> CodeSymbol -> [String] -> [Item] -> Frame
selectedFrame abi ly sym extra items = Frame sym local edges unknown
  where
    local = toInteger (lyBytes ly) + case abi of LinkRegister->0;StackReturnAddress->8
    pad = case abi of LinkRegister->0;StackReturnAddress->8
    ins = [i | I i<-items]
    tailTransfer i = siOpcode i==O.Common O.TailJump
      && maybe False ((==TailTransfer) . transferResult) (siTransfer i)
    edges = S.toAscList (S.fromList
      [Edge (callTarget c) (if tailTransfer i then 0 else local+pad)
      | i<-ins,c<-siCalls i,CalleeEntry _<-[callEffect c]])
    -- Deduplicate symbols before constructing diagnostic strings. Inlined
    -- ticks/refills can repeat one runtime boundary many times in a function.
    runtimeTargets=S.fromList [callTarget c | i<-ins,c<-siCalls i,
      case callEffect c of CalleeEntry _->False;_->True]
    unknown = extra
      ++ ["invalid-frame-layout" | lyBytes ly<0]
      ++ ["runtime:"++codeName target | target<-S.toAscList runtimeTargets]
      ++ ["dynamic-argument-packet" | any ((==Just PushArgument) . embedded . siOpcode) ins]

-- Collapse tail-only SCCs: arbitrary tail recursion has bounded stack.
-- Any retaining edge inside an SCC refuses a bound, including mixed
-- ordinary/tail recursion. No source termination annotation is trusted here.
-- All selected blocks are included, even when a source path is infeasible.
analyse :: [Frame] -> M.Map CodeSymbol Bound
analyse frames
  | M.size table/=length frames = M.map (const (Unproved ["duplicate-code-symbol"])) table
  | otherwise = knownBad `M.union` M.mapWithKey (\sym _->results M.! (owners M.! sym)) candidates
  where
    table = M.fromList [(frameSymbol f,f) | f<-frames]
    -- A known local runtime boundary needs no call-graph construction. In
    -- particular do not force its (potentially large) selected edge list.
    -- Calls into these functions remain explicit failures in the candidate
    -- graph, so removing them cannot turn a broken cycle into a finite proof.
    (badFrames,candidates)=M.partition (not . null . frameUnknown) table
    knownBad=M.map (Unproved . S.toAscList . S.fromList . frameUnknown) badFrames
    sccs = stronglyConnComp [(f,frameSymbol f,map edgeTarget (frameEdges f)) | f<-M.elems candidates]
    groups = M.fromList (zip [0::Int ..] [case s of AcyclicSCC f->[f];CyclicSCC fs->fs | s<-sccs])
    owners = M.fromList [(frameSymbol f,k) | (k,fs)<-M.toList groups,f<-fs]
    results = foldl' (\memo k->fst (visit memo k)) M.empty (M.keys groups)
    visit memo k | Just b<-M.lookup k memo = (memo,b)
    visit memo k =
      let fs = groups M.! k
          es = [(f,e) | f<-fs,e<-frameEdges f]
          localProblems = concatMap frameUnknown fs
            ++ ["invalid-frame-size" | f<-fs,frameLocal f<0]
            ++ ["invalid-retained-size" | (_,e)<-es,edgeRetained e<0]
            ++ ["missing:"++codeName (edgeTarget e) | (_,e)<-es,M.notMember (edgeTarget e) table]
            ++ concat [ps | (_,e)<-es,Just (Unproved ps)<-[M.lookup (edgeTarget e) knownBad]]
            ++ ["recursive-stack:"++codeName (frameSymbol f) | (f,e)<-es,
                 M.lookup (edgeTarget e) owners==Just k,edgeRetained e>0]
          outgoing = [(edgeRetained e,j) | (_,e)<-es,Just j<-[M.lookup (edgeTarget e) owners],j/=k]
          step (m,bs) (retained,j) = let (m',b)=visit m j in
            (m',case b of Bounded n->Bounded (retained+n):bs;_->b:bs)
          (memo',children) = foldl' step (memo,[]) outgoing
          problems = S.toAscList (S.fromList (localProblems++concat [ps | Unproved ps<-children]))
          bound | null problems = Bounded (maximum (0:map frameLocal fs++[n | Bounded n<-children]))
                | otherwise = Unproved problems
      -- A local refusal already proves this component unadmittable. Do not
      -- accumulate every descendant's runtime reason into it (hosted entry
      -- checks make that wasted work in almost every function). Each child
      -- still gets its own report from the outer fold. No finite answer is
      -- inferred by skipping these edges.
      in if null localProblems then (M.insert k bound memo',bound)
         else let refused=Unproved (S.toAscList (S.fromList localProblems))
              in (M.insert k refused memo,refused)

-- Admission is against requested entry symbols, not every unused constructor
-- in a library. Missing/unknown entries never acquire a zero default.
admit :: Integer -> [CodeSymbol] -> [Frame] -> Either String [(CodeSymbol,Integer)]
admit limit roots frames
  | limit<=0 = Left "stack budget must be a positive byte count"
  | null roots = Left "stack budget has no public callback entries"
  | length roots/=S.size (S.fromList roots) = Left "stack budget has duplicate public callback entries"
  | otherwise = traverse one roots
  where
    bounds=analyse frames
    one root = case M.lookup root bounds of
      Nothing->Left ("stack budget "++codeName root++": missing native entry")
      Just (Unproved reasons)->Left ("stack budget "++codeName root++": UNPROVED ("++intercalate ", " reasons++")")
      Just (Bounded n)
        | n<=limit->Right (root,n)
        | otherwise->Left ("stack budget "++codeName root++": needs "++show n++" bytes, limit "++show limit)

reportLine :: Frame -> Bound -> String
reportLine f b = "# native-stack-v1: "++codeName (frameSymbol f)
  ++" local="++show (frameLocal f)++" peak="++case b of
    Bounded n->show n
    Unproved reasons->"UNPROVED reasons="++intercalate "," reasons
