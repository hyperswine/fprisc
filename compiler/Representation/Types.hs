-- ARC representation contracts. Characters appear only in the runtime's
-- existing constructor-layout serialization, never as compiler type tags.
module Representation.Types
  (Kind(..),Rep(..),CallSignature(..),ShapeType(..),PrimitiveShape(..),kindTag) where
data Kind = Managed | RawWord | RawAddr | RawF64 | RawF32 deriving (Eq,Ord,Show)
data Rep = ScalarRep Kind | TextRep | DataRep Int deriving (Eq,Ord,Show)
data CallSignature = CallSignature [Maybe Rep] (Maybe Rep) deriving (Eq,Show)
data ShapeType = AnyValue | KnownValue Rep deriving (Eq,Show)
data PrimitiveShape = PrimitiveShape [ShapeType] ShapeType deriving (Eq,Show)
kindTag :: Kind -> Char
kindTag kind=case kind of Managed->'t';RawWord->'w';RawAddr->'a';RawF64->'d';RawF32->'f'
