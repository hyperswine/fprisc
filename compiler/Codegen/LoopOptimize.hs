-- Speculate only total register operations into existing unique preheaders.
-- Pure in the IR is not sufficient: field/tag/string reads may dereference
-- pointers, and hart/region reads can change across a safepoint.
module Codegen.LoopOptimize (moveInvariants) where
import Codegen.IR
import Codegen.ControlFlow
import Codegen.Policy (RegisterBudget)
import Codegen.Pressure
import Data.List (sortOn,foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S

moveInvariants :: Maybe RegisterBudget -> Bool -> Fn -> Fn
moveInvariants budget inlineFloats fn=
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
          available moved v=S.member v moved || maybe False (\d->S.notMember d members && dominates d pre) (M.lookup v defs)
          loopInstrs=[i | b<-fnBlocks f,S.member (bId b) members,i<-bInstrs b]
          candidates=[(v,Instr (Just (v,t)) (mapOpUses resolve op)) | Instr (Just (v,t)) op<-loopInstrs,speculatable op]
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
      in if null admitted then f else apply admitted
    move f _=f

cheap :: Op -> Bool
cheap op=case op of
  OConstInt {}->True; OBits {}->True; ONullary {}->True; OSymbol {}->True; OFunValue {}->True
  _->False

speculatable :: Op -> Bool
speculatable op=case op of
  OConstInt {}->True; ONullary {}->True; OBits {}->True
  OAddress {}->True; OIndex {}->True; OTag {}->True; OUntag {}->True
  OBoolOf {}->True; ONot {}->True; OIsInt {}->True
  OSymbol {}->True; OFunValue {}->True; OBit {}->True; OCmp {}->True
  OFloatBin {}->True; OFloat32Bin {}->True; OFloatCmp {}->True; OFloat32Cmp {}->True
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
