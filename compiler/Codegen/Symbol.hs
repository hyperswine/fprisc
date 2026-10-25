-- Linker spelling is separate from reference role. A data address cannot be
-- used as a call target simply because both eventually print one name.
module Codegen.Symbol (CodeSymbol(..),AddressSymbol(..),addressName) where
newtype CodeSymbol = CodeSymbol {codeName :: String} deriving (Eq,Ord,Show)
data AddressSymbol = StaticObject String | CodeAddress CodeSymbol | ExternalAddress String
  deriving (Eq,Ord,Show)
addressName :: AddressSymbol -> String
addressName address=case address of StaticObject name->name;CodeAddress code->codeName code;ExternalAddress name->name
