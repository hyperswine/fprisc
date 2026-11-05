{-# LANGUAGE FlexibleContexts #-}
-- Check whether a separately compiled, polymorphic function can transport
-- different representations at a particular instance. Source type variables
-- alone are insufficient: print, foreign calls and other uniform primitives
-- can observe them. Follow only calls whose occurrence mentions the payload.
module Core.Typed.Parametric
  (Catalog(..), changedParameters, constructorTransport, transportClosure) where

import Core.Typed.Syntax
import Core.Typed.Walk (allBinders)
import Core.Typed.Verify (instanceOf)
import Type.Syntax
import Type.Substitution (variables)
import Control.Monad (unless, when)
import Control.Monad.State.Strict (StateT, execStateT, gets, modify', lift)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- Constructors here are generated value entries. A source binding with the
-- same spelling must be checked as a function, never accepted as a constructor.
data Catalog = Catalog
  { checkedBodies :: M.Map String Function
  , publishedSchemes :: M.Map String Scheme
  , generatedConstructors :: M.Map String Scheme
  }

type Ports = S.Set Int
type Request = (String, Ports)
type Proof = StateT (S.Set Request) (Either String)

-- Match occurrences simultaneously. Only quantified positions may differ.
-- Require a consistent substitution even if one occurrence repeats its
-- formal variable in several positions.
changedParameters :: Type -> Type -> Type -> Either String Ports
changedParameters formal original physical = do
  bindings <- execStateT (match formal original physical) M.empty
  pure (M.keysSet (M.filter (uncurry (/=)) bindings))
  where
    match (TV v) a b = do
      previous <- gets (M.lookup v)
      case previous of
        Nothing -> modify' (M.insert v (a,b))
        Just pair -> unless (pair==(a,b)) (lift (Left "inconsistent type instance"))
    match (TFn p q) (TFn a b) (TFn x y) = match p a x >> match q b y
    match (TAp p q) (TAp a b) (TAp x y) = match p a x >> match q b y
    match (TTupT ps) (TTupT as) (TTupT bs)
      | length ps==length as && length ps==length bs =
          sequence_ (zipWith3 match ps as bs)
    match p a b
      | p==a && a==b = pure ()
      | otherwise = lift (Left "representation change outside a type parameter")

constructorTransport :: Scheme -> Type -> Type -> Either String ()
constructorTransport (Forall vs _ declared) original physical=do
  changed<-changedParameters declared original physical
  let result (TFn _ t)=result t
      result t=t
  unless (changed `S.isSubsetOf` S.fromList vs && changed `S.isSubsetOf` fst (variables (result declared)))
         (Left "constructor hides a changed payload")

-- Mark a parameter with an unspellable rigid type. This is used only in
-- structural comparisons; the marker never enters the program or its ABI.
mark :: Ports -> Type -> Type
mark ports ty = case ty of
  TV i | i `S.member` ports -> TC ("$private.parameter."++show i)
  TFn a b -> TFn (go a) (go b)
  TAp a b -> TAp (go a) (go b)
  TTupT ts -> TTupT (map go ts)
  TLayout t -> TLayout (go t)
  TRec r -> TRec (row r)
  _ -> ty
  where
    go=mark ports
    row (RExt n t r)=RExt n (go t) (row r)
    row r=r

-- The work set is finite: each entry is a checked source definition and a
-- subset of its own formal variables, independent of recursive type growth.
-- A failed dependency invalidates the whole proof, including cycles.
transportClosure :: Catalog -> String -> Type -> Type -> Either String (S.Set Request)
transportClosure catalog name original physical = do
  f <- maybe (Left ("missing checked body for "++name)) Right (M.lookup name (checkedBodies catalog))
  checkPublication name original physical
  ports <- changedParameters (functionType f) original physical
  execStateT (visit name ports) S.empty
  where
    checkPublication n a b=case M.lookup n (publishedSchemes catalog) of
      Just sc | instanceOf sc a && instanceOf sc b -> Right ()
      _ -> Left ("published scheme cannot transport this parameter at "++n)
    visit :: String -> Ports -> Proof ()
    visit n ports = do
      seen <- gets (S.member (n,ports))
      unless (seen || S.null ports) $ do
        f <- maybe (lift (Left ("missing checked body for "++n))) pure (M.lookup n (checkedBodies catalog))
        modify' (S.insert (n,ports))
        inspect n ports f

    inspect owner ports fn = walk (functionBody fn)
      where
        locals=M.fromList [(binderId b,binderScheme b) | b<-functionParameters fn++allBinders (functionBody fn)]
        sensitive ty = not (S.disjoint ports (fst (variables ty)))
        refuse why = lift (Left (owner++": "++why))
        require ok why = unless ok (refuse why)
        instancePorts formal ty = either refuse pure (changedParameters formal ty (mark ports ty))
        constructor n ty = case M.lookup n (generatedConstructors catalog) of
          Just sc -> either (refuse . ((n++": ")++)) pure (constructorTransport sc ty (mark ports ty))
          Nothing -> refuse ("unknown constructor "++n)
        reference n ty = when (sensitive ty) $ case M.lookup n (checkedBodies catalog) of
          Just fn -> do
            lift (checkPublication n ty (mark ports ty))
            instancePorts (functionType fn) ty >>= visit n
          Nothing | M.member n (generatedConstructors catalog) -> constructor n ty
                  | otherwise -> refuse ("observable or unknown entry "++n)
        application e as = case exprNode e of
          Apply f a -> application f (a:as)
          Note f -> application f as
          _ -> (e,as)
        arity (TFn _ t)=1+arity t
        arity _=0 :: Int
        checkPattern p = case patNode p of
          Wildcard -> pure ()
          Bind _ -> pure ()
          ConstructorPattern n ps -> do
            let ty=foldr (TFn . patType) (patType p) ps
            when (sensitive ty) (constructor n ty)
            mapM_ checkPattern ps
          TuplePattern ps -> mapM_ checkPattern ps
          _ -> require (not (sensitive (patType p))) "observed abstract pattern"
        alt (Alternative ps guards body)=mapM_ checkPattern ps >> mapM_ guardBody guards >> walk body
        guardBody (BoolGuard e)=walk e
        guardBody (PatternGuard p e)=checkPattern p >> walk e
        walk e = case exprNode e of
          Var (Global n _) -> reference n (exprType e)
          Var (Local uid) -> when (sensitive (exprType e)) $ case M.lookup uid locals of
            Just (Forall [] [] ty) | ty==exprType e -> pure ()
            _ -> refuse "unproved polymorphic local occurrence"
          Apply _ _ -> do
            let (f,args)=application e []
            -- A partial application can hide a changed value in a closure
            -- whose public type no longer mentions the payload.
            when (any (sensitive . exprType) args && length args < arity (exprType f))
                 (refuse "partial application captures a transported value")
            walk f >> mapM_ walk args
          Construct n xs -> do
            let ty=foldr (TFn . exprType) (exprType e) xs
            when (sensitive ty) (constructor n ty)
            mapM_ walk xs
          TupleValue xs -> mapM_ walk xs
          ListValue xs -> mapM_ walk xs
          If c a b -> walk c >> walk a >> walk b
          Match _ xs as -> mapM_ walk xs >> mapM_ alt as
          LetPattern p a b -> checkPattern p >> walk a >> walk b
          Let binder a b -> do
            let Forall ts rs _=binderScheme binder
            require (null ts && null rs) "polymorphic local binding"
            walk a >> walk b
          Sequence a b -> walk a >> walk b
          Note x -> walk x
          BoolTest _ x -> walk x
          Fail _ -> pure ()
          IntValue _ -> pure ()
          StringValue _ -> pure ()
          BoolValue _ -> pure ()
          AtomValue _ -> pure ()
          _ -> refuse "unproved local representation operation"
