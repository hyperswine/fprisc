{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- The existing word ABIs. Runtime calls use the native integer register bank;
-- generated entries additionally use the private hart cells up to arity 64.
-- These contracts do not describe arbitrary C stack/FP argument signatures.
module Codegen.Calling
  (module Codegen.Calling.Types, ABI(..), ArgumentPlace(..),
   argumentRegisters, resultRegister, secondResultRegister, productRegisters, resultPlaces, callerClobbers, argumentPlaces, nativePlaces,
   cellSymbol, cellOffset, calleeCall, nativeCall, callEvent,
   selectTransfer, selectPairTransfer, selectProductTransfer, stagedArguments, arrivalArguments, checkTransfers) where

import Codegen.Calling.Types
import Codegen.IR (Callee,calleeConvention,arityCeiling)
import Codegen.Policy (Policy,polFuel)
import Codegen.Selected
import qualified Codegen.Opcode as O
import qualified Codegen.Opcode.A64 as A
import qualified Codegen.Opcode.RV as R
import Control.Monad (unless,when)
import Data.List (sort,nub)

data ABI = AArch64 | X86_64 | RiscV deriving (Eq,Ord,Show)
data ArgumentPlace = ArgumentRegister Phys | NamedArgument ArgumentCell | HartArgument Int
  deriving (Eq,Ord,Show)

argumentRegisters :: ABI -> [Phys]
argumentRegisters abi=map Phys $ case abi of
  AArch64->["x"++show n | n<-[0::Int ..7]]
  X86_64->["rdi","rsi","rdx","rcx","r8","r9"]
  RiscV->["a"++show n | n<-[0::Int ..7]]
resultRegister :: ABI -> Phys
resultRegister abi=Phys $ case abi of AArch64->"x0";X86_64->"rax";RiscV->"a0"
-- the register a pair worker answers its second word in: the next result register of the ABI
secondResultRegister :: ABI -> Phys
secondResultRegister abi=Phys $ case abi of AArch64->"x1";X86_64->"rdx";RiscV->"a1"
-- Private FPR products use volatile integer registers. This is deliberately
-- not a claim about the platform C ABI: foreign aggregates need an adapter.
-- x64 preserves its established first two results and leaves r11 available
-- for copy cycles and the frame-restoring epilogue.
productRegisters :: ABI -> [Phys]
productRegisters abi=case abi of
  AArch64->map (Phys . ("x"++) . show) [0::Int ..7]
  RiscV->map (Phys . ("a"++) . show) [0::Int ..7]
  X86_64->map Phys ["rax","rdx","rcx","rsi","rdi","r8","r9","r10"]

resultPlaces :: ABI -> CallConvention -> TransferResult -> Either String [Phys]
resultPlaces abi convention result=case result of
  WordResult->pure [resultRegister abi]
  PairResult->product 2
  ProductResult n->product n
  DiscardResult->pure []
  TailTransfer->pure []
  NeverReturns->pure []
  where
    product n=do
      when (convention==RuntimeCall) (Left "call convention: product result requires a private FPR entry")
      when (n<2 || n>length (productRegisters abi)) (Left "call convention: unsupported product result count")
      pure (take n (productRegisters abi))
callerClobbers :: ABI -> [Phys]
callerClobbers abi=map Phys $ case abi of
  AArch64->["x"++show n | n<-[0::Int ..17]++[30]]++["d"++show n | n<-[0::Int ..7]++[16..31]]
  X86_64->["rax","rcx","rdx","rsi","rdi","r8","r9","r10","r11"]
  RiscV->["a"++show n | n<-[0::Int ..7]]++["t"++show n | n<-[0::Int ..6]]++["ra"]

-- All positions are explicit; no truncating zip can silently discard an
-- argument that does not fit the runtime's supported register-only interface.
nativePlaces :: ABI -> [ArgumentPlace]
nativePlaces abi=map ArgumentRegister (argumentRegisters abi)
  ++ [NamedArgument c | abi==X86_64,c<-[Argument7,Argument8]]
  ++ map HartArgument [0..arityCeiling-9]
argumentPlaces :: ABI -> CallConvention -> Int -> Either String [ArgumentPlace]
argumentPlaces abi convention n=do
  let places=case convention of FprCall _->nativePlaces abi;RuntimeCall->map ArgumentRegister (argumentRegisters abi)
  when (n<0 || n>length places) (Left "call convention: unsupported argument count")
  pure (take n places)
cellSymbol :: ArgumentCell -> String
cellSymbol Argument7="fpr_x64_a6"
cellSymbol Argument8="fpr_x64_a7"
cellOffset :: ArgumentCell -> Int
cellOffset Argument7=8
cellOffset Argument8=16

nativeCall :: Policy -> CallConvention
nativeCall policy=FprCall (if polFuel policy then TicksFuel else NoFuel)
calleeCall :: Policy -> Callee -> CallConvention
calleeCall policy c=case calleeConvention c of FprWords->nativeCall policy;CWords->RuntimeCall
callEvent :: CodeSymbol -> CallConvention -> Call
callEvent sym convention=case convention of
  FprCall fuel->Call sym (CalleeEntry fuel)
  RuntimeCall->Call sym RuntimeC

stagedArguments :: ABI -> CallConvention -> [VReg] -> Either String [(ArgumentPlace,VReg)]
stagedArguments abi convention vs=do
  places<-argumentPlaces abi convention (length vs)
  pure [(place,v) | (place,v)<-zip places vs,case place of ArgumentRegister _->False;_->True]
arrivalArguments :: ABI -> [VReg] -> [(ArgumentPlace,VReg)]
arrivalArguments abi=zip (nativePlaces abi)

selectTransfer :: ABI -> CallConvention -> TransferResult -> CodeSymbol -> [VReg] -> Maybe VReg -> SInstr -> Either String SInstr
selectTransfer abi convention result sym vs value base=do
  when (null (codeName sym)) (Left "call convention: empty code symbol")
  when (case result of PairResult->True;ProductResult _->True;_->False)
    (Left "call convention: product result needs product selection")
  places<-argumentPlaces abi convention (length vs)
  unless ((result==WordResult)==(value/=Nothing)) (Left "call convention: inconsistent result")
  let resultReg=resultRegister abi
  pure base
    {siDefs=[OV v (Fix resultReg) | Just v<-[value]],
     siUses=OCode sym:[OV v (Fix p) | (ArgumentRegister p,v)<-zip places vs],
     siClobbers=filter (\p->result/=WordResult || p/=resultReg) (callerClobbers abi),
     siControl=if result `elem` [TailTransfer,NeverReturns] then Return else Next,
     siCalls=[callEvent sym convention],
     siTransfer=Just (Transfer convention (length vs) result)}

-- a call that answers two words: the first in the result register, the second
-- in the second result register; both leave the clobber set
selectPairTransfer :: ABI -> CallConvention -> CodeSymbol -> [VReg] -> VReg -> VReg -> SInstr -> Either String SInstr
selectPairTransfer abi convention sym vs first second=selectProductTransfer abi convention sym vs [first,second]

selectProductTransfer :: ABI -> CallConvention -> CodeSymbol -> [VReg] -> [VReg] -> SInstr -> Either String SInstr
selectProductTransfer abi convention sym vs values base=do
  when (null (codeName sym)) (Left "call convention: empty code symbol")
  places<-argumentPlaces abi convention (length vs)
  let result=if length values==2 then PairResult else ProductResult (length values)
  registers<-resultPlaces abi convention result
  unless (length values==length (nub values)) (Left "call convention: duplicate product result definition")
  pure base
    {siDefs=zipWith (\v p->OV v (Fix p)) values registers,
     siUses=OCode sym:[OV v (Fix p) | (ArgumentRegister p,v)<-zip places vs],
     siClobbers=filter (`notElem` registers) (callerClobbers abi),
     siControl=Next,
     siCalls=[callEvent sym convention],
     siTransfer=Just (Transfer convention (length vs) result)}

-- Validate both virtual selection and physical placement. Staged cells must
-- belong to this transfer and cannot survive a branch, call or safepoint.
checkTransfers :: ABI -> String -> [Item] -> Either String ()
checkTransfers abi owner=go []
  where
    bad why=Left ("call convention "++owner++": "++why)
    require why yes=unless yes (bad why)
    go _ []=pure ()
    go _ (ILabel _:rest)=go [] rest
    go pending (I i:rest)=do
      let direct=case siOpcode i of
            O.Common O.TailJump->True
            O.X64 O.Call->True
            O.A64 A.Call->True
            O.RV R.Call->True
            _->False
      pending' <- case (direct,siTransfer i) of
        (False,Nothing)->pure pending
        (False,Just _)->bad "transfer contract on a non-transfer operation"
        (True,Nothing)->bad "missing transfer contract"
        (True,Just (Transfer convention arity result))->do
          places<-argumentPlaces abi convention arity
          answered<-resultPlaces abi convention result
          let registers=[p | ArgumentRegister p<-places]
              cells=[OC c | NamedArgument c<-places]++[OI (toInteger n) | HartArgument n<-places]
          require "missing or empty code target" (case siUses i of OCode sym:_->not (null (codeName sym));_->False)
          require "argument register placement mismatch" (case siUses i of OCode _:vs->length vs==length registers && and (zipWith fixed registers vs);_->False)
          require "result register placement mismatch"
            (length (siDefs i)==length answered && and (zipWith fixed answered (siDefs i)))
          let definitions=[v | OV v _<-siDefs i]
          require "duplicate product result definition" (length definitions==length (nub definitions))
          require "caller clobber set mismatch" (sort (siClobbers i)==sort (filter (`notElem` answered) (callerClobbers abi)))
          require "call event mismatch" (case siUses i of OCode sym:_->siCalls i==[callEvent sym convention];_->False)
          require "tail/return contract mismatch" ((result==TailTransfer)==(siOpcode i==O.Common O.TailJump) && siControl i==(if result `elem` [TailTransfer,NeverReturns] then Return else Next))
          require "staged argument cells mismatch or crossed a call/control boundary" (sort pending==sort cells)
          pure []
      let staged=case (siOpcode i,siUses i) of
            (O.Common O.StoreCell,[_,OC cell])->Just (OC cell)
            (O.Common O.StoreSpill,[_,OI n])->Just (OI n)
            _->Nothing
          next=case staged of
            Just key->key:pending'
            Nothing | not (null (siCalls i)) || siControl i/=Next->[]
            Nothing->pending'
      go next rest
    fixed p (OV _ (Fix q))=p==q
    fixed p (OP q)=p==q
    fixed _ _=False
