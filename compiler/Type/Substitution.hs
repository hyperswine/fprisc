{-# LANGUAGE FlexibleContexts #-}
-- Instantiation of already checked types. This never inspects expressions or
-- infers a type: only explicitly flexible variables may receive a solution.
module Type.Substitution
  (Substitution,variables,schemeVariables,applyType,applyScheme,freshen,freshSubstitution,unifyTypes) where
import Type.Syntax
import Type.Relation (sameType)
import Control.Monad.State.Strict
import Control.Monad (unless,zipWithM_)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

type Variables=(S.Set Int,S.Set Int)
variables :: Type -> Variables
variables t=case t of
  TV v->(S.singleton v,S.empty)
  TAp a b->variables a<>variables b
  TFn a b->variables a<>variables b
  TTupT xs->mconcat (map variables xs)
  TLayout a->variables a
  TRec r->row r
  _->mempty
  where row (RV v)=(S.empty,S.singleton v); row (RExt _ a r)=variables a<>row r; row RNil=mempty
schemeVariables :: Scheme -> Variables
schemeVariables (Forall qs rs ty)=let (a,b)=variables ty in (a S.\\ S.fromList qs,b S.\\ S.fromList rs)
data Substitution=Substitution (M.Map Int Type) (M.Map Int Row) deriving Show
applyType :: Substitution -> Type -> Type
applyType sub@(Substitution ts rs) ty=case ty of
  TV v->maybe ty (applyType sub) (M.lookup v ts)
  TAp a b->TAp (applyType sub a) (applyType sub b)
  TFn a b->TFn (applyType sub a) (applyType sub b)
  TTupT xs->TTupT (map (applyType sub) xs)
  TLayout a->TLayout (applyType sub a)
  TRec r->TRec (row r)
  _->ty
  where row (RV v)=maybe (RV v) row (M.lookup v rs)
        row (RExt n a r)=RExt n (applyType sub a) (row r)
        row RNil=RNil

-- Alpha-rename quantifiers away from substitution images before applying it.
-- Free outer variables stay free; local polymorphic bindings keep their scope.
applyScheme :: Substitution -> Scheme -> Scheme
applyScheme (Substitution ts rs) (Forall qs rqs ty)=Forall qs' rqs' (applyType scoped renamed)
  where
    images=mconcat (map variables (M.elems ts)++map (variables . TRec) (M.elems rs))
    (tv,rv)=variables ty<>images
    base=minimum (0:M.keys ts++M.keys rs++S.toList tv++S.toList rv++qs++rqs)-1
    qs'=take (length qs) [base,base-1..]
    rqs'=take (length rqs) [base-length qs,base-length qs-1..]
    renamed=applyType (Substitution (M.fromList (zip qs (map TV qs'))) (M.fromList (zip rqs (map RV rqs')))) ty
    scoped=Substitution (M.withoutKeys ts (S.fromList qs)) (M.withoutKeys rs (S.fromList rqs))

freshen :: Int -> Scheme -> (Type,Variables,Int)
freshen start sc@(Forall _ _ ty)=let (sub,flex,next)=freshSubstitution start sc in (applyType sub ty,flex,next)

-- The same fresh instantiation can span a code interface and its separately
-- quantified capture schemes. Caller variables must never become flexible.
freshSubstitution :: Int -> Scheme -> (Substitution,Variables,Int)
freshSubstitution start (Forall qs rs ty)=(sub,(S.fromList tvs,S.fromList rvs),base+length qs+length rs)
  where
    vars=variables ty
    base=max start (1+maximum (0:qs++rs++S.toList (fst vars)++S.toList (snd vars)))
    tvs=take (length qs) [base..]
    rvs=take (length rs) [base+length qs..]
    sub=Substitution (M.fromList (zip qs (map TV tvs))) (M.fromList (zip rs (map RV rvs)))

data U=U Substitution Variables Int
unifyTypes :: Variables -> Int -> [(Type,Type)] -> Either String (Substitution,Int)
unifyTypes flexible start pairs=do
  let vars=flexible<>mconcat [variables a<>variables b | (a,b)<-pairs]
      first=max start (1+maximum (0:S.toList (fst vars)++S.toList (snd vars)))
  U sub _ next<-execStateT (mapM_ (uncurry unify) pairs) (U (Substitution M.empty M.empty) flexible first)
  pure (sub,next)
  where
    failU message=lift (Left ("checked type instantiation: "++message))
    solve ty=gets (\(U sub _ _)->applyType sub ty)
    bindT v ty=do
      U (Substitution ts rs) (vs,_) _<-get
      unless (v `S.member` vs) (failU "rigid type variable")
      unless (v `S.notMember` fst (variables ty)) (failU "recursive type substitution")
      modify (\(U _ flex n)->U (Substitution (M.insert v ty ts) rs) flex n)
    bindR v row=do
      U (Substitution ts rs) (_,vs) _<-get
      unless (v `S.member` vs) (failU "rigid row variable")
      unless (v `S.notMember` snd (variables (TRec row))) (failU "recursive row substitution")
      modify (\(U _ flex n)->U (Substitution ts (M.insert v row rs)) flex n)
    unify a0 b0=do
      a<-solve a0;b<-solve b0
      U _ (tvs,_) _<-get
      if sameType a b then pure () else case (a,b) of
        (TV v,_) | v `S.member` tvs->bindT v b
        (_,TV v) | v `S.member` tvs->bindT v a
        (TAp f x,TAp g y)->unify f g>>unify x y
        (TFn x y,TFn u v)->unify x u>>unify y v
        (TTupT xs,TTupT ys) | length xs==length ys->zipWithM_ unify xs ys
        (TLayout x,TLayout y)->unify x y
        (TRec x,TRec y)->rows x y
        _->failU ("incompatible types "++show a++" and "++show b)
    fields (RExt n ty rest)=let (fs,tail')=fields rest in (M.insert n ty fs,tail')
    fields tail'=(M.empty,tail')
    extend fs tail'=foldr (uncurry RExt) tail' (M.toAscList fs)
    rows a b=do
      let (af,at)=fields a;(bf,bt)=fields b
      mapM_ (\n->unify (af M.! n) (bf M.! n)) (M.keys (M.intersection af bf))
      let ax=af `M.difference` bf;bx=bf `M.difference` af
      case (M.null ax,M.null bx) of
        (True,True)->tails at bt
        (True,False)->tails at (extend bx bt)
        (False,True)->tails bt (extend ax at)
        _->do
          U sub (ts,rs) next<-get
          put (U sub (ts,S.insert next rs) (next+1))
          tails at (extend bx (RV next))
          tails bt (extend ax (RV next))
    tails a0 b0=do
      aType<-solve (TRec a0);bType<-solve (TRec b0)
      let a=case aType of TRec r->r;_->a0
          b=case bType of TRec r->r;_->b0
      U _ (_,rvs) _<-get
      if sameType (TRec a) (TRec b) then pure () else case (a,b) of
        (RV v,_) | v `S.member` rvs->bindR v b
        (_,RV v) | v `S.member` rvs->bindR v a
        (RExt {},RExt {})->rows a b
        _->failU "incompatible record rows"
