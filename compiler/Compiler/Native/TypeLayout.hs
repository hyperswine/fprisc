{-# LANGUAGE FlexibleContexts #-}
-- Checked type definitions, not observed constructor occurrences, determine
-- an aggregate instance's field representations. Runtime nominal ids stay
-- unchanged; keys distinguish instantiations in this finite compiler table.
module Compiler.Native.TypeLayout (layoutsFor, layoutsForRaw, representation, uniformType, openRecord) where
import Compiler.DataLayout
import Core.Typed.Syntax (TypeContext(..))
import Core.Typed.Monomorphize (typeKey,typeEmbeds)
import Type.Syntax
import qualified Type.Substitution as U
import Representation.Types
import Control.Monad.State.Strict
import Control.Monad (unless,when,forM,mplus)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

scalar :: Type -> Maybe Rep
scalar ty=case ty of
  TC "$uniform.value"->Just UniformRep
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

representation :: LayoutTable -> Type -> Maybe Rep
representation _ original | openRecord original=Just UniformRep
representation layouts original=let ty=uniformType original in case scalar ty of
  Just rep->Just rep
  Nothing->case typeKey ty of
    Right key | M.member key layouts->Just (LayoutRep key)
    _->Nothing

-- An open row has no finite native field layout. Its complete runtime object
-- keeps tagged fields; concrete callers convert using their own checked shape.
openRecord :: Type -> Bool
openRecord (TRec row)=open row
  where open (RExt _ _ rest)=open rest
        open (RV _)=True
        open RNil=False
openRecord _=False

layoutsFor :: Layouts -> TypeContext -> [Type] -> Either String LayoutTable
layoutsFor=layoutsWithHidden True

-- Allocator/bootstrap raw units retain their explicitly allocation-free ABI.
layoutsForRaw :: Layouts -> TypeContext -> [Type] -> Either String LayoutTable
layoutsForRaw=layoutsWithHidden False

layoutsWithHidden hidden physical (TypeContext _ constructors) roots=classify . complete <$> execStateT (mapM_ (visit [] . uniformType) roots) M.empty
  where
    -- The choice is a function of the complete instantiated definition. A
    -- recursive, multi-variant, unknown or heap-valued payload stays boxed.
    classify table=M.mapWithKey (\key def->case immediate table S.empty key of
      Just (tid,v,payload)->ScalarLayoutDef tid v payload
      Nothing->def) table
    immediate table seen key
      | S.member key seen=Nothing
      | otherwise=do
          def<-M.lookup key table
          let (tid,vs)=layoutParts def
          case M.toList vs of
            [(variant,[Just payload])] | scalarPayload table (S.insert key seen) payload ->Just (tid,variant,payload)
            _->Nothing
    scalarPayload _ _ ScalarRep {}=True
    scalarPayload _ _ (DataRep tid)=tid==0 || tid==1
    scalarPayload table seen (LayoutRep key)=case immediate table seen key of Just _->True;_->False
    scalarPayload _ _ _=False
    -- Hidden constructor variables have uniform storage. Construction must
    -- promote those fields and extraction must check the requested layout;
    -- this evidence alone is not permission to reinterpret their raw bits.
    complete table=let next=M.filter (known table) table in
      if M.size next==M.size table then table else complete next
    known table (LayoutDef _ vs)=all fieldKnown (concat (M.elems vs))
      where fieldKnown Nothing=False
            fieldKnown (Just (LayoutRep key))=M.member key table
            fieldKnown _=True
    bad=lift . Left . ("checked aggregate layout: "++)
    nominal (TAp f _)=nominal f
    nominal (TC n)=Just n
    nominal _=Nothing
    arrows (TFn a b)=let (as,r)=arrows b in (a:as,r)
    arrows r=([],r)
    closed t=U.variables t==mempty
    variants ty=case ty of
      TTupT ts->case M.lookup ("Tup"++show (length ts)) (constructorLayouts physical)
                       `mplus` wideTup ("Tup"++show (length ts)) of
        Just (tid,v,ar) | ar==length ts->pure (Just (tid,[(v,ts)]))
        _->bad "missing tuple authority"
      TRec row->do
        fs<-fields row
        let ordered=sortOn fst fs
        unless (length fs==S.size (S.fromList (map fst fs))) (bad "duplicate record field")
        case M.lookup (map fst ordered) (shapeLayouts physical) of
          Just tid->pure (Just (tid,[(length fs,map snd ordered)]))
          Nothing->bad "missing closed record authority"
      _->do
        choices<-forM [(name,sc,layout) | (name,sc)<-M.toList constructors,
                       Just layout<-[M.lookup name (constructorLayouts physical)],
                       let Forall _ _ ct=sc,nominal (snd (arrows ct))==nominal ty,
                       nominal ty/=Nothing] $ \(name,Forall vs rs ct,(tid,v,ar))->do
          let (args,result)=arrows ct
          unless (ar==length args) (bad ("constructor arity disagrees at "++name))
          (sub,_)<-either bad pure (U.unifyTypes (S.fromList vs,S.fromList rs) 0 [(result,ty)])
          let instantiated=map ((if hidden then uniformType else id) . U.applyType sub) args
          pure (tid,v,instantiated)
        case choices of
          []->pure Nothing -- opaque runtime types retain their existing ABI
          (tid,_,_):_->do
            unless (all (\(t,_,_)->t==tid) choices) (bad "nominal type has inconsistent runtime ids")
            unless (length choices==S.size (S.fromList [v | (_,v,_)<-choices])) (bad "duplicate constructor variant")
            pure (if all (all closed . (\(_,_,fs)->fs)) choices
                  then Just (tid,[(v,fs) | (_,v,fs)<-choices]) else Nothing)
    fields RNil=pure []
    fields (RExt n t r)=((n,t):) <$> fields r
    fields (RV _)=bad "open record row"
    visit active ty
      | not (closed ty) || scalar ty/=Nothing=pure ()
      | otherwise=do
          key<-either bad pure (typeKey ty)
          known<-gets (M.member key)
          unless known $ do
            shape<-variants ty
            case shape of
              Nothing->pure ()
              Just (tid,vs)->do
                when (any (\prior->nominal prior==nominal ty && typeEmbeds prior ty) active)
                  (bad "expanding recursive type requires a finite layout graph")
                -- Publish the nominal knot before following recursive fields.
                modify (M.insert key (LayoutDef tid M.empty))
                mapM_ (visit (ty:active)) (concatMap snd vs)
                table<-get
                modify (M.insert key (LayoutDef tid (M.fromList [(v,map (representation table) fs) | (v,fs)<-vs])))

-- Source variables and open records occupy stable tagged slots. A container
-- keeps its finite surrounding graph even when a child has an open row.
uniformType :: Type -> Type
uniformType ty | openRecord ty=TC "$uniform.value"
uniformType ty=case ty of
  TV _->TC "$uniform.value"
  TAp f x->TAp (uniformType f) (uniformType x)
  TFn a b->TFn (uniformType a) (uniformType b)
  TTupT ts->TTupT (map uniformType ts)
  TRec row->TRec (fields row)
  TLayout t->TLayout (uniformType t)
  _->ty
  where
    fields (RExt n t rest)=RExt n (uniformType t) (fields rest)
    fields row=row
