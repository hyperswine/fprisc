{-# LANGUAGE FlexibleContexts #-}
-- Retarget a private container from a single-constructor scalar wrapper to
-- its field. A boundary with the original signature remains publicly callable.
module Core.Typed.Carrier (specializeCarriers) where
import Core.Identity
import Core.Typed.Syntax
import Core.Typed.Program
import Core.Typed.Parametric
import Core.Typed.Instantiate (constructorFunction,instantiateFunction)
import Core.Typed.Walk (allBinders,mapChildrenM)
import Core.Typed.Verify (instanceOf)
import Ownership.TypeShape (linShapeT)
import Ownership.Shape (isLin)
import Type.Syntax
import Type.Substitution (freshSubstitution)
import Control.Monad (foldM,unless,when)
import Control.Monad.State.Strict
import Data.List (mapAccumL)
import Data.Functor.Const
import qualified Data.Map.Strict as M
import qualified Data.Set as S

mapType f ty = f $ case ty of
  TFn x y -> TFn (go x) (go y)
  TAp x y -> TAp (go x) (go y)
  TTupT xs -> TTupT (map go xs)
  TLayout t -> TLayout (go t)
  TRec r -> TRec (row r)
  _ -> ty
  where
    go=mapType f
    row (RExt n t r)=RExt n (go t) (row r)
    row r=r

-- Collect only wrappers occurring as direct arguments of an imported nominal
-- result. The graph proof itself does not depend on a library or entry name.
containerArgs ty=case spine ty [] of
  (TC owner,args) | '@' `elem` owner -> [n | TC n<-args]
  _ -> []
  where spine (TAp f x) args=spine f (x:args); spine f args=(f,args)
resultType (TFn _ t)=resultType t
resultType t=t

data Edits = Edits
  { entered :: S.Set String
  , workers :: M.Map String Function
  , proofs :: S.Set (String,Type,Type)
  }
emptyEdits=Edits S.empty M.empty S.empty

specializeCarriers :: Bool -> String -> Catalog -> S.Set String -> Program
  -> Either String (Program, [(String,String)], M.Map String String)
specializeCarriers reporting home catalog pinned input
  | M.null builders = Right (input,[],M.empty)
  | M.null replacements = Right (input,notes,M.empty)
  | otherwise=do
      let schemas=M.fromList [(worker owner n,Forall ts rs (mapType replace published))
                 | (_, (owner,_,field),_,edits)<-accepted,n<-S.toList (entered edits),
                   let Forall ts rs published=programSchemas input M.! n,
                   let replace t=if t==TC owner then field else t] `M.union` programSchemas input
          arities=M.map (length . functionParameters) clones `M.union` programArities input
      case programWithAssumptions (programNamespace input) types schemas arities
              (clones `M.union` replacements `M.union` source) (programAssumptions input) of
        Right out->pure (out,notes,origins)
        Left why->pure (input,notes++[(n,"tagged container: "++why) | reporting,n<-M.keys replacements],M.empty)
  where
    types@(TypeContext linears constructors)=programTypes input
    source=programFunctions input
    exact=catalog {checkedBodies=source `M.union` checkedBodies catalog,
                   publishedSchemes=programSchemas input `M.union` publishedSchemes catalog}
    Namespace namespace=programNamespace input
    -- Group by complete nominal declaration, including alternatives with a
    -- different arity. A lone visible unary call cannot establish this fact.
    byOwner=M.fromListWith (++) [(owner,[(c,sc)]) | (c,sc@(Forall _ _ t))<-M.toList constructors,
                                  TC owner<-[resultType t]]
    wrapper owner=case M.lookup owner byOwner of
      Just [(c,Forall [] [] (TFn field (TC n)))] | n==owner,field `elem` [tInt,tBool,tUnit],
        (M.member c source || importedConstructor c),not (isLin (linShapeT linears (TC n))) -> Just (n,c,field)
      _ -> Nothing
    importedConstructor n='@' `elem` n && M.member n (generatedConstructors catalog)
    builders=M.mapMaybe (\fn->case [w | n<-containerArgs (exprType (functionBody fn)),Just w<-[wrapper n]] of
                          [w]->Just w;_->Nothing) source
    candidates e=here <> getConst (mapChildrenM (Const . candidates) e)
      where here=case exprNode e of
              Var (Global n _) | Just w<-M.lookup n builders->S.singleton w
              _->S.empty
    seeds=[(n,w,fn) | (n,fn)<-M.toList source,
              [w@(owner,_,field)]<-[S.toList (candidates (functionBody fn))],
              let t=functionType fn,let replace x=if x==TC owner then field else x,
              mapType replace t==t]
    attempts=snd (mapAccumL attempt S.empty seeds)
    attempt known (n,w,fn)=
      let verdict=runStateT (rewrite w fn) (emptyEdits {proofs=known})
      in (either (const known) (proofs . snd) verdict,(n,w,verdict))
    accepted=[(n,w,fn,edits) | (n,w,Right (fn,edits))<-attempts,not (M.null (workers edits))]
    replacements=M.fromList [(n,fn) | (n,_,fn,_)<-accepted]
    clones=M.unions [workers edits | (_,_,_,edits)<-accepted]
    origins=M.fromList [(worker owner n,n) | (_, (owner,_,_),_,edits)<-accepted,n<-S.toList (entered edits)]
    notes | reporting=[(n,"tagged container: "++why) | (n,_,Left why)<-attempts]
          | otherwise=[]
    -- An imported adapter may be demanded by independent compilation units.
    -- Give its private copy one stable home per importing artifact. Original
    -- public names and private entries for local definitions are unchanged.
    worker owner n="$carrier."++show (length owner)++"."++owner++"."++n
      ++if M.member n source then "" else ".$at."++home
    rewrite w@(owner,ctor,field) fn=do
      body<-walk (functionBody fn)
      pure fn {functionParameters=map binder (functionParameters fn),functionBody=body}
      where
        phys=mapType (\t->if t==TC owner then field else t)
        scheme (Forall vs rs t)=Forall vs rs (phys t)
        refuse=lift . Left
        require ok reason=unless ok (refuse reason)
        binders=M.fromList [(binderId b,b) | b<-functionParameters fn++allBinders (functionBody fn)]
        binder b=b {binderScheme=scheme (binderScheme b),binderShape=linShapeT linears (phys (binderType b))}
        -- A generated constructor has a unary entry (and its own fuel tick)
        -- even when that entry lives in the defining module. Recreate its
        -- checked Construct body; the same rewrite used for a local stub
        -- then turns the private constructor into an identity function.
        importedBody n
          | n==ctor && importedConstructor n=constructorFunction (programNamespace input) types n
          | '@' `elem` n=M.lookup n (checkedBodies catalog)
          | otherwise=Nothing
        definition n=case M.lookup n source of
          Just f->Just f
          Nothing->importedBody n
        private n local=do
          let target=worker owner n
          require (not (null (functionParameters local)) && S.notMember n pinned && M.notMember target (programSchemas input))
                  ("pinned, nullary or colliding entry "++n)
          require (M.lookup n (programArities input)==Just (length (functionParameters local)) &&
                   maybe False (\sc->instanceOf sc (functionType local)) (M.lookup n (programSchemas input)))
                  ("missing or incompatible published adapter "++n)
          seen<-gets (S.member n . entered)
          unless seen $ do
            modify' (\s->s {entered=S.insert n (entered s)})
            let (empty,_,_)=freshSubstitution 0 (Forall [] [] tUnit)
                fresh=instantiateFunction (Namespace (namespace++"/carrier/"++target)) types empty local
            copy<-rewrite w fresh
            modify' (\s->s {workers=M.insert target (copy {functionName=target}) (workers s)})
          pure target
        certify n old new=do
          let key=(n,old,new)
          seen<-gets (S.member key . proofs)
          unless seen $ do
            either refuse (const (pure ())) (transportClosure exact n old new)
            modify' (\s->s {proofs=S.insert key (proofs s)})
        global n sc old new
          | old==new=pure (Var (Global n sc))
          | Just local<-definition n,phys (functionType local)/=functionType local=do
              target<-private n local
              pure (Var (Global target (scheme sc)))
          | otherwise=do
              require (instanceOf sc new) ("public type exposes the wrapper at "++n)
              certify n old new
              pure (Var (Global n sc))
        pattern' p=case patNode p of
          ConstructorPattern n [x] | n==ctor && patType p==TC owner -> do
            inner<-pattern' x
            pure inner {patDisplay=patDisplay p}
          node->do
            mapped<-case node of
              Bind b->pure (Bind (binder b))
              ConstructorPattern n ps->do
                let ty=foldr (TFn . patType) (patType p) ps
                require (ty==phys ty || maybe False (\sc->either (const False) (const True) (constructorTransport sc ty (phys ty))) (M.lookup n constructors))
                        ("constructor pattern exposes the wrapper at "++n)
                ConstructorPattern n <$> mapM pattern' ps
              TuplePattern ps->TuplePattern <$> mapM pattern' ps
              RecordPattern fs->pure (RecordPattern [(n,binder b) | (n,b)<-fs])
              _->pure node
            pure p {patType=phys (patType p),patNode=mapped}
        guard' (BoolGuard x)=BoolGuard <$> walk x
        guard' (PatternGuard p x)=PatternGuard <$> pattern' p <*> walk x
        alt (Alternative ps gs x)=Alternative <$> mapM pattern' ps <*> mapM guard' gs <*> walk x
        walk e | Construct n [arg]<-exprNode e,n==ctor,exprType e==TC owner=walk arg
        walk e=do
          let old=exprType e;new=phys old
          node<-case exprNode e of
            Var (Global n sc)->global n sc old new
            Var (Local uid)->do
              when (old/=new) $ case M.lookup uid binders of
                Just b | Forall [] [] t<-binderScheme b,t==old->pure ()
                _->refuse "polymorphic local occurrence"
              pure (Var (Local uid))
            Construct n args->do
              let ty=foldr (TFn . exprType) old args
              require (ty==phys ty || maybe False (\sc->either (const False) (const True) (constructorTransport sc ty (phys ty))) (M.lookup n constructors))
                      ("opaque constructor field at "++n)
              Construct n <$> mapM walk args
            Apply _ _->do
              let spine term args=case exprNode term of
                    Apply f x->spine f ((term,x):args)
                    _->(term,args)
                  (f,args)=spine e []
                  arity (TFn _ r)=1+arity r
                  arity _=0 :: Int
                  carries x=phys (exprType x)/=exprType x
              require (not (any (carries . snd) args) || length args>=arity (exprType f))
                      "partial application captures a private carrier"
              headExpr<-walk f
              let apply f' (site,arg)=do
                    x<-walk arg
                    let r=phys (exprType site)
                    pure site {exprType=r,exprShape=linShapeT linears r,exprNode=Apply f' x}
              exprNode <$> foldM apply headExpr args
            Let b a body->do
              let Forall qs rs _=binderScheme b
              require (null qs && null rs) "polymorphic local binding"
              Let (binder b) <$> walk a <*> walk body
            Sequence a b->Sequence <$> walk a <*> walk b
            If c a b->If <$> walk c <*> walk a <*> walk b
            Match style xs arms->Match style <$> mapM walk xs <*> mapM alt arms
            LetPattern p a b->LetPattern <$> pattern' p <*> walk a <*> walk b
            TupleValue xs->TupleValue <$> mapM walk xs
            ListValue xs->ListValue <$> mapM walk xs
            Note x->Note <$> walk x
            BoolTest b x->BoolTest b <$> walk x
            IntValue n->pure (IntValue n)
            StringValue s->pure (StringValue s)
            BoolValue b->pure (BoolValue b)
            AtomValue n->pure (AtomValue n)
            Fail s->pure (Fail s)
            _->refuse "unproved carrier operation"
          pure e {exprType=new,exprShape=linShapeT linears new,exprNode=node}
