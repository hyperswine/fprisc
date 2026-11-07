-- Checked immediate Base layouts and their latent field types. Workers keep
-- tagged values and a nominal guard; type evidence never licenses an unchecked
-- projection of a dynamically received value. Unfold only the selected field
-- step, not an eager tree of every instantiated recursive type.
module Core.Opt.ProductParameters
  (ProductParameters,emptyProductParameters,checkedProductParameters,parameterProduct,
   CheckedKinds,checkedKinds,rawKind,
   VariantLayout,StorageLayout(..),StorageField(..),storagePlans,storageLists,variantResults,withoutVariantResults,renameProductParameters,expandProductParameter,productParameterKey) where
import Compiler.DataLayout
import Core.Syntax (Prog)
import Core.Typed.Syntax (TypeContext(..),binderName)
import Ownership.Shape (isLin)
import Ownership.TypeShape (linShapeT)
import Type.Substitution (variables)
import Core.Region.Interface
import Type.Syntax
import KernelKinds (Kind(..))
import Control.DeepSeq (deepseq)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

type Shape=(Int,Int,Int)
-- Constructor parameter variables are canonical positional indices. Negative
-- variables are hidden/unknown. Substitution is one-shot, so a caller's type
-- variables cannot be captured by a constructor scheme's local quantifiers.
data Definition=Definition Int Shape [Type] deriving (Eq,Ord,Show)
-- Nominal type id and the complete declared variant-to-arity table.
type VariantLayout=(Int,M.Map Int Int)
-- Only recursive children belong to the private representation domain. Other
-- fields retain their normal runtime values, including managed references.
data StorageField = PublicField | ChildField | InlineField deriving (Eq,Ord,Show)
data StorageLayout = ListStorage VariantLayout
                   | FieldStorage Int Int [Int] [StorageField] VariantLayout
                   deriving (Eq,Ord,Show)
type Entries a=M.Map String ([String],a)
type ResultTable=M.Map String ([String],VariantLayout)
-- Raw-word kinds of each checked function's parameters and result, from its
-- checked interface (P2 signature bridge, docs/2026-11-08-P2-SIGNATURE-BRIDGE.md).
-- Nothing: the checked type is not a raw word (a variable, a nominal type, a
-- String, ...). Keyed like the other entries, so a renamed or re-parameterized
-- function never reads another body's kinds.
type CheckedKinds=M.Map String ([Maybe Kind],Maybe Kind)
data ProductParameters=ProductParameters Layouts (M.Map String Definition)
  (M.Map String ([String],M.Map Int Type)) ResultTable (Entries StorageLayout) (Entries (Int,StorageLayout))
  (Entries ([Maybe Kind],Maybe Kind))
emptyProductParameters :: ProductParameters
emptyProductParameters=ProductParameters (Layouts M.empty M.empty) M.empty M.empty M.empty M.empty M.empty M.empty

-- The raw-word ABI kind a checked type denotes, if any.
rawKind :: Type -> Maybe Kind
rawKind ty=case ty of
  TC "Int"->Just KI
  TC "F64"->Just KD
  TC "F32"->Just KS
  TC "Bool"->Just KB
  _->Nothing

-- The checked kinds of the functions whose parameters still match.
checkedKinds :: Prog -> ProductParameters -> CheckedKinds
checkedKinds program (ProductParameters _ _ _ _ _ _ kinds)=matching program kinds

checkedProductParameters :: Layouts -> TypeContext -> M.Map String Interface -> ProductParameters
checkedProductParameters layouts (TypeContext linears constructors) interfaces=
  -- A module must not retain the whole linked constructor/type catalog just
  -- because one of its entries has a product parameter. Force canonical
  -- field types before releasing the original declaration/substitution thunks.
  table `deepseq` forced kinds `seq` ProductParameters localLayouts localModel table results producers readers kinds
  where
    -- every entry is a small constant; force them so the interfaces are not retained
    kinds=M.mapMaybe (\face->fmap (\bs->(map binderName bs,(map rawKind (interfaceArguments face),rawKind (interfaceResult face))))
                                   (interfaceParameters face)) interfaces
    forced=M.foldr (\(ps,(as,r)) acc->length ps `seq` foldr seq (r `seq` acc) as) ()
    choices=M.fromListWith S.union [(owner,S.singleton definition) |
      (name,Forall _ _ ty)<-M.toList constructors,
      let (fields,result)=arrows ty,(TC owner,args)<-[spine result],
      let definition=do
            shape@(_,_,width)<-M.lookup name (constructorLayouts layouts)
            params<-traverse variable args
            if width/=length fields || length params/=S.size (S.fromList params) then Nothing else
              let indices=M.fromList (zip params [0..])
                  canonical=mapVariables (\v->TV (M.findWithDefault (-1) v indices))
              in Just (Definition (length params) shape (map canonical fields))]
    rawModel=M.mapMaybe (\defs->case S.toList defs of [Just def]->Just def;_->Nothing) choices
    definitions=M.mapMaybe (sequence . S.toList) choices
    results=M.mapMaybe (\face->do bs<-interfaceParameters face
                                  layout@(_,vs)<-scalarLayout (interfaceResult face)
                                  if M.size vs>1 then Just (map binderName bs,layout) else Nothing) interfaces
    listLayout (TAp (TC "List") el)=do
      layout<-scalarLayout el
      if variables el==mempty && not (isLin (linShapeT linears el)) then Just (ListStorage layout) else Nothing
    listLayout ty=fieldLayout ty
    -- One payload-bearing constructor plus any number of nullary alternatives.
    -- Inspect its declaration once; self-recursion stops at the managed child.
    fieldLayout ty=do
      let (headType,args)=spine ty
      TC owner<-Just headType
      ds<-M.lookup owner definitions
      [(t,v,n,fieldTypes)]<-Just [(tid,var,count,fs) | Definition count (tid,var,k) fs<-ds,k>0]
      let other=[var | Definition _ (_,var,0) _<-ds]
          instantiate=mapVariables (\i->M.findWithDefault (TV (-1)) i params)
          params=M.fromList (zip [0..] args)
          ts=map instantiate fieldTypes
      if t<0x20000000 || owner `elem` linears || n/=length args || variables ty/=mempty
        || isLin (linShapeT linears ty) || any ((/=mempty) . variables) ts
        then Nothing else do
          [(index,element)]<-Just [(i,l) | (i,ft)<-zip [0::Int ..] ts,ft/=ty,Just l<-[scalarLayout ft]]
          let roles=[if i==index then InlineField else if ft==ty then ChildField else PublicField
                    | (i,ft)<-zip [0..] ts]
          Just (FieldStorage t v other roles element)
    producers=M.mapMaybe (\face->do bs<-interfaceParameters face
                                    layout<-listLayout (interfaceResult face)
                                    Just (map binderName bs,layout)) interfaces
    readers=M.mapMaybe (\face->do bs<-interfaceParameters face
                                  [(i,layout)]<-Just [(i,l) | (i,t)<-zip [0..] (interfaceArguments face),Just l<-[listLayout t]]
                                  Just (map binderName bs,(i,layout))) interfaces
    scalarLayout ty=do
      let (headType,args)=spine ty
      TC owner<-Just headType
      ds<-M.lookup owner definitions
      let scalar (TV i)=case drop i args of
            arg:_ | i>=0->baseScalar arg
            _->False
          scalar t=baseScalar t
          baseScalar t=t `elem` [tInt,tBool,tUnit]
          fields (Definition n (_,_,_) ts)=n==length args && all scalar ts
          shapes=[(t,v,k) | Definition _ (t,v,k) _<-ds]
          variants=M.fromList [(v,k) | (_,v,k)<-shapes]
      case shapes of
        (tid,_,_):_ | owner `notElem` linears,all fields ds,all (\(t,_,_)->t==tid) shapes,
                      M.size variants==length ds,any (>0) variants->
                        Just (tid,variants)
        _->Nothing
    model=M.map (\(Definition count shape fields)->Definition count shape (map (layoutType rawModel) fields)) rawModel
    table=M.mapMaybe plan interfaces
    plan face=do
      bs<-interfaceParameters face
      let types=M.fromList [(i,layoutType rawModel ty) | (i,ty)<-zip [0..] (interfaceArguments face),
                                    Just _<-[immediate layouts model ty]]
      if M.null types then Nothing else Just (map binderName bs,types)
    (reachable,dependencies)=layoutDependencies model (concatMap (M.elems . snd) (M.elems table))
    localModel=M.map (\d@(Definition _ _ fields)->fields `deepseq` d) (M.restrictKeys model reachable)
    (records,tuples)=structuralDependencies dependencies
    localLayouts=Layouts (M.restrictKeys (constructorLayouts layouts) (S.map (\w->"Tup"++show w) tuples))
      (M.restrictKeys (shapeLayouts layouts) records)
    variable (TV v)=Just v
    variable _=Nothing

-- This evidence describes product structure, not scalar operations or closure
-- signatures. A function, sum, open row or runtime container is one opaque
-- tagged field. Do not retain its potentially large internal type graph.
-- Variables remain substitutable; a concrete product supplied for one is
-- discovered when the selected worker's fields are instantiated.
layoutType :: M.Map String Definition -> Type -> Type
layoutType model ty=case ty of
  TV _->ty
  TTupT ts->TTupT (map go ts)
  TRec row->case closedFields row of
    Just fs->TRec (foldr (\(n,t) rest->RExt n (go t) rest) RNil fs)
    Nothing->opaque
  _->case spine ty of
    (TC name,args) | Just (Definition count (_,_,width) _)<-M.lookup name model,
                    count==length args,width>0->foldl TAp (TC name) (map go args)
    _->opaque
  where
    go=layoutType model
    opaque=TC "$base.boxed"

arrows :: Type -> ([Type],Type)
arrows (TFn a b)=let (as,r)=arrows b in (a:as,r)
arrows t=([],t)
spine :: Type -> (Type,[Type])
spine=go [] where go as (TAp f a)=go (a:as) f;go as h=(h,as)

-- Do not recursively substitute images. Row variables never supply a finite
-- shape and their identity is irrelevant to this representation contract.
mapVariables :: (Int -> Type) -> Type -> Type
mapVariables f ty=case ty of
  TV v->f v
  TAp a b->TAp (go a) (go b)
  TFn a b->TFn (go a) (go b)
  TTupT xs->TTupT (map go xs)
  TLayout a->TLayout (go a)
  TRec r->TRec (row r)
  _->ty
  where
    go=mapVariables f
    row (RExt n t r)=RExt n (go t) (row r)
    row (RV _)=RV 0
    row RNil=RNil
closedFields :: Row -> Maybe [(String,Type)]
closedFields RNil=Just []
closedFields (RExt n t r)=((n,t):) <$> closedFields r
closedFields (RV _)=Nothing

immediate :: Layouts -> M.Map String Definition -> Type -> Maybe (Shape,[Type])
immediate layouts model ty=case ty of
  TTupT ts->do
    shape@(_,_,width)<-case M.lookup ("Tup"++show (length ts)) (constructorLayouts layouts) of
      Just x->Just x
      Nothing->wideTup ("Tup"++show (length ts))
    if width==length ts && width>0 then Just (shape,ts) else Nothing
  TRec row->do
    fields<-closedFields row
    let ordered=M.fromList fields
    tid<-M.lookup (M.keys ordered) (shapeLayouts layouts)
    if not (null fields) && M.size ordered==length fields
      then Just ((tid,length fields,length fields),M.elems ordered) else Nothing
  _->case spine ty of
    (TC owner,args)->do
      Definition count shape@(_,_,width) fields<-M.lookup owner model
      if count/=length args || width<1 then Nothing else
        let substitution=M.fromList (zip [0..] args)
        in Just (shape,map (mapVariables (\v->M.findWithDefault (TV (-1)) v substitution)) fields)
    _->Nothing

parameterProduct :: ProductParameters -> String -> [String] -> Int -> Maybe Shape
parameterProduct (ProductParameters layouts model table _ _ _ _) name params index=do
  (checked,types)<-M.lookup name table
  if params/=checked then Nothing else M.lookup index types >>= fmap fst . immediate layouts model

variantResults :: Prog -> ProductParameters -> M.Map String VariantLayout
variantResults program (ProductParameters _ _ _ results _ _ _)=matching program results

matching :: Prog -> Entries a -> M.Map String a
matching program=M.mapMaybeWithKey select
  where select n (ps,value)=case M.lookup n program of
          Just (qs,_) | ps==qs->Just value
          _->Nothing

storageLists :: Prog -> ProductParameters -> (M.Map String VariantLayout,M.Map String (Int,VariantLayout))
storageLists program facts=(M.mapMaybe onlyList ps,M.mapMaybe getReader rs)
  where
    (ps,rs)=storagePlans program facts
    onlyList (ListStorage layout)=Just layout
    onlyList _=Nothing
    getReader (i,layout)=fmap ((,) i) (onlyList layout)

storagePlans :: Prog -> ProductParameters -> (M.Map String StorageLayout,M.Map String (Int,StorageLayout))
storagePlans program (ProductParameters _ _ _ _ producers readers _)=
  let owned=matching program producers in (owned,if M.null owned then M.empty else matching program readers)

withoutVariantResults :: ProductParameters -> ProductParameters
withoutVariantResults (ProductParameters layouts model table _ _ _ kinds)=ProductParameters layouts model table M.empty M.empty M.empty kinds

-- Only the pass performing alpha-renaming may transport original interfaces.
renameProductParameters :: M.Map String ([String],[String]) -> ProductParameters -> ProductParameters
renameProductParameters renames (ProductParameters layouts model table results producers readers kinds)=
  ProductParameters layouts model (M.mapMaybeWithKey rename table) (M.mapMaybeWithKey rename results)
    (M.mapMaybeWithKey rename producers) (M.mapMaybeWithKey rename readers) (M.mapMaybeWithKey rename kinds)
  where
    rename name (ps,types)=do
      (old,new)<-M.lookup name renames
      if old==ps && length new==length old && S.size (S.fromList new)==length new
        then Just (new,types) else Nothing

-- A proven field-worker step replaces exactly one parameter by its fields.
-- Keep other parameter types with their new positions and instantiate the
-- selected constructor's field types. Heuristic steps without checked shape
-- evidence may transport untouched parameters, but cannot invent field types.
expandProductParameter :: String -> [String] -> String -> [String] -> Int -> Shape -> ProductParameters -> ProductParameters
expandProductParameter source old target new index shape@(_,_,width) evidence@(ProductParameters layouts model table results producers readers kinds)=
  case M.lookup source table of
    Just (checked,types)
      | checked==old,index>=0,index<length old,width>0,
        length new==length old-1+width,S.size (S.fromList new)==length new,
        take index new==take index old,drop (index+width) new==drop (index+1) old,
        M.notMember target table ->
          let selected=M.lookup index types >>= immediate layouts model
              shifted=M.fromList [(if i<index then i else i+width-1,ty) | (i,ty)<-M.toList types,i/=index]
              fields=case selected of
                Just (actual,ts) | actual==shape->M.fromList [(index+i,ty) | (i,ty)<-zip [0..] ts,
                  Just _<-[immediate layouts model ty]]
                _->M.empty
              next=fields `M.union` shifted
          in case selected of
            Just (actual,_) | actual/=shape->evidence
            _ | M.null next->evidence
              | otherwise->ProductParameters layouts model (M.insert target (new,next) table) results producers readers kinds
    _->evidence

-- Hash all latent representation dependencies, not an eagerly instantiated
-- tree. Traverse each referenced nominal DECLARATION once: recursive or
-- expanding recursive fields keep a finite key. Unknown variables normalize
-- identically; unrelated root declarations do not invalidate this artifact.
productParameterKey :: Prog -> ProductParameters -> String
productParameterKey program facts@(ProductParameters layouts model table _ _ _ _)=show (selected,definitions,records,tuples,variantResults program facts,storagePlans program facts)
  where
    selected=M.mapMaybeWithKey (\name (ps,types)->case M.lookup name program of
      Just (qs,_) | ps==qs->Just (M.map (mapVariables (const (TV (-1)))) types)
      _->Nothing) table
    roots=concatMap M.elems (M.elems selected)
    (reachable,types)=layoutDependencies model roots
    definitions=[(name,M.lookup name model) | name<-S.toAscList reachable]
    (labels,widths)=structuralDependencies types
    records=[(fs,M.lookup fs (shapeLayouts layouts)) | fs<-S.toAscList labels]
    tuples=[(w,M.lookup ("Tup"++show w) (constructorLayouts layouts)) | w<-S.toAscList widths]

typeNodes :: Type -> [Type]
typeNodes ty=ty:case ty of
  TAp a b->typeNodes a++typeNodes b
  TFn a b->typeNodes a++typeNodes b
  TTupT ts->concatMap typeNodes ts
  TLayout a->typeNodes a
  TRec r->rowNodes r
  _->[]
  where
    rowNodes (RExt _ t r)=typeNodes t++rowNodes r
    rowNodes _=[]

layoutDependencies :: M.Map String Definition -> [Type] -> (S.Set String,[Type])
layoutDependencies model roots=close S.empty (names roots) roots
  where
    names ts=S.fromList [n | t<-ts,TC n<-typeNodes t]
    close seen pending types=case S.minView pending of
      Nothing->(seen,types)
      Just (name,rest)->
        let fields=case M.lookup name model of Just (Definition _ _ fs)->fs;_->[]
            seen'=S.insert name seen
        in close seen' ((rest `S.union` names fields) S.\\ seen') (fields++types)

structuralDependencies :: [Type] -> (S.Set [String],S.Set Int)
structuralDependencies types=(
  S.fromList [M.keys (M.fromList fs) | ty<-types,TRec row<-typeNodes ty,Just fs<-[closedFields row]],
  S.fromList [length fs | ty<-types,TTupT fs<-typeNodes ty])
