{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Checked roles and scopes for selected-instruction payloads. Machine frame
-- layout owns save-group bounds; the allocator owns its independent events.
module Codegen.Annotation
  (RestoreSupport(..),EntryPoint(..),checkAnnotations,checkSaveGroups,entryLabel) where
import Codegen.Selected
import qualified Codegen.Opcode as O
import qualified Codegen.Opcode.A64 as A
import qualified Codegen.Opcode.RV as R
import Control.Monad (unless,forM_)
import qualified Data.Set as S

data RestoreSupport=ConditionalRestores | AlwaysRestores deriving (Eq,Show)
data EntryPoint=StackReady | SameStack | FuelReady deriving (Eq,Ord,Show)

entryPoints opcode=case opcode of
  O.Common O.EntryCheckTick->[StackReady,SameStack,FuelReady]
  O.Common O.EntryCheck->[StackReady,SameStack]
  O.Common O.EntryTick->[FuelReady]
  O.Common O.TickN->[FuelReady]
  _->[]

checkAnnotations :: RestoreSupport -> String -> [Item] -> Either String ()
checkAnnotations restore owner items=do
  forM_ instructions $ \i->do
    let opcode=siOpcode i
        require why yes=unless yes (bad (siOp i++": "++why))
    require "annotation does not match its operation" (case siAnnotation i of
      NoAnnotation->not (entry opcode) && opcode/=O.A64 A.Save
      EntryLabels (Label stem)->entry opcode && not (null stem)
      SaveGroup k->opcode==O.A64 A.Save && k>=0
      SkipRestores->restore==ConditionalRestores && siControl i==Return)
    require "allocation event does not match a physical copy/load/store" (case siAllocation i of
      Nothing->True
      Just SpillStore->opcode `elem` [O.X64 O.FrameStore,O.A64 A.FrameStore,O.RV R.FrameStore]
        && null (siDefs i) && case siUses i of [OP _,OF _ 0]->True;_->False
      Just Reload->opcode `elem` [O.X64 O.FrameLoad,O.A64 A.FrameLoad,O.RV R.FrameLoad]
        && case (siDefs i,siUses i) of ([OP _],[OF _ 0])->True;_->False
      Just RegisterCopy->opcode `elem` [O.X64 O.Move,O.A64 A.Move,O.A64 A.FloatMove,O.RV R.Move]
        && case (siDefs i,siUses i) of ([OP _],[OP _])->True;_->False)
  let labels=itemLabels items++concatMap internalLabels instructions
  unless (length labels==S.size (S.fromList labels)) (bad "entry expansion captures or duplicates a local label")
  where
    instructions=[i | I i<-items]
    bad why=Left ("selected annotations "++owner++": "++why)
    entry=not . null . entryPoints
    internalLabels i=case siAnnotation i of
      EntryLabels _->map (entryLabel i) (entryPoints (siOpcode i))
      _->[]

-- Called with the actual final frame's save table before its renderer indexes
-- that table. No textual integer decoding or unbounded save reference remains.
checkSaveGroups :: String -> Int -> [Item] -> Either String ()
checkSaveGroups owner count items=forM_ [k | I i<-items,SaveGroup k<-[siAnnotation i]] $ \k->
  unless (k>=0 && k<count) (Left ("selected annotations "++owner++": save group is outside this frame"))

-- Renderers call this only after the annotation checker. Labels remain typed
-- until their final assembly spelling is needed; no instruction parses a tag.
entryLabel :: SInstr -> EntryPoint -> Label
entryLabel i point=case siAnnotation i of
  EntryLabels (Label stem)->Label (stem++case point of
    StackReady->"_stk";SameStack->"_same";FuelReady->"_fuel")
  _->error "selected renderer: missing checked entry-label annotation"
