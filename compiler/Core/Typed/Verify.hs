-- Check existing annotations and lexical identity. This never solves an
-- untyped body or guesses a representation from an optimized expression.
module Core.Typed.Verify (verifyFunction, instanceOf, sameType, fieldType) where
import Core.Typed.Syntax
import Ownership.TypeShape (linShapeT)
import Type.Syntax (Type(..), Row(..), Scheme(..))
import Control.Monad (unless, foldM)
import Type.Relation
import qualified Data.Map.Strict as M
import qualified Data.Set as S

verifyFunction :: TypeContext -> Function -> Either String ()
verifyFunction (TypeContext linearTypes constructors) f = do
  (env,used) <- introduce M.empty S.empty (functionParameters f)
  _ <- check env used (functionBody f)
  pure ()
  where
    bad reason = Left ("typed Core " ++ functionName f ++ ": " ++ reason)
    require reason ok = unless ok (bad reason)
    introduce env used bs = foldM step (env,used) bs
      where
        step (scope,seen) b = do
          require "binder ownership shape" (binderShape b == linShapeT linearTypes (binderType b))
          require "duplicate binder identity" (S.notMember (binderId b) seen)
          pure (M.insert (binderId b) b scope,S.insert (binderId b) seen)
    check env used e = do
      require "expression ownership shape" (exprShape e == linShapeT linearTypes (exprType e))
      node env used e
    node env used e = case exprNode e of
      Var (Local uid) -> do
        b <- maybe (bad "out-of-scope local identity") Right (M.lookup uid env)
        require "local reference type disagrees with its scheme" (instanceOf (binderScheme b) (exprType e))
        pure used
      Var (Global _ sc) -> do
        require "global reference type disagrees with its scheme" (instanceOf sc (exprType e))
        pure used
      IntValue _ -> fixed (TC "Int")
      StringValue _ -> fixed (TC "String")
      BoolValue _ -> fixed (TC "Bool")
      Apply fn arg -> do
        u <- check env used fn >>= \u -> check env u arg
        case exprType fn of
          TFn a r -> do
            require "application argument type" (sameType a (exprType arg))
            require "application result type" (sameType r (exprType e))
          _ -> bad "application head is not a function"
        pure u
      Lambda ps body -> do
        (scope,u) <- introduce env used ps
        u' <- check scope u body
        require "lambda type" (sameType (exprType e) (foldr (TFn . binderType) (exprType body) ps))
        pure u'
      Let b rhs body -> do
        u <- check env used rhs
        require "let right-hand side type" (instanceOf (binderScheme b) (exprType rhs))
        (scope,u') <- introduce env u [b]
        u'' <- check scope u' body
        require "let result type" (sameType (exprType e) (exprType body))
        pure u''
      If cond yes no -> do
        u <- check env used cond >>= \u -> check env u yes >>= \u -> check env u no
        require "condition is not Bool" (sameType (exprType cond) (TC "Bool"))
        require "conditional arm type" (all (sameType (exprType e) . exprType) [yes,no])
        pure u
      BoolTest _ arg -> do
        u <- check env used arg
        require "Bool test type" (sameType (exprType arg) (TC "Bool") && sameType (exprType e) (TC "Bool"))
        pure u
      Construct name xs -> do
        u<-foldM (check env) used xs
        sc<-maybe (bad ("unknown constructor "++name)) Right (M.lookup name constructors)
        let arity (TFn _ t)=1+arity t; arity _=0
            Forall _ _ declared=sc
        require "constructor value arity" (length xs==arity declared)
        require "constructor value signature" (instanceOf sc (foldr (TFn . exprType) (exprType e) xs))
        pure u
      AtomValue _ -> fixed (TC "Atom")
      TupleValue xs -> do
        u<-foldM (check env) used xs
        require "tuple type" (sameType (exprType e) (TTupT (map exprType xs)))
        pure u
      ListValue xs -> do
        u<-foldM (check env) used xs
        case exprType e of
          TAp (TC "List") t -> require "list element type" (all (sameType t . exprType) xs)
          _ -> bad "list result type"
        pure u
      RecordValue fs -> do
        u<-foldM (check env) used (map snd fs)
        let row=foldr (\(n,x) rest -> RExt n (exprType x) rest) RNil fs
        require "record type" (sameType (exprType e) (TRec row))
        pure u
      RecordField base path -> do
        u<-check env used base
        require "record projection type" (maybe False (sameType (exprType e)) (fieldType (exprType base) path))
        pure u
      RecordUpdate base fields -> do
        u<-check env used base
        require "record update result type" (sameType (exprType base) (exprType e))
        foldM (\seen (path,x) -> do
          require "record update field type" (not (null path) && maybe False (sameType (exprType x)) (fieldType (exprType base) path))
          check env seen x) u fields
      ResultPipe a fn -> do
        u<-check env used a >>= \u -> check env u fn
        case (exprType a,exprType fn,exprType e) of
          (TAp (TAp (TC "Result") x) err,TFn arg (TAp (TAp (TC "Result") y) err'),TAp (TAp (TC "Result") out) err'') ->
            require "result pipe type" (sameType x arg && sameType y out && sameType err err' && sameType err err'')
          _->bad "result pipe shape"
        pure u
      Sequence a b -> do
        u<-check env used a >>= \u -> check env u b
        require "sequence result type" (sameType (exprType b) (exprType e))
        pure u
      LetPattern p rhs body -> do
        u<-check env used rhs
        require "pattern binding input type" (sameType (patType p) (exprType rhs))
        (scope,u')<-patternScope env u p
        u''<-check scope u' body
        require "pattern binding result type" (sameType (exprType body) (exprType e))
        pure u''
      Match _ args alts -> do
        require "empty match" (not (null alts))
        u<-foldM (check env) used args
        foldM (alternative env (map exprType args) (exprType e)) u alts
      Note body -> do
        u <- check env used body
        require "note changes type" (sameType (exprType body) (exprType e))
        pure u
      where
        fixed ty = require "literal type" (sameType ty (exprType e)) >> pure used

    patternScope env used p = do
      case patNode p of
        Wildcard -> pure ()
        Bind b -> do
          require "pattern binder type" (sameType (binderType b) (patType p))
          require "pattern binder must be monomorphic" (case binderScheme b of Forall [] [] _->True; _->False)
        IntegerPattern _ -> require "integer pattern type" (sameType (patType p) (TC "Int"))
        StringPattern _ -> require "string pattern type" (sameType (patType p) (TC "String"))
        ConstructorPattern name ps -> do
          sc<-maybe (bad ("unknown pattern constructor "++name)) Right (M.lookup name constructors)
          let arity (TFn _ t)=1+arity t; arity _=0
              Forall _ _ declared=sc
          require "constructor pattern arity" (length ps==arity declared)
          require "constructor pattern signature" (instanceOf sc (foldr (TFn . patType) (patType p) ps))
          mapM_ (\q -> patternScope M.empty S.empty q >> pure ()) ps
        TuplePattern ps -> do
          require "tuple pattern type" (sameType (patType p) (TTupT (map patType ps)))
          mapM_ (\q -> patternScope M.empty S.empty q >> pure ()) ps
        RecordPattern fs -> mapM_ (\(name,b) -> require "record pattern field type"
          (maybe False (sameType (binderType b)) (fieldType (patType p) [name]))) fs
      introduce env used (patternBinders p)
    alternative env inputs result used (Alternative ps gs body) = do
      require "match pattern arity/type" (length ps==length inputs && and (zipWith (\p t -> sameType (patType p) t) ps inputs))
      (scope,u)<-foldM (\(s,seen) p -> patternScope s seen p) (env,used) ps
      (scope',u')<-foldM guardScope (scope,u) gs
      u''<-check scope' u' body
      require "match alternative result type" (sameType result (exprType body))
      pure u''
    guardScope (env,used) g = case g of
      BoolGuard e -> do
        u<-check env used e
        require "guard is not Bool" (sameType (exprType e) (TC "Bool"))
        pure (env,u)
      PatternGuard p e -> do
        u<-check env used e
        require "pattern guard input type" (sameType (patType p) (exprType e))
        patternScope env u p
