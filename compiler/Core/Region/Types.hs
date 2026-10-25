-- Copyability/boundedness over checked types and constructor schemes. No
-- source AST conversion or type inference belongs in a region consumer.
module Core.Region.Types (ValueModel,valueModel,copyable,bounded) where
import Core.Typed.Syntax (TypeContext(..))
import Type.Syntax
import Control.Monad (unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Variant=Variant [Int] [Type] deriving Eq
data ValueModel=ValueModel (S.Set String) (M.Map String [Variant]) deriving Eq

valueModel :: TypeContext -> Either String ValueModel
valueModel (TypeContext linears schemas)=do
  entries<-mapM variant (M.toList schemas)
  let model=M.fromListWith (++) [entry | Just entry<-entries]
  mapM_ (\vs->unless (length (S.fromList [length ps | Variant ps _<-vs])==1)
    (Left "region types: inconsistent nominal constructor arity")) (M.elems model)
  pure (ValueModel (S.fromList linears) model)
  where
    variant (name,Forall _ _ ty)=
      let (fields,result)=arrows ty
      in case spine result of
        (TC owner,args)->do
          ps<-mapM (\t->case t of TV n->Right n;_->Left ("region types: nonparametric constructor "++name)) args
          unless (length ps==S.size (S.fromList ps)) (Left ("region types: repeated constructor parameter "++name))
          pure (Just (owner,[Variant ps fields]))
        _->pure Nothing -- tuples and record aliases are structural types
    arrows (TFn a b)=let (as,r)=arrows b in (a:as,r)
    arrows t=([],t)

copyable,bounded :: ValueModel -> Type -> Bool
copyable=property False
bounded=property True

property :: Bool -> ValueModel -> Type -> Bool
property finite (ValueModel linears declarations)=check S.empty
  where
    check seen ty=case ty of
      TTupT ts->all (check seen) ts
      TRec row->checkRow seen row
      -- Evidence describes one fixed element type throughout the activation;
      -- it is a compiler-generated immutable layout descriptor.
      TLayout _->True
      _->case spine ty of
        (TC n,as)
          | n `elem` ["Int","Bool","Unit","Atom","I64","Word","F64","I32"]->null as
          | n=="String"->not finite && null as
          | n=="Vector"->length as==1 -- the existing move/copy-by-handle rule
          | n=="List"->not finite && length as==1 && all (check seen) as
          | n=="Result"->length as==2 && all (check seen) as
          | n `S.member` linears->False
          | Just variants<-M.lookup n declarations,
            all (\(Variant ps _)->length ps==length as) variants,
            all (check seen) as->
              if n `S.member` seen then not finite else
                all (\(Variant ps fields)->all (check (S.insert n seen) . substitute (M.fromList (zip ps as))) fields) variants
        _->False
    checkRow _ RNil=True
    checkRow seen (RExt _ t rest)=check seen t && checkRow seen rest
    checkRow _ _=False
    -- Substitute constructor parameters once. Substitution images belong to
    -- the caller and must not be substituted again through coincident IDs.
    substitute env t=case t of
      TV v->M.findWithDefault t v env
      TAp a b->TAp (substitute env a) (substitute env b)
      TFn a b->TFn (substitute env a) (substitute env b)
      TTupT xs->TTupT (map (substitute env) xs)
      TLayout x->TLayout (substitute env x)
      TRec r->TRec (row env r)
      _->t
    row env (RExt n t rest)=RExt n (substitute env t) (row env rest)
    row _ r=r

spine :: Type -> (Type,[Type])
spine=go [] where go as (TAp f a)=go (a:as) f;go as h=(h,as)
