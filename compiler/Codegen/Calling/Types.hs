-- Logical entry contracts are independent of selection and physical registers.
module Codegen.Calling.Types
  (EntryConvention(..), FuelEntry(..), CallConvention(..), TransferResult(..), Transfer(..), ArgumentCell(..)) where

data EntryConvention = FprWords | CWords deriving (Eq,Ord,Show)
data FuelEntry = TicksFuel | NoFuel deriving (Eq,Ord,Show)
data CallConvention = FprCall FuelEntry | RuntimeCall deriving (Eq,Ord,Show)
data TransferResult = WordResult | DiscardResult | TailTransfer deriving (Eq,Ord,Show)
data Transfer = Transfer
  { transferConvention :: CallConvention,
    transferArity :: Int,
    transferResult :: TransferResult
  } deriving (Eq,Ord,Show)

-- Private x64 argument cells, distinct from linker symbols and hart indices.
data ArgumentCell = Argument7 | Argument8 deriving (Eq,Ord,Show)
