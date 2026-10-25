-- Event roles used by native instruction accounting and allocation. There is
-- no independent pair of runtime/safepoint Booleans to contradict a call role.
module Codegen.Call
  (Call(..),CallEffect(..),callSafepoint,callRuntime,RuntimeEntry(..),runtimeSymbol,runtimeEvent,runtimeName) where
import Codegen.Symbol
import Codegen.Calling.Types (FuelEntry(..))
data CallEffect = CalleeEntry FuelEntry | RuntimeC | FuelExhaustion deriving (Eq,Ord,Show)
data Call = Call {callTarget :: CodeSymbol,callEffect :: CallEffect} deriving (Eq,Ord,Show)
callSafepoint :: Call -> Bool
callSafepoint event=case callEffect event of CalleeEntry TicksFuel->True;FuelExhaustion->True;_->False
callRuntime :: Call -> Bool
callRuntime event=callEffect event==RuntimeC
data RuntimeEntry = ApplyEntry | PanicEntry | GrowStackEntry | FuelEntry | ReserveStackEntry deriving (Eq,Ord,Show)
runtimeName :: RuntimeEntry -> String
runtimeName entry=case entry of
  ApplyEntry->"fpr_applyN"
  PanicEntry->"fpr_panic"
  GrowStackEntry->"fpr_stack_grow"
  FuelEntry->"fpr_fuel_exhausted"
  ReserveStackEntry->"fpr_stack_reserve"
runtimeSymbol :: RuntimeEntry -> CodeSymbol
runtimeSymbol=CodeSymbol . runtimeName
runtimeEvent :: RuntimeEntry -> Call
runtimeEvent entry=Call (runtimeSymbol entry) (if entry==FuelEntry then FuelExhaustion else RuntimeC)
