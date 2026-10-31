-- Guarded versioning for a bounded, immutable String scan. No caller contract
-- is assumed: zero trips and every failed entry guard use the original CFG.
-- The fast copy has i >= 0 and n <= strlen(s); its header establishes i < n.
-- Every back edge must carry exactly i+1, formed under that header guard.
-- Thus i remains nonnegative without wrapping, and each byte read is in range.
module Codegen.StringScan (versionScan) where

import Codegen.IR
import Codegen.ControlFlow
import Data.List (find)
import Data.Maybe (listToMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- One small loop per function, one string, one unit-stride index. Deliberate
-- admission limits bound code growth and leave more general loops unchanged.
versionScan :: Fn -> Fn
versionScan fn = maybe fn build candidate
  where
    blocks = fnBlocks fn
    byId = M.fromList [(bId b,b) | b <- blocks]
    defs = M.fromList [(v,(bId b,op)) | b <- blocks, Instr (Just (v,_)) op <- bInstrs b]
    op v = snd <$> M.lookup v defs
    flow = analyze fn
    dom a b = S.member a (M.findWithDefault S.empty b (dominators flow))
    outside v = maybe False ((== fnEntry fn) . fst) (M.lookup v defs)
                || any ((==v) . fst) (maybe [] bParams (M.lookup (fnEntry fn) byId))
    rawOf p v = v == p || op v == Just (OUntag p)
    rawSource v = case op v of
      Just (OUntag p) | outside p -> Just (p,True)
      _ | outside v -> Just (v,False)
      _ -> Nothing
    one v = op v == Just (OConstInt 1)
    zero v = op v == Just (OConstInt 0)
    address s a = op a == Just (OAddress s)
    lengthOf s v = case op v of Just (OLoad TInt a 8) -> address s a; _ -> False
    candidate = do
      [loop] <- pure (naturalLoops fn flow)
      preId <- loopPreheader loop
      if preId == fnEntry fn && length blocks <= 24 && sum (map (length . bInstrs) blocks) <= 160
        then pure () else Nothing
      pre <- M.lookup preId byId
      header <- M.lookup (loopHeader loop) byId
      TBr h arrivals <- pure (bTerm pre)
      TCondBr test exit exitArgs body bodyArgs <- pure (bTerm header)
      (_, OCmp Ge idx limit) <- M.lookup test defs
      -- No header effects may be speculated by the dispatch. The original
      -- header still executes in both copies, with exactly its original ops.
      if M.lookup body (predecessors flow) == Just (S.singleton h) && exit /= body && all (\(Instr _ o) -> opEffect o == Pure) (bInstrs header)
         && null exitArgs && null bodyArgs then pure () else Nothing
      (slot,(param,ty)) <- find (\(_, (p,t)) -> (t==TInt && idx==p) || (t==TVal && op idx==Just (OUntag p)))
                           (zip [0..] (bParams header))
      (bound,unboxBound) <- rawSource limit
      let incoming = [(b,args) | b <- blocks, (target,args) <- termSuccs (bTerm b), target==h, bId b/=preId]
          advance (b,args) = length args==length (bParams header) && dom body (bId b)
            && case (if ty==TVal then op (args !! slot) else Just (OTag (args !! slot))) of
              Just (OTag next) -> case M.lookup next defs of
                Just (d,OArith Add x k) -> dom body d && rawOf param x && one k
                Just (d,OArithU Add x k) -> dom body d && rawOf param x && one k
                _ -> False
              _ -> False
      if not (null incoming) && all advance incoming then pure () else Nothing
      -- Only the concrete managed String byte layout produced by StringRead.
      str <- listToMaybe [s | b <- blocks, dom body (bId b),
                        Instr _ (OLoadByte cursor 16) <- bInstrs b,
                        Just (OIndexByte a i) <- [op cursor], rawOf param i,
                        Just (OAddress s) <- [op a], outside s,
                        any (\(_,o) -> o==OTagTest 9000 0 s) (M.elems defs),
                        any (\v -> lengthOf s v) (M.keys defs)]
      if length arrivals == length (bParams header) then pure () else Nothing
      pure (pre,header,body,param,ty,arrivals !! slot,bound,unboxBound,str)
    build (pre,header,body,param,ty,start,bound,unboxBound,str) = compact (sweep result)
      where
        copied = filter ((/= bId pre) . bId) blocks
        nextB = 1 + maximum [n | b <- blocks, BId n <- [bId b]]
        nextV = 1 + maximum (0:[n | b <- blocks, (VId n,_) <- bParams b]
                               ++ [n | b <- blocks, Instr (Just (VId n,_)) _ <- bInstrs b])
        -- Six dispatch blocks, then a fresh SSA/CFG copy including its exits.
        labels = M.fromList [(bId b,BId n) | (b,n) <- zip copied [nextB+6..]]
        values = M.fromList (zip [v | b <- copied, v <- map fst (bParams b) ++ [v | Instr (Just (v,_)) _ <- bInstrs b]]
                                (map VId [nextV+10..]))
        rename v = M.findWithDefault v v values
        label b = M.findWithDefault b b labels
        [initial,limit,pActive,pNonneg,pInt,pString,addr,count,pLimit,z] = map VId [nextV..nextV+9]
        ins v t o = Instr (Just (v,t)) o
        unpack v input yes = ins v TInt (if yes then OUntag input else OArithU Add input z)
        original = bTerm pre
        TBr _ arrivals = original
        fallback p yes target = if yes then TCondBr p target [] (bId header) arrivals
                                      else TCondBr p (bId header) arrivals target []
        dispatch =
          [Block (BId nextB) [] [ins z TInt (OConstInt 0),unpack initial start (ty==TVal),unpack limit bound unboxBound,
                                ins pActive TPred (OCmp Lt initial limit)] (fallback pActive True (BId (nextB+1))),
           Block (BId (nextB+1)) [] [ins pNonneg TPred (OCmp Ge initial z)] (fallback pNonneg True (BId (nextB+2))),
           Block (BId (nextB+2)) [] [ins pInt TPred (OIsInt str)] (fallback pInt False (BId (nextB+3))),
           Block (BId (nextB+3)) [] [ins pString TPred (OTagTest 9000 0 str)] (fallback pString True (BId (nextB+4))),
           Block (BId (nextB+4)) [] [ins addr TAddr (OAddress str),ins count TInt (OLoad TInt addr 8),
                                    ins pLimit TPred (OCmp Le limit count)] (fallback pLimit True (BId (nextB+5))),
           Block (BId (nextB+5)) [] [] (TBr (label (bId header)) arrivals)]
        known b p = case op p of
          Just (OIsInt s) | s==str -> Just False
          Just (OTagTest 9000 0 s) | s==str -> Just True
          Just (OCmp Ge i k) | dom body (bId b), rawOf param i, zero k -> Just True
          Just (OCmp Lt i n) | dom body (bId b), rawOf param i, lengthOf str n -> Just True
          _ -> Nothing
        term b = case bTerm b of
          TCondBr p yes ys no ns | Just takeYes <- known b p -> if takeYes then TBr yes ys else TBr no ns
          t -> t
        targets t = case mapTermUses rename t of
          TBr b as -> TBr (label b) as
          TCondBr p y ys n ns -> TCondBr p (label y) ys (label n) ns
          t' -> t'
        -- Cached lengths are immutable. Keep each byte's OAddress(str) in
        -- the loop so the managed string remains live across fuel safepoints.
        lengths = M.fromList [(rename v,count) | v <- M.keys defs, lengthOf str v]
        use v = M.findWithDefault (rename v) (rename v) lengths
        clone b = Block (label (bId b)) [(rename v,t) | (v,t) <- bParams b]
          [Instr (fmap (\(v,t)->(rename v,t)) d) (mapOpUses use o)
          | Instr d o <- bInstrs b, not (maybe False (\(v,_)->lengthOf str v) d)]
          (mapTermUses (\v->M.findWithDefault v v lengths) (targets (term b)))
        result = fn {fnBlocks = [if bId b==bId pre then b {bTerm=TBr (BId nextB) []} else b | b<-blocks]
                                  ++ dispatch ++ map clone copied}
    sweep f = let live=reachable (analyze f) in f {fnBlocks=filter (\b->S.member (bId b) live) (fnBlocks f)}

-- Removing guards creates straight-line chains. Merge only an unconditional
-- edge into a block with exactly one predecessor, substituting its parameters
-- with that edge's arguments. This preserves instruction/trap/tick order and
-- avoids replacing cheap checks with a chain of machine jumps. Each step
-- deletes a block; loop headers with backedges cannot meet the admission rule.
compact :: Fn -> Fn
compact fn = case listToMaybe candidates of
  Nothing -> fn
  Just (source,target,args) -> compact fn {fnBlocks=map rewrite kept}
    where
      aliases=M.fromList (zip (map fst (bParams target)) args)
      use v=M.findWithDefault v v aliases
      kept=filter ((/=bId target) . bId) (fnBlocks fn)
      rewrite block =
        let b=if bId block==bId source then block
                {bInstrs=bInstrs source++bInstrs target,bTerm=bTerm target} else block
        in b {bInstrs=[Instr d (mapOpUses use o) | Instr d o<-bInstrs b],
              bTerm=mapTermUses use (bTerm b)}
  where
    flow=analyze fn
    blocks=M.fromList [(bId b,b) | b<-fnBlocks fn]
    candidates=[(b,target,args) | b<-fnBlocks fn,TBr next args<-[bTerm b],
                next/=bId b,next/=fnEntry fn,Just target<-[M.lookup next blocks],
                M.lookup next (predecessors flow)==Just (S.singleton (bId b)),
                length args==length (bParams target)]
