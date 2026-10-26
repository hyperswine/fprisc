-- Speculate only total register operations into existing unique preheaders.
-- Pure in the IR is not sufficient: field/tag/string reads may dereference
-- pointers, and hart/region reads can change across a safepoint.
module Codegen.LoopOptimize (moveInvariants) where
import Codegen.IR
import Codegen.ControlFlow
import Data.List (sortOn,foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S

moveInvariants :: Fn -> Fn
moveInvariants fn=
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
          candidates=[(v,Instr (Just (v,t)) (mapOpUses resolve op)) | b<-fnBlocks f,S.member (bId b) members,
            Instr (Just (v,t)) op<-bInstrs b,speculatable op]
          choose moved chosen =
            let (moved',chosen')=foldl' (\(ready,out) (v,i@(Instr _ op))->
                  if S.size ready<16 && S.notMember v ready && all (available ready) (opUses op)
                    then (S.insert v ready,out++[i]) else (ready,out)) (moved,chosen) candidates
            in if moved'==moved then (moved,chosen) else choose moved' chosen'
          (moving,instructions)=choose S.empty []
          rewrite b | bId b==pre=b {bInstrs=bInstrs b++instructions}
                    | S.member (bId b) members=b {bInstrs=[i | i@(Instr d _)<-bInstrs b,maybe True (\(v,_)->S.notMember v moving) d]}
                    | otherwise=b
      in f {fnBlocks=map rewrite (fnBlocks f)}
    move f _=f

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
