-- Check existing annotations and lexical identity. This never solves an
-- untyped body or guesses a representation from an optimized expression.
module Core.Typed.Verify (verifyFunction, verifyFunctionWith, instanceOf, sameType, fieldType) where
import Core.Typed.Syntax
import Core.Typed.Contract (checkInstance)
import Ownership.TypeShape (linShapeT)
import Type.Syntax (Type(..), Row(..), Scheme(..))
import Control.Monad (unless, foldM)
import Type.Relation
import Data.List (nub,sort)
import Compiler.VectorLayout (VectorBuilder(..),validLayout)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

verifyFunction :: TypeContext -> Function -> Either String ()
verifyFunction = verifyFunctionWith M.empty

verifyFunctionWith :: M.Map CodeId CodeContract -> TypeContext -> Function -> Either String ()
verifyFunctionWith contracts (TypeContext linearTypes constructors) f = do
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
      Var (Global name sc) -> do
        require "code identity requires an explicit closure/join reference" (M.notMember (CodeId name) contracts)
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
      LetRec b rhs body -> do
        require "recursive initializer must be a function" (case lambdaView rhs of Just _->True; _->False)
        (scope,u)<-introduce env used [b]
        require "recursive binding initializer type" (instanceOf (binderScheme b) (exprType rhs))
        u'<-check scope u rhs
        u''<-check scope u' body
        require "recursive binding result type" (sameType (exprType e) (exprType body))
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
      PlannedUpdate base plan -> do
        u<-check env used base
        require "planned record update result type" (sameType (exprType base) (exprType e))
        updatePlan env u (exprType base) plan
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
      ClosureValue label captures -> do
        codeInstance env label captures ClosureCode (exprType e)
        pure used
      CodeCall label captures args -> do
        contract<-maybe (bad "unknown code identity") Right (M.lookup label contracts)
        require "a join requires an explicit continuation call" (contractKind contract/=JoinCode)
        require "nullary code is not a callable closure" (contractKind contract==EntryCode || not (null args))
        saturated env label captures (contractKind contract) args (exprType e)
        foldM (check env) used args
      JoinCall label captures args -> do
        require "nullary join is not a callable continuation" (not (null captures && null args))
        saturated env label captures JoinCode args (exprType e)
        foldM (check env) used args
      MatchTail style args alts fallback -> do
        require "empty match tail" (not (null alts))
        require "match tail arguments must be evaluated variables" (all (\x -> case exprNode x of Var (Local _)->True; _->False) args)
        require "case match tail arity" (style/=CaseMatch || length args==1)
        u<-foldM (check env) used args
        u'<-foldM (alternative env (map exprType args) (exprType e)) u alts
        require "match fallback type" (sameType (exprType e) (exprType fallback))
        check env u' fallback
      Fail _ -> pure used
      LayoutLiteral spec -> do
        case exprType e of
          TLayout element->require "layout evidence descriptor/type" (validLayout element spec)
          _->bad "layout evidence requires its element type"
        pure used
      VectorBuild builder evidence -> do
        u<-check env used evidence
        element<-case exprType evidence of TLayout t->pure t; _->bad "vector builder requires layout evidence"
        let vector t=TAp (TC "Vector") t
        case builder of
          BuildEmpty->require "vector allocation layout/result type" (sameType (exprType e) (vector element))
          BuildFromList->require "vector from-list layout/result type"
            (sameType (exprType e) (TFn (TAp (TC "List") element) (vector element)))
          BuildMap->case exprType e of
            TFn (TFn input output) (TFn v result)->require "vector map layout/result type"
              (sameType output element && sameType v (vector input) && sameType result (vector element))
            _->bad "vector map function type"
        pure u
      Note body -> do
        u <- check env used body
        require "note changes type" (sameType (exprType body) (exprType e))
        pure u
      where
        fixed ty = require "literal type" (sameType ty (exprType e)) >> pure used

    updatePlan env used input (UpdatePlan roots branches)=do
      require "planned update branches" (not (null branches))
      require "planned update roots" (not (null roots) && roots==nub roots)
      let ids=[tid | UpdateBranch tid _<-branches]
      require "planned update duplicate layout" (ids==nub ids)
      foldM branch used branches
      where
        branch seen (UpdateBranch _ fields)=do
          let names=map fst fields
          require "planned update layout fields" (names==sort names && names==nub names && all (`elem` names) roots)
          require "planned update replacement roots" ([n | (n,x)<-fields,case x of KeepField->False; _->True]==sort roots)
          foldM field seen fields
        field seen (_,KeepField)=pure seen
        field seen (name,value)=do
          ty<-maybe (bad "planned update field absent from input type") Right (fieldType input [name])
          case value of
            ReplaceField x->do
              require "planned update field type" (sameType ty (exprType x))
              check env seen x
            NestedUpdate p->updatePlan env seen ty p

    codeInstance env label captures kind actual = do
      contract<-maybe (bad "unknown code identity") Right (M.lookup label contracts)
      require "code kind" (contractKind contract==kind)
      require "capture arity" (length captures==length (contractCaptures contract))
      actualCaptures<-mapM (\uid -> do
        b<-maybe (bad "out-of-scope capture identity") Right (M.lookup uid env)
        pure (binderScheme b)) captures
      mapM_ (\(Forall _ _ ty,shape)->require "capture ownership shape" (shape==linShapeT linearTypes ty)) (contractCaptures contract)
      either bad pure (checkInstance contract actualCaptures actual)
    saturated env label captures kind args result=do
      contract<-maybe (bad "unknown code identity") Right (M.lookup label contracts)
      require "code argument arity" (length args==length (contractParameters contract))
      codeInstance env label captures kind (foldr (TFn . exprType) result args)

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
