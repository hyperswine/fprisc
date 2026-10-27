-- Event roles used by native instruction accounting and allocation. There is
-- no independent pair of runtime/safepoint Booleans to contradict a call role.
module Codegen.Call
  (Call(..),CallEffect(..),callSafepoint,callRuntime,callPreserves,RuntimeEntry(..),runtimeSymbol,runtimeEvent,runtimeName) where
import Codegen.Symbol
import Codegen.Calling.Types (FuelEntry(..))
-- PreservingFuel: the fuel tick's slow path through the unit's register-
-- saving wrapper (fpr_fuel_save_local, emitted beside the code): a
-- safepoint that preserves every allocatable register, so values live
-- across it need not sit in the scheduler-preserved budget.
data CallEffect = CalleeEntry FuelEntry | RuntimeC | FuelExhaustion | PreservingFuel deriving (Eq,Ord,Show)
data Call = Call {callTarget :: CodeSymbol,callEffect :: CallEffect} deriving (Eq,Ord,Show)
callSafepoint :: Call -> Bool
callSafepoint event=case callEffect event of CalleeEntry TicksFuel->True;FuelExhaustion->True;PreservingFuel->True;_->False
-- the call leaves every allocatable register as it found it
callPreserves :: Call -> Bool
callPreserves event=callEffect event==PreservingFuel
callRuntime :: Call -> Bool
callRuntime event=callEffect event==RuntimeC
data RuntimeEntry = ApplyEntry | PanicEntry | GrowStackEntry | FuelEntry | FuelSaveEntry | ReserveStackEntry deriving (Eq,Ord,Show)
runtimeName :: RuntimeEntry -> String
runtimeName entry=case entry of
  ApplyEntry->"fpr_applyN"
  PanicEntry->"fpr_panic"
  GrowStackEntry->"fpr_stack_grow"
  FuelEntry->"fpr_fuel_exhausted"
  FuelSaveEntry->"fpr_fuel_save_local" -- unit-local: saves the caller-saved registers around fpr_fuel_exhausted
  ReserveStackEntry->"fpr_stack_reserve"
runtimeSymbol :: RuntimeEntry -> CodeSymbol
runtimeSymbol=CodeSymbol . runtimeName
runtimeEvent :: RuntimeEntry -> Call
runtimeEvent entry=Call (runtimeSymbol entry) (case entry of FuelEntry->FuelExhaustion;FuelSaveEntry->PreservingFuel;_->RuntimeC)
