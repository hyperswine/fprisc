{-# LANGUAGE LambdaCase, FlexibleContexts #-}
-- Explicit compatibility boundary. Layout operations lower directly from
-- typed nodes/patterns; they never reconstruct or re-infer a surface AST.
module Core.Typed.Erase (Layout(..), eraseFunction, eraseFunctionWith) where
import Core.Typed.Syntax
import Core.Typed.Verify (verifyFunctionWith)
import Core.Syntax (Core(..))
import Control.Monad (unless, foldM, forM)
import Control.Monad.Except
import Control.Monad.State.Strict (lift)
import Data.List (sort,sortOn,nub,intercalate)
import qualified Data.Map.Strict as M
import Compiler.VectorLayout (builderRuntimeName)

-- Runtime layout authority and fresh/control-flow effects are supplied by the
-- owning desugaring stage. Core typing is independent of content-addressed IDs.
data Layout m = Layout
  { freshName :: String -> m String,
    constructorLayout :: String -> Maybe (Int,Int,Int),
    recordLayouts :: M.Map [String] Int,
    registerJoin :: String -> [String] -> Core -> m () }

eraseFunction :: Monad m => TypeContext -> Layout m -> Function -> m (Either String ([String],Core))
eraseFunction = eraseFunctionWith M.empty

eraseFunctionWith :: Monad m => M.Map CodeId CodeContract -> TypeContext -> Layout m -> Function -> m (Either String ([String],Core))
eraseFunctionWith contracts types layout f = runExceptT $ do
  either throwError pure (verifyFunctionWith contracts types f)
  let ps=functionParameters f
  body<-go (M.fromList [(binderId b,binderName b) | b<-ps])
           (M.fromList [(binderName b,binderId b) | b<-ps]) (functionBody f)
  pure (map binderName ps,body)
  where
    fresh p=lift (freshName layout p)
    con n=maybe (throwError ("typed Core layout: unknown constructor "++n)) pure (constructorLayout layout n)
    shape fs=maybe (throwError ("typed Core layout: unknown record "++show fs)) pure (M.lookup (sort fs) (recordLayouts layout))
    scope b env names=(M.insert (binderId b) (binderName b) env,M.insert (binderName b) (binderId b) names)
    scopes bs env names=foldl (\(e,n) p -> scope p e n) (env,names) bs
    patScopes ps env names=scopes (concatMap patternBinders ps) env names
    allScopes ps gs env names=foldl (\(e,n) g -> case g of
      PatternGuard p _ -> patScopes [p] e n; _ -> (e,n)) (patScopes ps env names) gs
    go env names e=case exprNode e of
      Var (Local uid) -> do
        n<-maybe (throwError "typed Core erasure: absent local") pure (M.lookup uid env)
        unless (M.lookup n names==Just uid) (throwError "typed Core erasure: display spelling would capture a local identity")
        pure (CVar n)
      Var (Global n _) -> do
        unless (M.notMember n names) (throwError "typed Core erasure: display spelling would capture a global")
        pure (CVar n)
      ClosureValue (CodeId label) captures -> foldl CApp (CVar label) <$> mapM (capture env names) captures
      CodeCall (CodeId label) captures args -> do
        caps<-mapM (capture env names) captures
        xs<-mapM (go env names) args
        pure (foldl CApp (CVar label) (caps++xs))
      JoinCall (CodeId label) captures args -> do
        caps<-mapM (capture env names) captures
        xs<-mapM (go env names) args
        pure (foldl CApp (CVar label) (caps++xs))
      Fail message -> pure (CErr message)
      LayoutLiteral spec -> pure (CStr spec)
      VectorBuild builder evidence -> CApp (CVar (builderRuntimeName builder)) <$> go env names evidence
      MatchTail style args alts fallback -> do
        xs<-mapM (go env names) args
        next<-go env names fallback
        case (style,xs) of
          (CaseMatch,[scrut])->caseArmsWith False next env names scrut alts
          (FunctionMatch owner,_)->functionArmsWith False next env names owner xs alts
          _->throwError "typed Core erasure: malformed explicit match tail"
      IntValue n -> pure (CInt n)
      StringValue s -> pure (CStr s)
      BoolValue b -> pure (CMk 1 (if b then 1 else 0) [])
      Construct name xs -> do
        (tid,var,ar)<-con name
        unless (ar==length xs) (throwError "typed Core constructor value layout arity")
        CMk tid var <$> mapM (go env names) xs
      AtomValue a -> pure (CMk 6 0 [CStr a])
      TupleValue xs -> do
        (tid,var,_)<-con ("Tup"++show (length xs))
        CMk tid var <$> mapM (go env names) xs
      ListValue xs -> foldr (\x rest -> CApp (CApp (CVar "Cons") x) rest) (CVar "Nil") <$> mapM (go env names) xs
      RecordValue fs -> do
        let sorted=sortOn fst fs
        tid<-shape (map fst sorted)
        CMk tid (length sorted) <$> mapM (go env names . snd) sorted
      RecordField base path -> go env names base >>= \x -> foldM project x path
      RecordUpdate base fields -> do
        x<-go env names base
        v<-fresh "rec"
        CLet v x <$> update env names (CVar v) fields
      PlannedUpdate base plan -> do
        x<-go env names base
        v<-fresh "rec"
        CLet v x <$> plannedUpdate env names (CVar v) plan
      Apply a b -> CApp <$> go env names a <*> go env names b
      Lambda ps b -> let (env',names')=scopes ps env names
                     in CLam (map binderName ps) <$> go env' names' b
      Let p a b -> let (env',names')=scope p env names
                  in CLet (binderName p) <$> go env names a <*> go env' names' b
      LetRec _ _ _ -> throwError "typed Core erasure: recursive binding requires closure conversion"
      ResultPipe a fn -> do
        ok<-fresh "ok"; err<-fresh "err"; scrut<-fresh "scrut"
        x<-go env names a
        f'<-go env names fn
        (tid,var,_)<-con "Ok"
        let fallback=CLet err (CProj 0 (CVar scrut)) (CApp (CVar "Err") (CVar err))
            success=CLet ok (CProj 0 (CVar scrut)) (CApp f' (CVar ok))
        pure (CLet scrut x (CIf (CTagEq tid var (CVar scrut)) success fallback))
      Sequence a b -> do
        x<-go env names a; y<-go env names b; v<-fresh "seq"
        pure (CLet v x y)
      LetPattern p rhs body -> do
        x<-go env names rhs
        v<-fresh "bind"
        let (env',names')=patScopes [p] env names
        k<-go env' names' body
        m<-matchPat (CVar v) p k (CErr ("let pattern: no match; pattern was "++patDisplay p))
        pure (CLet v x m)
      Match CaseMatch [arg] alts -> do
        v<-fresh "scrut"
        x<-go env names arg
        b<-caseArms env names (CVar v) alts
        pure (CLet v x b)
      Match (FunctionMatch name) args alts -> do
        xs<-mapM (go env names) args
        functionArms env names name xs alts
      Match _ _ _ -> throwError "typed Core erasure: malformed case arity"
      If a b c -> CIf <$> go env names a <*> go env names b <*> go env names c
      BoolTest b x -> CTagEq 1 (if b then 1 else 0) <$> go env names x
      Note x -> go env names x
    capture env names uid = do
      n<-maybe (throwError "typed Core erasure: absent capture identity") pure (M.lookup uid env)
      unless (M.lookup n names==Just uid) (throwError "typed Core erasure: capture spelling is shadowed")
      pure (CVar n)
    project scrut name = do
      let cands=[(tid,length (takeWhile (/=name) (sort fs)),length fs)
                | (fs,tid)<-M.toList (recordLayouts layout),name `elem` fs]
      case cands of
        [] -> pure (CErr ("no record shape has field ."++name))
        [(_,idx,_)] -> pure (CProj idx scrut)
        many -> do
          v<-fresh "r"
          pure (CLet v scrut (foldr (\(tid,idx,ar) rest -> CIf (CTagEq tid ar (CVar v)) (CProj idx (CVar v)) rest)
                  (CErr ("no shape with field ."++name++" matched")) many))
    plannedUpdate env names scrut (UpdatePlan roots branches)=do
      let expected=[(tid,sort fs) | (fs,tid)<-M.toList (recordLayouts layout),all (`elem` fs) roots]
          actual=[(tid,map fst fields) | UpdateBranch tid fields<-branches]
      unless (actual==expected) (throwError "typed Core layout: stale record update plan")
      arms<-forM branches $ \(UpdateBranch tid fields)->do
        values<-forM (zip [0..] fields) $ \(idx,(_,value))->case value of
          KeepField->pure (CProj idx scrut)
          ReplaceField x->go env names x
          NestedUpdate tree->plannedUpdate env names (CProj idx scrut) tree
        pure (tid,length fields,CMk tid (length fields) values)
      pure $ case arms of
        [(_,_,body)]->body
        _->foldr (\(tid,arity,body) rest->CIf (CTagEq tid arity scrut) body rest)
          (CErr "record update: no shape matched") arms
    update env names scrut assigns = do
      let roots=nub [head path | (path,_)<-assigns,not (null path)]
          cands=[(fs,tid) | (fs,tid)<-M.toList (recordLayouts layout),all (`elem` fs) roots]
      unless (not (null cands)) (throwError ("typed Core layout: no record shape has fields "++show roots))
      arms<-forM cands $ \(fs,tid) -> do
        vals<-forM (zip [0..] (sort fs)) $ \(idx,name) ->
          case [(path,e) | (path,e)<-assigns,not (null path),head path==name] of
            [] -> pure (CProj idx scrut)
            [([_],e)] -> go env names e
            deeper -> update env names (CProj idx scrut) [(drop 1 p,e) | (p,e)<-deeper]
        pure (tid,length fs,CMk tid (length fs) vals)
      pure $ case arms of
        [(_,_,b)] -> b
        _ -> foldr (\(tid,ar,b) rest -> CIf (CTagEq tid ar scrut) b rest) (CErr "record update: no shape matched") arms
    matchPat scrut p ok fail'=case patNode p of
      Wildcard -> pure ok
      Bind b -> pure (CLet (binderName b) scrut ok)
      IntegerPattern n -> pure (CIf (CApp (CApp (CVar "==") scrut) (CInt n)) ok fail')
      StringPattern s -> pure (CIf (CApp (CApp (CVar "==") scrut) (CStr s)) ok fail')
      ConstructorPattern name ps -> do
        (tid,var,ar)<-con name
        unless (ar==length ps) (throwError "typed Core constructor pattern layout arity")
        inner<-matchFields scrut ps ok fail'
        pure (CIf (CTagEq tid var scrut) inner fail')
      TuplePattern ps -> do
        (tid,var,_)<-con ("Tup"++show (length ps))
        inner<-matchFields scrut ps ok fail'
        pure (CIf (CTagEq tid var scrut) inner fail')
      RecordPattern fs -> foldr (\(name,b) rest -> do
        x<-project scrut name; CLet (binderName b) x <$> rest) (pure ok) fs
    matchFields scrut ps ok fail'=foldr (\(i,p) rest -> rest >>= \k -> matchPat (CProj i scrut) p k fail')
      (pure ok) (zip [0..] ps)
    tests p=case patNode p of
      IntegerPattern _ -> 1; StringPattern _ -> 1
      ConstructorPattern _ ps -> 1+sum (map tests ps)
      TuplePattern ps -> 1+sum (map tests ps)
      _ -> 0
    trivial (CErr _) = True
    trivial _ = False
    functionArms env names owner args = functionArmsWith True (CErr ("no matching clause for "++owner)) env names owner args
    functionArmsWith makeJoins bottom env names owner args = loop
      where
        loop []=pure bottom
        loop (Alternative ps gs body:rest)=do
          next<-loop rest
          fallback<-if makeJoins && sum (map tests ps)+length gs>1 && not (trivial next)
            then do
              jn<-fresh (owner++"_fb")
              let params=[n | CVar n<-args]
              unless (length params==length args) (throwError "typed Core function match arguments must be entry variables")
              lift (registerJoin layout jn params next)
              pure (foldl CApp (CVar jn) args)
            else pure next
          let (allEnv,allNames)=allScopes ps gs env names
          b<-go allEnv allNames body
          let (pEnv,pNames)=patScopes ps env names
          guarded<-guards pEnv pNames gs b fallback
          foldr (\(x,p) k -> k >>= \b -> matchPat x p b fallback) (pure guarded) (zip args ps)
    guards _ _ [] ok _=pure ok
    guards env names (g:rest) ok fallback=do
      let (nextEnv,nextNames)=case g of PatternGuard p _ -> patScopes [p] env names; _ -> (env,names)
      inner<-guards nextEnv nextNames rest ok fallback
      case g of
        BoolGuard e -> do x<-go env names e; pure (CIf x inner fallback)
        PatternGuard p e -> do
          x<-go env names e; v<-fresh "gp"
          m<-matchPat (CVar v) p inner fallback
          pure (CLet v x m)
    caseArms env names scrut alts=caseArmsWith True
      (CErr ("case: no matching pattern; arms were ["++intercalate "," [patDisplay p | Alternative [p] _ _<-alts]++"]")) env names scrut alts
    caseArmsWith makeJoins fallback env names scrut alts=loop True alts
      where
        loop _ []=pure fallback
        loop first (Alternative [p] gs body:rest)=do
          next<-loop False rest
          let build fail'=do
                let (e,n)=allScopes [p] gs env names
                b<-go e n body
                let (pe,pn)=patScopes [p] env names
                inner<-guards pe pn gs b fail'
                certain<-if null rest && not first && all (\(Alternative _ g _) -> null g) alts then coveredHead p else pure False
                if certain then case patNode p of
                  ConstructorPattern _ ps -> matchFields scrut ps inner fail'
                  TuplePattern ps -> matchFields scrut ps inner fail'
                  _ -> matchPat scrut p inner fail'
                else matchPat scrut p inner fail'
          if makeJoins && not (trivial next) && tests p+length gs>1 then do
            jn<-fresh "$case_fb"; unit<-fresh "$case_unit"
            matched<-build (CApp (CVar jn) (CInt 0))
            pure (CLet jn (CLam [unit] next) matched)
          else build next
        loop _ _=throwError "typed Core case pattern arity"
        coveredHead p=case patNode p of
          ConstructorPattern name _ -> do
            (tid,_,_)<-con name
            let earlier=[c | Alternative [q] _ _<-init alts,ConstructorPattern c ps<-[patNode q],all irrefutable ps]
                -- The complete constructor family comes from the type model;
                -- compare its content-addressed layout, as ordinary lowering does.
                TypeContext _ constructors=types
                siblings=[c | c<-M.keys constructors,Just (t,_,_)<-[constructorLayout layout c],t==tid,c/=name]
            pure (all (`elem` earlier) siblings)
          _ -> pure False
        irrefutable p=case patNode p of Bind _->True; Wildcard->True; RecordPattern _->True; _->False
