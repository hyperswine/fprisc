-- ARC representation contracts. Characters appear only in the runtime's
-- existing constructor-layout serialization, never as compiler type tags.
module Representation.Types
  (Kind(..),Rep(..),LayoutDef(..),layoutParts,scalarLayout,layoutKind,LayoutTable,
   ProductShape(..),ProductField(..),productParts,productOwners,productFields,productFieldWidth,
   ProductEvidence(..),emptyProductEvidence,productLayout,productLayouts,
   CallSignature(..),signatureParts,ShapeType(..),PrimitiveShape(..),kindTag) where
import Core.Syntax (Core)
import qualified Data.Map.Strict as M
import qualified Data.Map.Lazy as L
import qualified Data.Set as S
import Data.Graph (SCC(..),stronglyConnComp)
data Kind = Managed | RawWord | RawAddr | RawF64 | RawF32 deriving (Eq,Ord,Show)
data Rep = ScalarRep Kind | UniformRep | TextRep | DataRep Int | LayoutRep String deriving (Eq,Ord,Show)
-- Finite, checked type graphs. Recursive fields name another table entry;
-- neither call order nor constructor occurrences determine these fields.
data LayoutDef = LayoutDef Int (M.Map Int [Maybe Rep])
               | ScalarLayoutDef Int Int Rep deriving (Eq,Ord,Show)
layoutParts (LayoutDef tid variants)=(tid,variants)
layoutParts (ScalarLayoutDef tid variant payload)=(tid,M.singleton variant [Just payload])
scalarLayout (ScalarLayoutDef _ variant payload)=Just (variant,payload)
scalarLayout _=Nothing
type LayoutTable = M.Map String LayoutDef
-- A value ABI, separate from the nominal heap layout. Only complete checked
-- single-constructor definitions qualify. Owned fields keep individual references;
-- a heap/generic boundary materializes the original constructor and transfers them.
data ProductShape = ProductShape Int Int [Kind]
                  | OwnedProductShape Int Int [Kind] [Bool]
                  | NestedProductShape Int Int [ProductField] deriving (Eq,Ord,Show)
data ProductField = ProductWord Kind Bool | ProductNested ProductShape deriving (Eq,Ord,Show)
productParts (ProductShape tid variant kinds)=(tid,variant,kinds)
productParts (OwnedProductShape tid variant kinds _)=(tid,variant,kinds)
productParts (NestedProductShape tid variant fields)=(tid,variant,concatMap kinds fields)
  where kinds (ProductWord k _)=[k]
        kinds (ProductNested shape)=let (_,_,ks)=productParts shape in ks
productOwners (ProductShape _ _ kinds)=replicate (length kinds) False
productOwners (OwnedProductShape _ _ _ owned)=owned
productOwners (NestedProductShape _ _ fields)=concatMap owners fields
  where owners (ProductWord _ owned)=[owned]
        owners (ProductNested shape)=productOwners shape
productFields (ProductShape _ _ kinds)=[ProductWord k False | k<-kinds]
productFields (OwnedProductShape _ _ kinds owners)=zipWith ProductWord kinds owners
productFields (NestedProductShape _ _ fields)=fields
productFieldWidth (ProductWord _ _)=1
productFieldWidth (ProductNested shape)=let (_,_,ks)=productParts shape in length ks
data ProductEvidence = ProductEvidence
  { productValues :: M.Map Core ProductShape,
    productArguments :: M.Map String [Maybe ProductShape],
    productResults :: M.Map String (Maybe ProductShape)
  } deriving (Eq,Show)
emptyProductEvidence = ProductEvidence M.empty M.empty M.empty

productLayout :: Int -> LayoutTable -> String -> Maybe ProductShape
productLayout capacity table key=M.lookup key (productLayouts capacity table)

-- Layout choices depend on the complete type graph and target capacity, not
-- on the order in which a caller reaches a type. Recursive edges stay boxed.
-- Memoize the finite acyclic expansion; each chosen packet has at most eight
-- leaves. An over-wide expansion keeps the original immediate-field packet.
productLayouts :: Int -> LayoutTable -> M.Map String ProductShape
productLayouts capacity table=M.mapMaybe id choices
  where
    limit=min 8 capacity
    references def=[key | Just (LayoutRep key)<-concat (M.elems (snd (layoutParts def)))]
    recursive=S.fromList (concat [keys | CyclicSCC keys<-stronglyConnComp
      [(key,key,references def) | (key,def)<-M.toList table]])
    choices=L.map choose table
    choose def=case def of
      LayoutDef tid variants -> case M.toList variants of
        [(variant, fields)] | not (null fields) && length fields <= limit ->
          do leaves<-traverse field fields
             let (kinds,owners)=unzip leaves
                 original=if or owners then OwnedProductShape tid variant kinds owners else ProductShape tid variant kinds
                 expanded=zipWith expand fields [ProductWord k o | (k,o)<-leaves]
             pure (if sum (map productFieldWidth expanded)<=limit && any nested expanded
                   then NestedProductShape tid variant expanded else original)
        _ -> Nothing
      _ -> Nothing
    nested ProductNested {}=True
    nested _=False
    expand (Just (LayoutRep key)) fallback
      | S.notMember key recursive,Just (Just shape)<-M.lookup key choices=ProductNested shape
      | otherwise=fallback
    expand _ fallback=fallback
    field (Just (ScalarRep k)) = Just (k,False)
    field (Just (DataRep tid)) = Just (Managed,tid/=0 && tid/=1)
    field (Just TextRep) = Just (Managed,True)
    field (Just UniformRep) = Just (Managed,True)
    field (Just (LayoutRep key)) = case M.lookup key table of
      Just ScalarLayoutDef {} -> either (const Nothing) (\k->Just (k,False)) (layoutKind table key)
      Just LayoutDef {} -> Just (Managed,True)
      _ -> Nothing
    field _ = Nothing

layoutKind :: LayoutTable -> String -> Either String Kind
layoutKind table=go S.empty
  where
    go seen key | S.member key seen=Left "cyclic scalar layout"
    go seen key=case M.lookup key table of
      Nothing->Left ("missing checked layout "++key)
      Just LayoutDef {}->Right Managed
      Just (ScalarLayoutDef _ _ payload)->leaf (S.insert key seen) payload
    leaf _ (ScalarRep k)=Right k
    leaf _ (DataRep tid) | tid==0 || tid==1=Right Managed
    leaf seen (LayoutRep key)=case M.lookup key table of
      Just ScalarLayoutDef {}->go seen key
      _->Left "scalar layout contains a boxed payload"
    leaf _ _=Left "scalar layout contains a managed payload"
-- ClosedSignature certifies a complete monomorphic checked type, even when
-- its aggregate layout is not available (for example, hidden constructor
-- variables). Complete aggregates refer to the separate checked layout table.
-- It prevents representation inference from cloning a closed List Int helper
-- merely because two calls expose different lengths of the same list.
data CallSignature = CallSignature [Maybe Rep] (Maybe Rep)
                   | ClosedSignature [Maybe Rep] (Maybe Rep) deriving (Eq,Show)
signatureParts (CallSignature ps r) = (ps,r)
signatureParts (ClosedSignature ps r) = (ps,r)
data ShapeType = AnyValue | KnownValue Rep deriving (Eq,Show)
data PrimitiveShape = PrimitiveShape [ShapeType] ShapeType deriving (Eq,Show)
kindTag :: Kind -> Char
kindTag kind=case kind of Managed->'t';RawWord->'w';RawAddr->'a';RawF64->'d';RawF32->'f'
