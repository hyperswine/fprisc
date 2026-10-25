-- Preserve known representations from checked, closed interfaces at ARC's
-- erased compatibility boundary. Unknown type variables remain unconstrained;
-- they are not invented managed types. The representation solver checks each
-- surviving signature against the actual physical function and its uses.
module Compiler.Native.Representation (signatures) where
import qualified Compiler.Native.Core as Native
import qualified Core.Typed.Syntax as Core
import qualified Core.Calling as Calling
import Type.Syntax (Type(..))
import Representation.Types
import qualified Data.Map.Strict as M

signatures :: Native.NativeCore -> M.Map String CallSignature
signatures native=M.map checked (Native.nativeDefinitions native)
  `M.union` M.map declaration (Native.nativeDeclarations native)
  where
    checked definition=let fn=Native.checkedFunction definition
      in CallSignature (map (representation . Core.binderType) (Core.functionParameters fn))
                       (representation (Core.exprType (Core.functionBody fn)))
    declaration d=CallSignature (map representation (Calling.callingArguments d)) (representation (Calling.callingResult d))
    representation ty=case ty of
      TC "Word"->Just (ScalarRep RawWord)
      TC "Addr"->Just (ScalarRep RawAddr)
      TC "F64"->Just (ScalarRep RawF64)
      TC "F32"->Just (ScalarRep RawF32)
      TC "Int"->Just (ScalarRep Managed)
      TC "I32"->Just (ScalarRep Managed)
      TC "Bool"->Just (DataRep 1)
      TC "Unit"->Just (DataRep 0)
      TC "String"->Just TextRep
      _->Nothing
