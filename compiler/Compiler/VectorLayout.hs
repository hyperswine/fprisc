-- Checked layout evidence and native calling schemas. The runtime descriptor
-- is serialized at the boundary; its element type and lexical slot stay data.
module Compiler.VectorLayout
  (VectorBuilder(..), LayoutSlot(..), LayoutEvidence(..), LayoutContract(..), LayoutOwner(..),
   layoutParameterName, layoutEvidenceType, mapLayoutEvidenceM,
   builderName, builderRuntimeName, plainBuilder, unresolvedLayoutType, canonicalLayout, validLayout) where
import Type.Syntax
import Data.List (sortOn)
import Core.Identity (BinderId)

data VectorBuilder=BuildEmpty | BuildFromList | BuildMap deriving (Eq,Show)
data LayoutSlot=LayoutSlot String Int deriving (Eq,Ord,Show)
data LayoutEvidence=StaticLayout Type String | ForwardLayout Type LayoutSlot deriving (Show)
data LayoutOwner=GlobalLayout String | LocalLayout BinderId deriving (Eq,Show)
data LayoutContract=LayoutContract
  {layoutContractOwner :: LayoutOwner, layoutCallingScheme :: Scheme,
   layoutBodyRequirements :: [Type]} deriving (Show)
layoutParameterName :: LayoutSlot -> String
layoutParameterName (LayoutSlot owner index)="$vectorLayout."++owner++"."++show index
layoutEvidenceType :: LayoutEvidence -> Type
layoutEvidenceType (StaticLayout t _)=t
layoutEvidenceType (ForwardLayout t _)=t
mapLayoutEvidenceM :: Functor m => (Type -> m Type) -> LayoutEvidence -> m LayoutEvidence
mapLayoutEvidenceM f (StaticLayout t s)=(`StaticLayout` s) <$> f t
mapLayoutEvidenceM f (ForwardLayout t s)=(`ForwardLayout` s) <$> f t
builderName :: VectorBuilder -> String
builderName BuildEmpty="Vec.new"
builderName BuildFromList="Vec.fromList"
builderName BuildMap="Vec.map"
builderRuntimeName :: VectorBuilder -> String
builderRuntimeName b=builderName b++"As"
plainBuilder :: VectorBuilder -> LayoutEvidence -> Bool
plainBuilder b (StaticLayout _ "")=b/=BuildMap
plainBuilder _ _=False

unresolvedLayoutType :: Type -> Bool
unresolvedLayoutType t=case t of
  TV _->True
  TAp a b->unresolvedLayoutType a || unresolvedLayoutType b
  TFn a b->unresolvedLayoutType a || unresolvedLayoutType b
  TTupT xs->any unresolvedLayoutType xs
  TRec r->row r
  TLayout _->True -- evidence is not a source vector element
  _->False
  where row RNil=False; row (RV _)=True; row (RExt _ a r)=unresolvedLayoutType a || row r

canonicalLayout :: Type -> Maybe String
canonicalLayout t
  | unresolvedLayoutType t=Nothing
  | not (mentionsFloat t)=Just ""
  | otherwise=floatLayout t
  where
    floatLayout (TC "F64")=Just "d"
    floatLayout (TC "F32")=Just "s"
    floatLayout (TTupT xs) | not (null xs)=productLayout xs
    floatLayout (TRec r)=case fields r of Just fs | not (null fs)->productLayout (map snd (sortOn fst fs)); _->Nothing
    floatLayout _=Nothing
    productLayout ts=do
      fs<-mapM field ts
      pure (if length ts==1 || any (elem '(') fs then "("++concat fs++")" else concat fs)
    fields RNil=Just []
    fields (RExt n a r)=((n,a):) <$> fields r
    fields _=Nothing
    field (TC "Int")=Just "i"
    field (TC "F64")=Just "d"
    field (TC "F32")=Just "s"
    field a@(TTupT _) | mentionsFloat a=nested a
    field a@(TRec _) | mentionsFloat a=nested a
    field a | not (mentionsFloat a)=Just "b"
    field _=Nothing
    nested a=do
      spec<-floatLayout a
      pure (if take 1 spec=="(" then spec else "("++spec++")")

-- Explicit newAs permits flat i/d/s/b declarations, while inferred evidence
-- also carries nested product descriptors and the ordinary boxed default.
validLayout :: Type -> String -> Bool
validLayout t spec=canonicalLayout t==Just spec ||
  (not (null spec) && length components==length spec && and (zipWith field components spec))
  where
    components=case t of TTupT xs->xs; _->[t]
    field a 'i'=a==TC "Int"
    field a 'd'=a==TC "F64"
    field a 's'=a==TC "F32"
    field a 'b'=not (unresolvedLayoutType a || mentionsFloat a)
    field _ _=False
