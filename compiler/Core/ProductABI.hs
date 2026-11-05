-- Compiler-private multiword value forms. Source syntax cannot name these.
-- They carry no nominal/type authority; the checked producer supplies it.
module Core.ProductABI (ProductMarker(..), productMarker, packName, valueName, storedNodeName) where
import Data.List (stripPrefix)
data ProductMarker = PackWords Int | JoinWords Int deriving (Eq,Show)
packName n = "$product.pack"++show n
valueName n = "$product.value"++show n
productMarker name = do
  suffix <- stripPrefix "$product." name
  lookup suffix ([("pack"++show n,PackWords n) | n<-[2..8]]
    ++ [("value"++show n,JoinWords n) | n<-[2..8]])

storedNodeName :: String
storedNodeName="$storage.makeNode"
