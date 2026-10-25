{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Checked RV64 builtin C adapters. Signature, placement, conversions and
-- scheduling are data; only the final target renderer chooses assembly.
module Codegen.Export.Plan
  (FloatABI(..), CKind(..), Signature(..), CExportSymbol(..), FprEntrySymbol(..),
   CSource(..), NativeLocation(..), ArgumentConversion(..), ResultConversion(..),
   ArgumentPlan(..), AdapterFrame(..), AdapterPlan(..), CheckedAdapter,
   adapterPlan, checkExportArity, planAdapter, checkAdapter) where

import qualified Codegen.Calling as Calling
import Codegen.Selected (Phys)
import Control.Monad (unless,when,foldM)
import Data.List (sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data FloatABI = SoftFloat | HardFloat deriving (Eq,Ord,Show)
-- Keep the established diagnostic/comment spellings.
data CKind = KInt | KWord | KAddr | KBool | KUnit | KF64 | KF32 deriving (Eq,Ord,Show)
data Signature = Signature {signatureParams :: [CKind], signatureResult :: CKind} deriving (Eq,Show)
newtype CExportSymbol = CExportSymbol String deriving (Eq,Show)
newtype FprEntrySymbol = FprEntrySymbol String deriving (Eq,Show)
data CSource = IntegerArgument Int | FloatArgument Int | StackWord Int deriving (Eq,Ord,Show)
data NativeLocation = NativeRegister Phys | NativeCell Int deriving (Eq,Ord,Show)
data ArgumentConversion = WordIdentity | TagInt | BoxBool | BoxUnit | F64Bits | F32Bits deriving (Eq,Ord,Show)
data ResultConversion = ReturnWord | UntagInt | UnboxBool | ReturnF64 | ReturnF32 deriving (Eq,Ord,Show)
data ArgumentPlan = ArgumentPlan
  { argumentPosition :: Int, argumentKind :: CKind, argumentSource :: CSource,
    argumentDestination :: NativeLocation, argumentConversion :: ArgumentConversion
  } deriving (Eq,Show)
data AdapterFrame = AdapterFrame {frameBytes :: Int, savedReturnOffset :: Int} deriving (Eq,Show)
data AdapterPlan = AdapterPlan
  { adapterPublic :: CExportSymbol, adapterEntry :: FprEntrySymbol,
    adapterABI :: FloatABI, adapterSignature :: Signature,
    adapterFrame :: AdapterFrame, adapterArguments :: [ArgumentPlan],
    adapterResult :: ResultConversion
  } deriving (Eq,Show)
newtype CheckedAdapter = CheckedAdapter AdapterPlan deriving (Eq,Show)
adapterPlan :: CheckedAdapter -> AdapterPlan
adapterPlan (CheckedAdapter plan)=plan

checkExportArity :: FloatABI -> Int -> Int -> Either String ()
checkExportArity abi declared actual=do
  unless (actual==declared) (Left ("signature has "++show declared++" parameters, the function "++show actual))
  when (actual<0) (Left "negative export arity")
  when (actual>64) (Left "more than 64 parameters: pass a pointer to a Layout instead (docs/2026-09-19-LAYOUTS.md)")
  when (abi==HardFloat && actual>8) (Left "more than 8 parameters under --float-abi=hard: stacked float arguments are not lowered yet")

isFloat :: CKind -> Bool
isFloat k=k==KF64 || k==KF32

-- Each C bank has its own counter under lp64d. The supported hard ABI stops
-- at eight total parameters, so neither bank can overflow into C's stack.
cSources :: FloatABI -> [CKind] -> [CSource]
cSources abi=go 0 0
  where
    go _ _ []=[]
    go ints floats (k:ks)
      | abi==HardFloat && isFloat k=FloatArgument floats:go ints (floats+1) ks
      | otherwise=(if ints<8 then IntegerArgument ints else StackWord (ints-8)):go (ints+1) floats ks

nativeLocations :: Int -> Either String [NativeLocation]
nativeLocations count=do
  places<-Calling.argumentPlaces Calling.RiscV (Calling.FprCall Calling.NoFuel) count
  traverse native places
  where
    native (Calling.ArgumentRegister p)=Right (NativeRegister p)
    native (Calling.HartArgument j)=Right (NativeCell j)
    native (Calling.NamedArgument _)=Left "RV64 export: another target's private argument cell"

conversion :: CKind -> CSource -> ArgumentConversion
conversion k source=case (k,source) of
  (KF64,FloatArgument _)->F64Bits
  (KF32,FloatArgument _)->F32Bits
  (KInt,_)->TagInt
  (KBool,_)->BoxBool
  (KUnit,_)->BoxUnit
  _->WordIdentity
resultConversion :: FloatABI -> CKind -> ResultConversion
resultConversion abi k=case k of
  KInt->UntagInt
  KBool->UnboxBool
  KF64 | abi==HardFloat->ReturnF64
  KF32 | abi==HardFloat->ReturnF32
  _->ReturnWord

planAdapter :: FloatABI -> CExportSymbol -> FprEntrySymbol -> Signature -> Either String CheckedAdapter
planAdapter abi public entry sig=do
  let ks=signatureParams sig
  checkExportArity abi (length ks) (length ks)
  destinations<-nativeLocations (length ks)
  let args=zipWith3 (\i k (source,destination)->ArgumentPlan i k source destination (conversion k source))
        [0..] ks (zip (cSources abi ks) destinations)
      -- Copy wide C stack arguments before any register moves; read the
      -- register bank from high positions down to avoid overwriting inputs.
      schedule=[a | a<-args,argumentPosition a>=8]++reverse [a | a<-args,argumentPosition a<8]
  checkAdapter (AdapterPlan public entry abi sig (AdapterFrame 16 8) schedule (resultConversion abi (signatureResult sig)))

-- This boundary also accepts plans rewritten by a future pass. It checks
-- signature coverage, ABI placement and conversion types, then simulates
-- register destruction in emission order. Rendering accepts only its result.
checkAdapter :: AdapterPlan -> Either String CheckedAdapter
checkAdapter plan=do
  let Signature kinds result=adapterSignature plan
      args=adapterArguments plan
      count=length kinds
      abi=adapterABI plan
      AdapterFrame bytes ret=adapterFrame plan
      require why yes=unless yes (Left ("C export plan: "++why))
  checkExportArity abi count count
  require "frame is not aligned or return address is outside the frame"
    (bytes>=16 && bytes<=2032 && bytes `mod` 16==0 && ret>=0 && ret `mod` 8==0 && ret<=bytes-8)
  require "missing or duplicate argument position" (sort (map argumentPosition args)==[0..count-1])
  destinations<-nativeLocations count
  let expected=M.fromList (zip [0..] (zip3 kinds (cSources abi kinds) destinations))
  mapM_ (\arg->case M.lookup (argumentPosition arg) expected of
    Nothing->Left "C export plan: argument has no signature position"
    Just (kind,source,destination)->do
      require "argument kind disagrees with signature" (argumentKind arg==kind)
      require "argument C location disagrees with ABI" (argumentSource arg==source)
      require "argument native location disagrees with ABI" (argumentDestination arg==destination)
      case source of
        StackWord n->require "incoming C stack word exceeds the RV load immediate" (bytes+8*n<=2047)
        _->pure ()
      require "argument conversion disagrees with its representation" (argumentConversion arg==conversion kind source)) args
  require "result conversion disagrees with its representation" (adapterResult plan==resultConversion abi result)
  _<-foldM (\destroyed arg->do
    case argumentSource arg of
      IntegerArgument n | argumentConversion arg/=BoxUnit->
        require "argument schedule reads an overwritten C register" (S.notMember n destroyed)
      _->pure ()
    -- Register destinations are a_i by source position, checked above.
    pure (case argumentDestination arg of NativeRegister _->S.insert (argumentPosition arg) destroyed;NativeCell _->destroyed)) S.empty args
  pure (CheckedAdapter plan)
