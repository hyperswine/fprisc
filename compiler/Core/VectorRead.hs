-- The three audited reads return the original Vector handle unchanged.
-- Pair-free lowering keeps the element read/checks and reuses that handle.
--
-- An element read also says what the checker knew of the element: a read
-- of a `Vector Int` or of a float vector has its own name, so the lowering
-- reads the one column kind the type allows with no test of which it is.
-- Every name of one read is the same runtime entry (vec.c h_peek_get).
module Core.VectorRead (Read(..),Element(..),reads,sourceName,fromSourceName,peekName,peekNameAs,fromPeekName,peekElement,elementOf,indexArity,peekArities,storeNameAs,storeElement,storeNames) where
import Prelude hiding (Read,reads)
import Type.Syntax (Type(..))
data Read=At | Get | Length deriving (Eq,Ord,Show)
-- what the element's type says of its column: raw Ints, raw float bits, or nothing
data Element=AnyElement | IntElement | FloatElement deriving (Eq,Ord,Show,Enum,Bounded)
reads :: [Read]
reads=[At,Get,Length]
sourceName :: Read -> String
sourceName op=case op of At->"Vec.at";Get->"Vec.get";Length->"Vec.len"
fromSourceName :: String -> Maybe Read
fromSourceName name=lookup name [(sourceName op,op) | op<-reads]
peekName :: Read -> String
peekName op=case op of At->"$vec.at";Get->"$vec.get";Length->"$vec.len"
peekNameAs :: Element -> Read -> String
peekNameAs element op=peekName op++case (op,element) of
  (Length,_)->""
  (_,IntElement)->".int"
  (_,FloatElement)->".float"
  (_,AnyElement)->""
names :: [(String,(Read,Element))]
names=[(peekNameAs element op,(op,element)) | op<-reads,element<-if op==Length then [AnyElement] else [minBound..maxBound]]
fromPeekName :: String -> Maybe Read
fromPeekName name=fst <$> lookup name names
peekElement :: String -> Element
peekElement name=maybe AnyElement snd (lookup name names)
-- the element of a vector handle's checked type
elementOf :: Type -> Element
elementOf t=case t of
  TAp (TC "Vector") (TC "Int")->IntElement
  TAp (TC "Vector") (TC "F64")->FloatElement
  TAp (TC "Vector") (TC "F32")->FloatElement
  _->AnyElement
indexArity :: Read -> Int
indexArity Length=0
indexArity _=1
peekArities :: [(String,Int)]
peekArities=[(name,indexArity op+1) | (name,(op,_))<-names]++[(name,3) | (name,(_,element))<-stores,element/=AnyElement]
-- An in-place store (`Vec.set`, `Vec.put`) into a `Vector Int` or a float
-- vector has its own name too, for the same reason; each is the same runtime
-- entry as its source name (vec.c h_set, h_put). A store keeps its source
-- name where the element's type says nothing.
stores :: [(String,(String,Element))]
stores=[(name,(name,AnyElement)) | name<-["Vec.set","Vec.put"]]
  ++[(stem++suffix,(name,element)) | (name,stem)<-[("Vec.set","$vec.set"),("Vec.put","$vec.put")],
      (suffix,element)<-[(".int",IntElement),(".float",FloatElement)]]
storeNames :: [String]
storeNames=map fst stores
-- the source primitive and the element of a store's name
storeElement :: String -> Maybe (String,Element)
storeElement name=lookup name stores
storeNameAs :: Element -> String -> String
storeNameAs element name=case [typed | (typed,(source,e))<-stores,source==name,e==element] of
  (typed:_) -> typed
  [] -> name
