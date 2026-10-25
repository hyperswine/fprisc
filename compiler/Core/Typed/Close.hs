{-# LANGUAGE FlexibleContexts #-}
-- Typed closure/join conversion. Captures are lexical identities with their
-- checked schemes; generated code never re-infers an erased expression.
module Core.Typed.Close
  (ClosedFunction,closeFunction,closedRoot,closedCode,verifyClosed) where
import Core.Typed.Syntax
import Core.Typed.Verify
import Core.Typed.Walk
import Core.Identity
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import Control.Monad.State.Strict
import Control.Monad.Except
import Control.Monad (unless,when)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data ClosedFunction=ClosedFunction Function (M.Map CodeId CodeFunction)
closedRoot :: ClosedFunction -> Function
closedRoot (ClosedFunction f _)=f
closedCode :: ClosedFunction -> M.Map CodeId CodeFunction
closedCode (ClosedFunction _ codes)=codes
data Closing=Closing Int (M.Map CodeId CodeFunction)

closeFunction :: Monad m => Namespace -> (String -> m String) -> TypeContext -> Function -> m (Either String ClosedFunction)
closeFunction (Namespace sourceNamespace) names types@(TypeContext linears _) input = runExceptT $ do
  either throwError pure (verifyFunction types input)
  (root,Closing _ codes)<-runStateT run (Closing 0 M.empty)
  let result=ClosedFunction root codes
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
    liftCode env kind params body=do
      let wanted=filter (`S.notMember` S.fromList (map binderId params)) (localUses body)
      captures<-mapM (\uid -> maybe (throwError "typed closure: absent capture identity") pure (M.lookup uid env)) wanted
      freshCaptures<-mapM introduced captures
      label<-CodeId <$> name (if kind==ClosureCode then "$typed_lifted" else "$typed_join")
      let renamed=renameUses (M.fromList (zip wanted (map binderId freshCaptures))) body
          code=CodeFunction label kind freshCaptures params renamed
      Closing _ existing<-get
      when (M.member label existing) (throwError "typed closure: duplicate generated code identity")
      modify (\(Closing n codes)->Closing n (M.insert label code codes))
      pure (label,wanted)
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
verifyClosed types (ClosedFunction root codes)=do
  let contracts=M.map codeContract codes
      functions=root:map codeAsFunction (M.elems codes)
      binders=concat [functionParameters f++allBinders (functionBody f) | f<-functions]
      identities=map binderId binders
  unless (length identities==S.size (S.fromList identities)) (Left "typed closure: binder identity reused between functions")
  mapM_ (\(label,code)->unless (label==codeId code) (Left "typed closure: code identity/key mismatch")) (M.toList codes)
  mapM_ (verifyFunctionWith contracts types) functions
  mapM_ (closed . functionBody) functions
  where
    closed e=case exprNode e of
      Lambda _ _->Left "typed closure: lambda remains after conversion"
      Match _ _ _->Left "typed closure: implicit match fallthrough remains"
      RecordUpdate _ _->Left "typed closure: unplanned record update remains"
      _->mapChildrenM (\child->closed child >> pure child) e >> pure ()
