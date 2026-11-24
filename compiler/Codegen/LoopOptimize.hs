-- Speculate only total register operations into existing unique preheaders.
-- Pure in the IR is not sufficient: field/tag/string reads may dereference
-- pointers, and hart/region reads can change across a safepoint.
module Codegen.LoopOptimize (moveInvariants, moveViews, carryRaw, carryRawI64, dropUnusedParameters, formSelfLoop) where
import Codegen.IR
import Codegen.ControlFlow
import Codegen.Policy
import Codegen.Pressure
import Data.List (sortOn,foldl')
import Data.Maybe (isJust,listToMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

moveInvariants :: Maybe RegisterBudget -> Bool -> Fn -> Fn
moveInvariants=moveWhere speculatable

-- Vector views alone, whatever the policy says of general motion: a view
-- left in a loop repeats its tests and loads on every iteration.
moveViews :: Fn -> Fn
moveViews=moveWhere (\op->case op of OVectorView {}->True;_->False) Nothing False

moveWhere :: (Op -> Bool) -> Maybe RegisterBudget -> Bool -> Fn -> Fn
moveWhere wanted budget inlineFloats fn=
  let moved=foldl' move fn (sortOn (S.size . loopBlocks) (naturalLoops fn flow))
  in if moved==fn then fn else dropUnusedParameters moved
  where
    flow=analyze fn
    move f loop | Just pre<-loopPreheader loop =
      let members=loopBlocks loop
          defs=M.fromList [(v,bId b) | b<-fnBlocks f,(v,_)<-blockDefs b]
          dominates d b=S.member d (M.findWithDefault S.empty b (dominators flow))
          incoming=M.fromListWith (++) [(target,[args]) | b<-fnBlocks f,(target,args)<-termSuccs (bTerm b)]
          -- Inlined callbacks take captures as block parameters. Resolve
          -- single-source copies only when their source strictly dominates
          -- the parameter; loop-carried/conditional phis stay untouched.
          aliases=M.fromList [(param,arg) | b<-fnBlocks f,bId b/=fnEntry f,
            Just [args]<-[M.lookup (bId b) incoming],((param,_),arg)<-zip (bParams b) args,
            Just d<-[M.lookup arg defs],d/=bId b,dominates d (bId b)]
          resolve v=maybe v resolve (M.lookup v aliases)
          available moved v=S.member v moved || maybe False (\d->S.notMember d members && dominates d pre) (M.lookup (resolve v) defs)
          loopInstrs=[i | b<-fnBlocks f,S.member (bId b) members,i<-bInstrs b]
          candidates=[(v,Instr (Just (v,t)) (mapOpUses resolve op)) | Instr (Just (v,t)) op<-loopInstrs,wanted op]
          choose excluded=go S.empty []
            where
              go moved chosen =
                let (moved',chosen')=foldl' (\(ready,out) (v,i@(Instr _ op))->
                      if S.size ready<16 && S.notMember v ready && S.notMember v excluded && all (available ready) (opUses op)
                        then (S.insert v ready,out++[i]) else (ready,out)) (moved,chosen) candidates
                in if moved'==moved then (moved,chosen) else go moved' chosen'
          -- A rematerializable value (a constant or a static address) moves
          -- only when nothing left in the loop still reads it: hoisting it
          -- otherwise keeps one more register busy for the whole loop to
          -- save an instruction the loop could repeat for free.
          stillRead moving v=any (elem v) ([opUses op | Instr d op<-loopInstrs,maybe True (\(u,_)->S.notMember u moving) d]
            ++ [termUses (bTerm b) | b<-fnBlocks f,S.member (bId b) members])
          settle excluded=
            let (moving,chosen)=choose excluded
                bad=[v | Instr (Just (v,_)) op<-chosen,cheap op,stillRead moving v]
            in if null bad then chosen else settle (S.union excluded (S.fromList bad))
          instructions=settle S.empty
          apply chosen=
            let moving=S.fromList [v | Instr (Just (v,_)) _<-chosen]
                rewrite b | bId b==pre=b {bInstrs=bInstrs b++chosen}
                          | S.member (bId b) members=b {bInstrs=[i | i@(Instr d _)<-bInstrs b,maybe True (\(v,_)->S.notMember v moving) d]}
                          | otherwise=b
            in f {fnBlocks=map rewrite (fnBlocks f)}
          -- The register-pressure gate (Codegen.Pressure): the longest
          -- prefix of the dependency-ordered moves whose loop fits the
          -- target's registers; when no prefix fits (the loop was already
          -- over budget), the longest that needs no more than before.
          pressureOf chosen=case budget of
            Just b->loopPressure b inlineFloats (dropUnusedParameters (apply chosen)) members
            Nothing->Pressure 0 0 0 0
          longest ok lo hi | lo>=hi=lo
                           | otherwise=let mid=(lo+hi+1) `div` 2 in if ok (take mid instructions) then longest ok mid hi else longest ok lo (mid-1)
          n=length instructions
          admitted=case budget of
            Nothing->instructions
            Just b
              | fitsBudget b (pressureOf instructions)->instructions
              | k<-longest (fitsBudget b . pressureOf) 0 n,k>0->take k instructions
              | otherwise->let before=loopPressure b inlineFloats f members
                           in take (longest (\c->noWorse (pressureOf c) before) 0 n) instructions
          noWorse a b=prGpr a<=prGpr b && prFpr a<=prFpr b && prGprAcross a<=prGprAcross b && prFprAcross a<=prFprAcross b
          -- A vector view is some twenty instructions of tests and loads:
          -- repeating it every iteration costs far more than the registers
          -- it holds, so it moves whatever the pressure. The rest are then
          -- weighed against the loop that has it outside.
          views=[i | i@(Instr _ (OVectorView {}))<-instructions]
      -- nothing to move: no pressure analysis either (the costly part)
      in if not (null views) then move (apply views) loop
         else if null instructions || null admitted then f else apply admitted
    move f _=f

cheap :: Op -> Bool
cheap op=case op of
  OConstInt {}->True; OBits {}->True; ONullary {}->True; OSymbol {}->True; OFunValue {}->True
  _->False

speculatable :: Op -> Bool
speculatable op=case op of
  OConstInt {}->True; ONullary {}->True; OBits {}->True
  OAddress {}->True; OIndex {}->True; OTag {}->True; OUntag {}->True; OVectorView {}->True
  OBoolOf {}->True; ONot {}->True; OIsInt {}->True
  OSymbol {}->True; OFunValue {}->True; OBit {}->True; OCmp {}->True
  OFloatBin {}->True; OFloat32Bin {}->True; OFloatCmp {}->True; OFloat32Cmp {}->True; OFloatOfInt {}->True
  OI64Arith {}->True; OI64Bit {}->True; OI64Cmp {}->True
  OFloatTree {}->True; OFloat32Tree {}->True; OFloatCmpTree {}->True; OFloat32CmpTree {}->True
  _->False

-- Captures whose computations moved out of an inlined callback no longer
-- need its parallel-copy parameters. Leaving those dead copies in place
-- needlessly extends native live ranges and can turn motion into spills.
dropUnusedParameters :: Fn -> Fn
dropUnusedParameters fn=
  let used=S.fromList [v | block<-fnBlocks fn,v<-concatMap (\(Instr _ op)->opUses op) (bInstrs block)++termUses (bTerm block)]
      masks=M.fromList [(bId block,[bId block==fnEntry fn || S.member v used | (v,_)<-bParams block]) | block<-fnBlocks fn]
      keep target xs=[x | (x,True)<-zip xs (masks M.! target)]
      term t=case t of
        TBr target args->TBr target (keep target args)
        TCondBr p yes as no bs->TCondBr p yes (keep yes as) no (keep no bs)
        _->t
      next=fn {fnBlocks=[block {bParams=keep (bId block) (bParams block),bTerm=term (bTerm block)} | block<-fnBlocks fn]}
  in if next==fn then fn else dropUnusedParameters next

-- Loop-carried Ints, untagged. A header parameter p (a tagged word) that
-- every back edge passes as a freshly tagged Int (OTag x) gets a raw
-- companion r: the preheader passes untag of its arrival, each back edge
-- its x, and every `untag p` reads r instead. By induction r == untag p on
-- every iteration, whatever the arrival is (untag is total), so the answer
-- is exact. p stays for any tagged use; when none is left it goes
-- (dropUnusedParameters) and so do the back edges' tags (dropDeadPure).
carryRaw :: Fn -> Fn
carryRaw fn0=go fn0 (12::Int)
  where
    go fn 0=fn
    go fn n=case [r | loop<-naturalLoops fn (analyze fn), Just r<-[step fn loop]] of
      f:_ -> go f (n-1)
      [] -> fn
    step fn loop=do
      pre<-loopPreheader loop
      let h=loopHeader loop
          byId=M.fromList [(bId b,b) | b<-fnBlocks fn]
          defs=M.fromList [(v,o) | b<-fnBlocks fn,Instr (Just (v,_)) o<-bInstrs b]
      header<-M.lookup h byId
      preBlock<-M.lookup pre byId
      TBr h' preArgs<-Just (bTerm preBlock)
      if h'==h && h/=fnEntry fn then Just () else Nothing
      let latchArgs=[args | b<-fnBlocks fn,bId b/=pre,(t,args)<-termSuccs (bTerm b),t==h]
          tagged a=case M.lookup a defs of Just (OTag x)->Just x; _->Nothing
          untags p=[w | b<-fnBlocks fn,Instr (Just (w,TInt)) (OUntag q)<-bInstrs b,q==p]
      (k,(p,_))<-listToMaybe [(k,pt) | (k,pt@(p,TVal))<-zip [0..] (bParams header),
                               not (null latchArgs),all (\args->length args==length (bParams header)
                                                             && isJust (tagged (args!!k))) latchArgs,
                               not (null (untags p))]
      let top=1+maximum (0:[i | b<-fnBlocks fn,(VId i,_)<-bParams b]++[i | b<-fnBlocks fn,Instr (Just (VId i,_)) _<-bInstrs b])
          r=VId top; u=VId (top+1)
          dropped=S.fromList (untags p)
          rename v=if S.member v dropped then r else v
          extend t=case t of
            TBr t' as | t'==h -> TBr t' (as++[raw as])
            TCondBr c y ys n' ns -> TCondBr c y (if y==h then ys++[raw ys] else ys) n' (if n'==h then ns++[raw ns] else ns)
            other -> other
          raw as=maybe r id (tagged (as!!k))
          block b
            | bId b==pre=b {bInstrs=bInstrs b++[Instr (Just (u,TInt)) (OUntag (preArgs!!k))],bTerm=TBr h (preArgs++[u])}
            | otherwise=
                let b'=if bId b==h then b {bParams=bParams b++[(r,TInt)]} else b
                in b' {bInstrs=[Instr d (mapOpUses rename o) | Instr d o<-bInstrs b',maybe True (\(w,_)->S.notMember w dropped) d],
                       bTerm=mapTermUses rename (extend (bTerm b'))}
      Just fn {fnBlocks=map block (fnBlocks fn)}

-- C6 stage 3d: an I64 loop value carried as its raw bits.  A loop header's
-- parameter that every back edge passes as a fresh I64 box (Lower.i64Box),
-- and that the loop reads only through its bits (Lower.i64Bits), gets a raw
-- twin parameter; the loads read the twin.  A use of the boxed parameter
-- outside the loop (an exit returning it) is given a box built there from
-- the twin, once per exit block.  Any other use inside the loop leaves the
-- loop alone: a box per iteration there is what the latch builds now.  The
-- boxed parameter and the latch boxes then die (Simplify.forwardI64Bits).
carryRawI64 :: Fn -> Fn
carryRawI64 fn0=go fn0 (12::Int)
  where
    go fn 0=fn
    go fn n=case [r | loop<-naturalLoops fn (analyze fn), Just r<-[step fn loop]] of
      f:_ -> go f (n-1)
      [] -> fn
    step fn loop=do
      pre<-loopPreheader loop
      let h=loopHeader loop
          members=loopBlocks loop
          byId=M.fromList [(bId b,b) | b<-fnBlocks fn]
          defs=M.fromList [(v,o) | b<-fnBlocks fn,Instr (Just (v,_)) o<-bInstrs b]
      header<-M.lookup h byId
      preBlock<-M.lookup pre byId
      TBr h' preArgs<-Just (bTerm preBlock)
      if h'==h && h/=fnEntry fn then Just () else Nothing
      let latchArgs=[args | b<-fnBlocks fn,bId b/=pre,(t,args)<-termSuccs (bTerm b),t==h]
          boxed a=case M.lookup a defs of Just (OMake 9004 4 [_,x])->Just x; _->Nothing
          -- the OAddress of p and the bit loads through it
          addrs p=S.fromList [a | b<-fnBlocks fn,Instr (Just (a,TAddr)) (OAddress q)<-bInstrs b,q==p]
          loadsOf as=[w | b<-fnBlocks fn,Instr (Just (w,TVal)) (OLoad TVal a 16)<-bInstrs b,S.member a as]
          -- every other use of p: in which blocks
          otherUses p as=[bId b | b<-fnBlocks fn,
                            any (\(Instr d o)->p `elem` opUses o && not (maybe False (\(a,_)->S.member a as) d && isAddrOf p o)) (bInstrs b)
                            || p `elem` termUses (bTerm b)]
          addrUsedElsewhere as=or [any (`S.member` as) (opUses o) | b<-fnBlocks fn,Instr _ o<-bInstrs b,not (isBitLoad as o)]
                               || or [any (`S.member` as) (termUses (bTerm b)) | b<-fnBlocks fn]
      (k,p)<-listToMaybe [(k,p) | (k,(p,TVal))<-zip [0..] (bParams header),
                            not (null latchArgs),all (\args->length args==length (bParams header) && isJust (boxed (args!!k))) latchArgs,
                            let as=addrs p, not (null (loadsOf as)), not (addrUsedElsewhere as),
                            all (`S.notMember` members) (otherUses p as)]
      let as=addrs p
          top=1+maximum (0:[i | b<-fnBlocks fn,(VId i,_)<-bParams b]++[i | b<-fnBlocks fn,Instr (Just (VId i,_)) _<-bInstrs b])
          r=VId top; u=VId (top+1)
          dropped=S.fromList (loadsOf as)
          exits=S.fromList (otherUses p as)
          extend t=case t of
            TBr t' xs | t'==h -> TBr t' (xs++[raw xs])
            TCondBr c y ys n' ns -> TCondBr c y (if y==h then ys++[raw ys] else ys) n' (if n'==h then ns++[raw ns] else ns)
            other -> other
          raw xs=maybe r id (boxed (xs!!k))
          -- fresh names for the exit boxes: two per exit block
          exitNames=M.fromList (zip (S.toList exits) [(VId (top+2+2*i),VId (top+3+2*i)) | i<-[0..]])
          rebox b=case M.lookup (bId b) exitNames of
            Nothing->b
            Just (wv,pb)->let ren v=if v==p then pb else v
                          in b {bInstrs=[Instr (Just (wv,TVal)) (OBits 64),Instr (Just (pb,TVal)) (OMake 9004 4 [wv,r])]
                                         ++[Instr d (mapOpUses ren o) | Instr d o<-bInstrs b],
                                bTerm=mapTermUses ren (bTerm b)}
          rename v=if S.member v dropped then r else v
          block b
            | bId b==pre=b {bInstrs=bInstrs b++[Instr (Just (u,TAddr)) (OAddress (preArgs!!k)),Instr (Just (VId (top+2+2*S.size exits),TVal)) (OLoad TVal u 16)],
                            bTerm=TBr h (preArgs++[VId (top+2+2*S.size exits)])}
            | otherwise=
                let b'=if bId b==h then b {bParams=bParams b++[(r,TVal)]} else b
                    b''=b' {bInstrs=[Instr d (mapOpUses rename o) | Instr d o<-bInstrs b',maybe True (\(w,_)->S.notMember w dropped) d],
                            bTerm=mapTermUses rename (extend (bTerm b'))}
                in rebox b''
      Just fn {fnBlocks=map block (fnBlocks fn)}
    isAddrOf p o=case o of OAddress q->q==p; _->False
    isBitLoad as o=case o of OLoad TVal a 16->S.member a as; _->False

-- Loop form recognition (formerly Codegen.LoopOptimize)
formSelfLoop :: Policy -> Fn -> Fn
formSelfLoop policy fn
  | not (polEarlyLoops policy) = fn
  | [entry] <- [b | b <- blocks, bId b == fnEntry fn]
  , not (null backs)
  , all directEntryEdge blocks
  , take (length prefix) (bInstrs entry) == prefix
  , all (\(Instr _ op) -> op /= OStackCheck) (drop (length prefix) (bInstrs entry))
  = let params = bParams entry
        arrivals = zipWith (\n (_,t) -> (VId n,t)) [nextV..] params
        -- A parameter passed unchanged on EVERY back edge is its arrival
        -- value on every iteration. Keep it outside the carried tuple so
        -- invariant motion can see the defining block dominate the loop.
        invariant = [all (\b -> case bTerm b of TBr _ args -> args !! i == v; _ -> False) backs
                    | (i,(v,_)) <- zip [0..] params]
        aliases = M.fromList [(v,a) | ((v,_),(a,_),True) <- zip3 params arrivals invariant]
        rename v = M.findWithDefault v v aliases
        carried xs = [x | (x,False) <- zip xs invariant]
        pre = Block (BId nextB) arrivals prefix (TBr (fnEntry fn) (carried (map fst arrivals)))
        rewrite b =
          let self = case bTerm b of TBr target _ -> target == fnEntry fn; _ -> False
              ops = if bId b == fnEntry fn then drop (length prefix) (bInstrs b) else bInstrs b
              term = case bTerm b of
                TBr target args | self -> TBr target (carried args)
                other -> other
          in b { bParams = if bId b == fnEntry fn then carried (bParams b) else bParams b,
                 bInstrs = [Instr d (mapOpUses rename op) | Instr d op <- ops ++ [Instr Nothing OSafepoint | self && polFuel policy]],
                 bTerm = mapTermUses rename term }
    in fn {fnEntry = bId pre, fnBlocks = pre : map rewrite blocks}
  | otherwise = fn
  where
    blocks = fnBlocks fn
    entryArity = length (concat [bParams e | e <- blocks, bId e == fnEntry fn])
    prefix = [Instr Nothing OStackCheck | polStackCheck policy /= StackStatic]
          ++ [Instr Nothing OSafepoint | polFuel policy]
    backs = [b | b <- blocks, TBr target args <- [bTerm b], target == fnEntry fn,
                 length args == entryArity]
    backIds = S.fromList (map bId backs)
    directEntryEdge b = case bTerm b of
      TBr target _ | target == fnEntry fn -> S.member (bId b) backIds
      t -> all ((/= fnEntry fn) . fst) (termSuccs t)
    nextB = 1 + maximum (0 : [n | b <- blocks, BId n <- [bId b]])
    nextV = 1 + maximum (0 : [n | b <- blocks, (VId n,_) <- bParams b]
                          ++ [n | b <- blocks, Instr (Just (VId n,_)) _ <- bInstrs b])
