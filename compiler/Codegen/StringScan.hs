-- Guarded versioning for bounded, immutable String reads in a counted loop.
-- No caller contract is assumed: zero trips and every failed entry guard use
-- the original CFG. The dispatch checks i >= 0 at entry and, for each String
-- read in the loop, that the value is a String and that some exit test
-- `i >= n` dominating all of its reads has n <= strlen(s). Every back edge
-- carries exactly i+1, so in the fast copy i stays nonnegative without
-- wrapping and i < n <= strlen(s) at each read: the copy drops the reads'
-- String tests, length loads and bounds checks. Two strings compared in one
-- loop (the prelude's strCmpGo) qualify as one string scanned does.
module Codegen.StringScan (versionScan) where

import Codegen.IR
import Codegen.ControlFlow
import Data.List (find, nub)
import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- One small counted loop per function and one unit-stride index; deliberate
-- size limits bound the code growth (the whole body is copied once).
versionScan :: Fn -> Fn
versionScan fn
  -- most functions read no String bytes: no analysis for them
  | null [() | b <- fnBlocks fn, Instr _ (OLoadByte _ 16) <- bInstrs b] = fn
  | otherwise = maybe fn build candidate
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
      if preId == fnEntry fn && length blocks <= 48 && sum (map (length . bInstrs) blocks) <= 320
        then pure () else Nothing
      pre <- M.lookup preId byId
      header <- M.lookup (loopHeader loop) byId
      TBr h arrivals <- pure (bTerm pre)
      let members = loopBlocks loop
          inLoop b = S.member b members
          incoming = [(b,args) | b <- blocks, (target,args) <- termSuccs (bTerm b), target==h, bId b/=preId]
          -- the index: a header parameter every back edge advances by one
          advance param ty (b,args) slot = length args==length (bParams header) && inLoop (bId b)
            && case (if ty==TVal then op (args !! slot) else Just (OTag (args !! slot))) of
              Just (OTag next) -> case M.lookup next defs of
                Just (d,OArith Add x k) -> inLoop d && rawOf param x && one k
                Just (d,OArithU Add x k) -> inLoop d && rawOf param x && one k
                _ -> False
              _ -> False
      (slot,(param,ty)) <- find (\(k,(p,t)) -> not (null incoming) && all (\e -> advance p t e k) incoming)
                                 (zip [0..] (bParams header))
      if length arrivals == length (bParams header) then pure () else Nothing
      -- exit tests i >= n (n invariant): leaving the loop on true, staying on false
      let limits = [(no,n) | b <- blocks, inLoop (bId b), TCondBr t yes [] no [] <- [bTerm b],
                             Just (OCmp Ge i n) <- [op t], rawOf param i, Just _ <- [rawSource n],
                             not (inLoop yes), inLoop no]
          -- the managed String layout produced by StringRead, per string
          strings = nub [s | b <- blocks, inLoop (bId b), Instr _ (OLoadByte cursor 16) <- bInstrs b,
                             Just (OIndexByte a i) <- [op cursor], rawOf param i,
                             Just (OAddress s) <- [op a], outside s]
          readBlocks s = [bId b | b <- blocks, inLoop (bId b),
                                  any (\(Instr d o) -> maybe False (\(v,_) -> lengthOf s v) d
                                                       || case o of OLoadByte c 16 -> maybe False (\x -> case x of OIndexByte a _ -> address s a; _ -> False) (op c); _ -> False)
                                      (bInstrs b)]
          bound s = nub [n | (no,n) <- limits, all (dom no) (readBlocks s)]
          admitted = [(s,bound s) | s <- strings, not (null (bound s)),
                                    any (\b -> any (\(Instr _ o) -> o==OTagTest 9000 0 s || o==OVariantTest 9000 0 s) (bInstrs b)) blocks]
      if not (null admitted) && length admitted == length strings then pure () else Nothing
      pure (pre,header,param,ty,arrivals !! slot,admitted)
    build (pre,header,param,ty,start,admitted) = compact (sweep result)
      where
        copied = filter ((/= bId pre) . bId) blocks
        nextB = 1 + maximum [n | b <- blocks, BId n <- [bId b]]
        nextV = 1 + maximum (0:[n | b <- blocks, (VId n,_) <- bParams b]
                               ++ [n | b <- blocks, Instr (Just (VId n,_)) _ <- bInstrs b])
        ins v t o = Instr (Just (v,t)) o
        TBr _ arrivals = bTerm pre
        -- the dispatch's values and blocks, numbered from nextV / nextB
        z = VId nextV
        initial = VId (nextV+1)
        pNonneg = VId (nextV+2)
        perString = zip admitted [nextV+3,nextV+3+(4+2*maxLimits)..]
        maxLimits = maximum (1:[length ns | (_,ns) <- admitted])
        firstClone = nextV+3+(4+2*maxLimits)*length admitted
        countOf = M.fromList [(s,VId (base+2)) | ((s,_),base) <- perString]
        unpack v input yes = ins v TInt (if yes then OUntag input else OArithU Add input z)
        toOriginal = (bId header,arrivals)
        -- block ids: B0, then per string one test block, one load block and
        -- one block per limit; then the jump into the copy
        stringBlocks = scanl (+) (nextB+1) [2+length ns | (_,ns) <- admitted]
        enterCopy = BId (last stringBlocks)
        firstBlock k = BId (stringBlocks !! k)
        nextString k = if k+1 < length admitted then firstBlock (k+1) else enterCopy
        fallback p target = TCondBr p target [] (fst toOriginal) (snd toOriginal)
        dispatch =
          Block (BId nextB) [] [ins z TInt (OConstInt 0), unpack initial start (ty==TVal),
                                ins pNonneg TPred (OCmp Ge initial z)] (fallback pNonneg (firstBlock 0))
          : concat [stringDispatch k s ns base | (k,((s,ns),base)) <- zip [0..] perString]
          ++ [Block enterCopy [] [] (TBr (label (bId header)) arrivals)]
        stringDispatch k s ns base =
          let BId b0 = firstBlock k
              pStr = VId base; addr = VId (base+1); count = VId (base+2)
              limitBlock j n =
                let (src,yes) = maybe (n,False) id (rawSource n)
                    raw = VId (base+3+2*j); pFits = VId (base+4+2*j)
                    otherwise' = if j+1 < length ns then TCondBr pFits (nextString k) [] (BId (b0+3+j)) []
                                 else fallback pFits (nextString k)
                in Block (BId (b0+2+j)) [] [unpack raw src yes, ins pFits TPred (OCmp Le raw count)] otherwise'
          in [Block (BId b0) [] [ins pStr TPred (OVariantTest 9000 0 s)] (fallback pStr (BId (b0+1))),
              Block (BId (b0+1)) [] [ins addr TAddr (OAddress s), ins count TInt (OLoad TInt addr 8)] (TBr (BId (b0+2)) [])]
             ++ zipWith limitBlock [0..] ns
        -- the copy: fresh labels and values
        labels = M.fromList [(bId b,BId n) | (b,n) <- zip copied [last stringBlocks+1..]]
        values = M.fromList (zip [v | b <- copied, v <- map fst (bParams b) ++ [v | Instr (Just (v,_)) _ <- bInstrs b]]
                                (map VId [firstClone..]))
        rename v = M.findWithDefault v v values
        label b = M.findWithDefault b b labels
        proven s = M.member s countOf
        known p = case op p of
          Just (OIsInt s) | proven s -> Just False
          Just (OTagTest 9000 0 s) | proven s -> Just True
          Just (OVariantTest 9000 0 s) | proven s -> Just True
          Just (OCmp Ge i k) | rawOf param i, zero k -> Just True
          Just (OCmp Lt i n) | rawOf param i, any (\s -> lengthOf s n) (M.keys countOf) -> Just True
          _ -> Nothing
        term b = case bTerm b of
          TCondBr p yes ys no ns | Just takeYes <- known p -> if takeYes then TBr yes ys else TBr no ns
          t -> t
        targets t = case mapTermUses rename t of
          TBr b as -> TBr (label b) as
          TCondBr p y ys n ns -> TCondBr p (label y) ys (label n) ns
          t' -> t'
        -- each String's length comes from the dispatch (immutable)
        lengths = M.fromList [(rename v,count) | v <- M.keys defs, (s,count) <- M.toList countOf, lengthOf s v]
        use v = M.findWithDefault (rename v) (rename v) lengths
        isLength v = any (\s -> lengthOf s v) (M.keys countOf)
        clone b = Block (label (bId b)) [(rename v,t) | (v,t) <- bParams b]
          [Instr (fmap (\(v,t)->(rename v,t)) d) (mapOpUses use o)
          | Instr d o <- bInstrs b, not (maybe False (\(v,_)->isLength v) d)]
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
