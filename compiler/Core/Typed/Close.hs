{-# LANGUAGE FlexibleContexts #-}
-- Typed closure/join conversion. Captures are lexical identities with their
-- checked schemes; generated code never re-infers an erased expression.
module Core.Typed.Close
  (ClosedFunction,closeFunction,closeFunctionWith,closedRoot,closedCode,closedGlobals,closedContracts,
   closedOwnedContracts,closedImports,CodeLibrary,codeLibrary,libraryContracts,importClosedLibrary,importClosedCode,mergeClosedLibrary,CloneOrigin(..),closedOrigins,
   mapClosed,mapClosedChanged,rewriteClosed,rewriteClosedWithOrigins,verifyClosed) where
import Core.Typed.Syntax
import Core.Typed.Verify
import Core.Typed.Walk
import Core.Typed.Contract (codeContractsWith)
import Core.Identity
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import Control.Monad.State.Strict
import Control.Monad.Except
import Control.Monad (unless,when)
import Data.List (intercalate)
import Data.Functor.Identity (runIdentity)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data CloneOrigin=CloneOrigin
  { cloneSource :: String,cloneTemplate :: CodeId,
    cloneBindings :: [(BinderId,Maybe BinderId)] } deriving Show
data ClosedFunction=ClosedFunction Function (M.Map CodeId CodeFunction) (M.Map String Scheme) (M.Map CodeId CodeContract) (M.Map CodeId CloneOrigin)
closedRoot :: ClosedFunction -> Function
closedRoot (ClosedFunction f _ _ _ _)=f
closedCode :: ClosedFunction -> M.Map CodeId CodeFunction
closedCode (ClosedFunction _ codes _ _ _)=codes
closedGlobals :: ClosedFunction -> M.Map String Scheme
closedGlobals (ClosedFunction _ _ globals _ _)=globals
closedImports :: ClosedFunction -> M.Map CodeId CodeContract
closedImports (ClosedFunction _ _ _ imports _)=imports
closedOrigins :: ClosedFunction -> M.Map CodeId CloneOrigin
closedOrigins (ClosedFunction _ _ _ _ origins)=origins
closedOwnedContracts :: ClosedFunction -> M.Map CodeId CodeContract
closedOwnedContracts (ClosedFunction _ codes globals imports _)=codeContractsWith imports globals codes
closedContracts :: ClosedFunction -> M.Map CodeId CodeContract
closedContracts p=closedOwnedContracts p `M.union` closedImports p

-- Derive a declaration library once from verified owners. Attaching this
-- snapshot to another caller does not recheck/re-generalize every provider.
newtype CodeLibrary=CodeLibrary (M.Map CodeId CodeContract)
libraryContracts :: CodeLibrary -> M.Map CodeId CodeContract
libraryContracts (CodeLibrary contracts)=contracts
codeLibrary :: [ClosedFunction] -> Either String CodeLibrary
codeLibrary providers=do
  -- ClosedFunction is opaque; every producer verifies its changed graph.
  -- A library adds declaration ownership, not a new body transformation.
  let entries=concatMap (M.toList . closedOwnedContracts) providers
      contracts=M.fromList entries
  unless (length entries==M.size contracts) (Left "typed closure: duplicate code library identity")
  pure (CodeLibrary contracts)

-- Import declarations only from verified owners. Bodies remain at home;
-- cloning a source body must never copy the PAP of its nested lambda.
importClosedCode :: TypeContext -> [ClosedFunction] -> ClosedFunction -> Either String ClosedFunction
importClosedCode types providers input=codeLibrary providers >>= \library->importClosedLibrary types library input

importClosedLibrary :: TypeContext -> CodeLibrary -> ClosedFunction -> Either String ClosedFunction
importClosedLibrary types library input=do
  let result=mergeClosedLibrary library input
  verifyClosed types result
  pure result

-- The merge itself, for callers that verify their own product downstream.
-- Existing imports win over library duplicates, and entries colliding with
-- owned code are dropped, so the merge is consistent by construction.
mergeClosedLibrary :: CodeLibrary -> ClosedFunction -> ClosedFunction
mergeClosedLibrary (CodeLibrary available) (ClosedFunction root codes globals imports origins)=
  ClosedFunction root codes globals (M.withoutKeys (imports `M.union` available) (M.keysSet codes)) origins
-- Transform an owned closed product and check the complete code graph before
-- exposing it to another pass. Clients cannot construct an unchecked product.
mapClosed :: TypeContext -> (Function -> Either String Function) -> (CodeFunction -> Either String CodeFunction) -> ClosedFunction -> Either String ClosedFunction
mapClosed types rootPass codePass (ClosedFunction root codes globals imports origins)=do
  root'<-rootPass root
  codes'<-traverse codePass codes
  let result=ClosedFunction root' codes' globals imports origins
  verifyClosed types result
  pure result
-- A reporting pass returns its output paired with whether it rewrote
-- anything. Untouched products pass through with their existing verification
-- instead of being rebuilt and re-checked; changed ones verify atomically.
mapClosedChanged :: TypeContext -> (Function -> Either String (Function,Bool)) -> (CodeFunction -> Either String (CodeFunction,Bool)) -> ClosedFunction -> Either String (ClosedFunction,Bool)
mapClosedChanged types rootPass codePass input@(ClosedFunction root codes globals imports origins)=do
  (root',rootChanged)<-rootPass root
  coded<-traverse codePass codes
  if not (rootChanged || any snd coded) then pure (input,False)
  else do
    let result=ClosedFunction root' (M.map fst coded) globals imports origins
    verifyClosed types result
    pure (result,True)
-- Code-generating passes publish the whole changed graph atomically. Existing
-- code/capture identities remain checked alongside newly introduced entries.
rewriteClosed :: TypeContext -> (Function -> M.Map CodeId CodeFunction -> Either String (Function,M.Map CodeId CodeFunction)) -> ClosedFunction -> Either String ClosedFunction
rewriteClosed types pass input=rewriteClosedWithOrigins types (\root codes origins->do
  (root',codes')<-pass root codes
  pure (root',codes',origins)) input

rewriteClosedWithOrigins :: TypeContext -> (Function -> M.Map CodeId CodeFunction -> M.Map CodeId CloneOrigin
  -> Either String (Function,M.Map CodeId CodeFunction,M.Map CodeId CloneOrigin)) -> ClosedFunction -> Either String ClosedFunction
rewriteClosedWithOrigins types pass (ClosedFunction root codes globals imports origins)=do
  (root',codes',origins')<-pass root codes origins
  let references e=(case exprNode e of ClosureValue k _->S.singleton k;CodeCall k _ _->S.singleton k;JoinCall k _ _->S.singleton k;_->S.empty)
        <>getConst (mapChildrenM (Const . references) e)
      wanted=S.unions (map (references . functionBody) (root':map codeAsFunction (M.elems codes')))
      result=ClosedFunction root' codes' globals (M.restrictKeys imports wanted) origins'
  verifyClosed types result
  pure result
data Closing=Closing Int (M.Map CodeId CodeFunction)

closeFunction :: Monad m => Namespace -> (String -> m String) -> TypeContext -> Function -> m (Either String ClosedFunction)
closeFunction=closeFunctionWith M.empty

closeFunctionWith :: Monad m => M.Map String Scheme -> Namespace -> (String -> m String) -> TypeContext -> Function -> m (Either String ClosedFunction)
closeFunctionWith globals (Namespace sourceNamespace) names types@(TypeContext linears _) input = runExceptT $ do
  either throwError pure (verifyFunction types input)
  (root,Closing _ codes)<-runStateT run (Closing 0 M.empty)
  let result=ClosedFunction root codes globals M.empty M.empty
  either throwError pure (verifyClosed types result)
  pure result
  where
    namespace=Namespace (sourceNamespace++"/closed/"++functionName input)
    name prefix=lift (lift (names prefix))
    index=do
      Closing next codes<-get
      put (Closing (next+1) codes)
      pure next
    identity=BinderId namespace <$> index
    -- Local names belong to this closure group, not the unit's global label
    -- supply. Unrelated constructor stubs must not shift cached code labels.
    localName prefix=do n<-index; pure (prefix++"_"++show n)
    alpha binder=do
      spelling<-localName "$typed_v"
      pure binder {binderName=spelling}
    introduced binder=do
      uid<-identity
      spelling<-localName "$typed_capture"
      pure binder {binderId=uid,binderName=spelling}
    generated ty node=Expr ty (linShapeT linears ty) Generated Nothing node
    ref binder=generated (binderType binder) (Var (Local (binderId binder)))
    extend binders env=M.union (M.fromList [(binderId b,b) | b<-binders]) env
    newBinder ty=do
      uid<-identity
      spelling<-localName "$typed_temp"
      pure (Binder uid spelling (Forall [] [] ty) (linShapeT linears ty))
    run=do
      ps<-mapM alpha (functionParameters input)
      body<-go (extend ps M.empty) (functionBody input)
      pure input {functionParameters=ps,functionBody=body}
    install code=do
      Closing n existing<-get
      when (M.member (codeId code) existing) (throwError "typed closure: duplicate generated code identity")
      put (Closing n (M.insert (codeId code) code existing))
    liftCode env kind params body=do
      let wanted=filter (`S.notMember` S.fromList (map binderId params)) (localUses body)
      captures<-mapM (\uid -> maybe (throwError "typed closure: absent capture identity") pure (M.lookup uid env)) wanted
      freshCaptures<-mapM introduced captures
      label<-CodeId <$> name (if kind==ClosureCode then "$typed_lifted" else "$typed_join")
      let renamed=renameUses (M.fromList (zip wanted (map binderId freshCaptures))) body
          code=CodeFunction label kind freshCaptures params renamed
      install code
      pure (label,wanted)
    -- Self references denote the same code and lexical environment, rather
    -- than capturing the not-yet-initialized local function value. Substitute
    -- before closing nested lambdas so their capture sets include that env.
    selfValue uid label captures e=case exprNode e of
      Var (Local used) | used==uid->e {exprNode=ClosureValue label captures}
      _->runIdentity (mapChildrenM (pure . selfValue uid label captures) e)
    recursive env binder rhs continuation=do
      (ps,body)<-maybe (throwError "typed closure: recursive initializer is not a function") pure (lambdaView rhs)
      let wanted=filter (/=binderId binder) (localUses rhs)
      captures<-mapM (\uid->maybe (throwError "typed closure: absent recursive capture") pure (M.lookup uid env)) wanted
      freshCaptures<-mapM introduced captures
      ps'<-mapM alpha ps
      label<-CodeId <$> name "$typed_recursive"
      let captureIds=map binderId freshCaptures
          renamed=renameUses (M.fromList (zip wanted captureIds)) body
          selfBody=selfValue (binderId binder) label captureIds renamed
      body'<-go (extend (freshCaptures++ps') M.empty) selfBody
      install (CodeFunction label ClosureCode freshCaptures ps' body')
      binder'<-alpha binder
      continuation'<-go (extend [binder'] env) continuation
      let value e=case exprNode e of
            Note x->e {exprNode=Note (value x)}
            _->e {exprNode=ClosureValue label wanted}
      pure (Let binder' (value rhs) continuation')
    go env e=case exprNode e of
      RecordUpdate _ _->throwError "typed closure: record update requires layout planning"
      Lambda ps body->do
        ps'<-mapM alpha ps
        body'<-go (extend ps' env) body
        (label,captures)<-liftCode env ClosureCode ps' body'
        pure e {exprNode=ClosureValue label captures}
      Let binder rhs body->do
        rhs'<-go env rhs
        binder'<-alpha binder
        body'<-go (extend [binder'] env) body
        pure e {exprNode=Let binder' rhs' body'}
      LetRec binder rhs body->do
        node<-recursive env binder rhs body
        pure e {exprNode=node}
      LetPattern pat rhs body->do
        rhs'<-go env rhs
        pat'<-pattern' pat
        body'<-go (extend (patternBinders pat') env) body
        pure e {exprNode=LetPattern pat' rhs' body'}
      Match style args alts->do
        args'<-mapM (go env) args
        alts'<-mapM (alternative env) alts
        let failure=generated (exprType e) (Fail (case style of
              FunctionMatch owner->"no matching clause for "++owner
              CaseMatch->"case: no matching pattern; arms were ["++intercalate "," [patDisplay p | Alternative [p] _ _<-alts]++"]"))
        case style of
          CaseMatch->case args' of
            [arg]->do
              scrut<-newBinder (exprType arg)
              body<-match (extend [scrut] env) style [ref scrut] alts' failure
              pure e {exprNode=Let scrut arg body}
            _->throwError "typed closure: case arity"
          _->match env style args' alts' failure
      _->mapChildrenM (go env) e
    pattern' p=do
      node<-case patNode p of
        Bind b->Bind <$> alpha b
        ConstructorPattern n ps->ConstructorPattern n <$> mapM pattern' ps
        TuplePattern ps->TuplePattern <$> mapM pattern' ps
        RecordPattern fs->RecordPattern <$> mapM (\(n,b)->(,) n <$> alpha b) fs
        n->pure n
      pure p {patNode=node}
    alternative env (Alternative ps gs body)=do
      ps'<-mapM pattern' ps
      let scope=extend (concatMap patternBinders ps') env
          guards s []=do b<-go s body; pure ([],b)
          guards s (BoolGuard x:rest)=do
            x'<-go s x; (rest',b)<-guards s rest; pure (BoolGuard x':rest',b)
          guards s (PatternGuard p x:rest)=do
            x'<-go s x; p'<-pattern' p
            (rest',b)<-guards (extend (patternBinders p') s) rest
            pure (PatternGuard p' x':rest',b)
      (gs',body')<-guards scope gs
      pure (Alternative ps' gs' body')
    -- Split a match only where the ordinary layout pass would share a
    -- nontrivial fallthrough. Earlier simple arms stay inline in this step.
    match env style args alts failure=case break needsJoin (zip alts (drop 1 (tails alts))) of
      (prefix,[]) -> pure (generated (exprType failure) (MatchTail style args (map fst prefix) failure))
      (prefix,(current,rest):_) -> do
        fallback<-match env style args rest failure
        -- Captures already make a nonnullary call. Only a capture-free join
        -- needs a dummy arg: do not turn a 64-capture join into arity 65.
        (params,args')<-if null (localUses fallback) then do
          unit<-newBinder (TC "Int")
          pure ([unit],[generated (TC "Int") (IntValue 0)])
          else pure ([],[])
        (label,captures)<-liftCode env JoinCode params fallback
        let target=generated (exprType failure) (JoinCall label captures args')
        pure (generated (exprType failure) (MatchTail style args (map fst prefix++[current]) target))
      where
        needsJoin (Alternative ps gs _,rest)=not (null rest) && sum (map tests ps)+length gs>1
        tests p=case patNode p of
          IntegerPattern _->1; StringPattern _->1
          ConstructorPattern _ ps->1+sum (map tests ps)
          TuplePattern ps->1+sum (map tests ps)
          _->0
        tails []=[[]]
        tails xs@(_:rest)=xs:tails rest

verifyClosed :: TypeContext -> ClosedFunction -> Either String ()
verifyClosed types product@(ClosedFunction root codes _ imports origins)=do
  let contracts=closedContracts product
      functions=root:map codeAsFunction (M.elems codes)
      binders=concat [functionParameters f++allBinders (functionBody f) | f<-functions]
      identities=map binderId binders
      ordinary=functionParameters root++concatMap codeParameters (M.elems codes)
      monomorphic b=case binderScheme b of Forall [] [] _->True;_->False
  unless (all monomorphic ordinary) (Left "typed closure: ordinary parameter requires a monomorphic scheme")
  unless (all (\code->codeKind code/=ClosureCode || not (null (codeParameters code))) (M.elems codes))
    (Left "typed closure: a callable code entry requires an ordinary parameter")
  unless (length identities==S.size (S.fromList identities)) (Left "typed closure: binder identity reused between functions")
  unless (M.notMember (CodeId (functionName root)) codes) (Left "typed closure: root and code entry share a label")
  unless (S.null (M.keysSet codes `S.intersection` M.keysSet imports)) (Left "typed closure: code is both owned and imported")
  mapM_ (\(label,origin)->case M.lookup label codes of
    Nothing->Left "typed closure: clone origin has no owned code"
    Just code->do
      let ps=S.fromList (map binderId (codeCaptures code++codeParameters code))
          targets=[uid | (_,Just uid)<-cloneBindings origin]
          sources=map fst (cloneBindings origin)
      unless (length sources==S.size (S.fromList sources) && length targets==S.size (S.fromList targets)
        && S.fromList targets `S.isSubsetOf` ps) (Left "typed closure: clone parameter provenance disagrees")) (M.toList origins)
  mapM_ (\(label,code)->unless (label==codeId code) (Left "typed closure: code identity/key mismatch")) (M.toList codes)
  mapM_ (verifyFunctionWith contracts types) functions
  mapM_ (closed . functionBody) functions
  where
    closed e=case exprNode e of
      Lambda _ _->Left "typed closure: lambda remains after conversion"
      Match _ _ _->Left "typed closure: implicit match fallthrough remains"
      RecordUpdate _ _->Left "typed closure: unplanned record update remains"
      LetRec _ _ _->Left "typed closure: recursive binding remains after conversion"
      _->mapChildrenM (\child->closed child >> pure child) e >> pure ()
