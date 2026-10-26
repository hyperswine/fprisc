-- Shared CFG facts. Dominance includes the defining block itself; natural
-- loops merge every back edge to one header and reject irreducible entries.
module Codegen.ControlFlow (Flow(..),NaturalLoop(..),analyze,naturalLoops) where
import Codegen.IR
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Flow=Flow
  { successors :: M.Map BId (S.Set BId), predecessors :: M.Map BId (S.Set BId),
    reachable :: S.Set BId, dominators :: M.Map BId (S.Set BId) } deriving (Eq,Show)
data NaturalLoop=NaturalLoop
  { loopHeader :: BId, loopLatches :: S.Set BId, loopBlocks :: S.Set BId,
    loopPreheader :: Maybe BId } deriving (Eq,Show)

analyze :: Fn -> Flow
analyze fn=Flow succs preds live (fix start)
  where
    ids=S.fromList (map bId (fnBlocks fn))
    succs=M.fromList [(bId b,S.fromList (map fst (termSuccs (bTerm b)))) | b<-fnBlocks fn]
    preds=M.fromListWith S.union [(t,S.singleton (bId b)) | b<-fnBlocks fn,(t,_)<-termSuccs (bTerm b)]
    walk seen []=seen
    walk seen (b:bs)
      | S.member b seen || S.notMember b ids=walk seen bs
      | otherwise=walk (S.insert b seen) (S.toList (M.findWithDefault S.empty b succs)++bs)
    live=walk S.empty [fnEntry fn]
    start=M.fromSet (\b->if b==fnEntry fn || S.notMember b live then S.singleton b else live) ids
    step dm=M.mapWithKey (\b ds->if b==fnEntry fn || S.notMember b live then ds else
      let ps=S.toList (S.intersection live (M.findWithDefault S.empty b preds))
      in S.insert b (case ps of []->S.empty;p:rest->foldl S.intersection (dm M.! p) [dm M.! q | q<-rest])) dm
    fix dm=let next=step dm in if next==dm then dm else fix next

naturalLoops :: Fn -> Flow -> [NaturalLoop]
naturalLoops fn flow=
  [ NaturalLoop header latches members (preheader header members)
  | (header,latches)<-M.toList backs,let members=walk header (S.singleton header) (S.toList latches),
    all (S.member header . dom) (S.toList members) ]
  where
    dom b=M.findWithDefault S.empty b (dominators flow)
    preds b=M.findWithDefault S.empty b (predecessors flow)
    byId=M.fromList [(bId b,b) | b<-fnBlocks fn]
    backs=M.fromListWith S.union [(target,S.singleton source) | (source,ts)<-M.toList (successors flow),
      S.member source (reachable flow),target<-S.toList ts,S.member target (dom source)]
    walk _ seen []=seen
    walk h seen (b:bs)
      | S.member b seen=walk h seen bs
      | otherwise=walk h (S.insert b seen) (S.toList (preds b)++bs)
    preheader h members=case S.toList (preds h S.\\ members) of
      [p] | Just b<-M.lookup p byId,TBr target _<-bTerm b,target==h->Just p
      _->Nothing
