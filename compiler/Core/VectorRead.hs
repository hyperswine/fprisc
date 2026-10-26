-- The three audited reads return the original Vector handle unchanged.
-- Pair-free lowering keeps the element read/checks and reuses that handle.
module Core.VectorRead (Read(..),reads,sourceName,fromSourceName,peekName,indexArity,peekArities) where
import Prelude hiding (Read,reads)
data Read=At | Get | Length deriving (Eq,Ord,Show)
reads :: [Read]
reads=[At,Get,Length]
sourceName :: Read -> String
sourceName op=case op of At->"Vec.at";Get->"Vec.get";Length->"Vec.len"
fromSourceName :: String -> Maybe Read
fromSourceName name=lookup name [(sourceName op,op) | op<-reads]
peekName :: Read -> String
peekName op=case op of At->"$vec.at";Get->"$vec.get";Length->"$vec.len"
indexArity :: Read -> Int
indexArity Length=0
indexArity _=1
peekArities :: [(String,Int)]
peekArities=[(peekName op,indexArity op+1) | op<-reads]
