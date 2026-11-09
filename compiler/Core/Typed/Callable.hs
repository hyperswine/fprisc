{-# LANGUAGE FlexibleContexts #-}
-- Analysis-only, context-insensitive callable flow over one immutable checked
-- catalog. No optimizer consumes this evidence yet. Unknown is never empty.
module Core.Typed.Callable
  (Limits(..),defaultLimits,Member(..),Value(..),emptyValue,unknownValue,valueStatus,
   Site(..),SiteKind(..),Summary(..),Analysis(..),analyze) where
import Core.Typed.Syntax
import Core.Typed.Callback.Model (Target(..),Slot(..),Template(..),spine)
import Core.Typed.Walk (mapChildrenM)
import Core.Identity (BinderId)
import Type.Syntax (Type(..))
import Source.Span (SourceOffset)
import Control.Monad (when,liftM2)
import Control.Monad.State.Strict
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Limits = Limits {maxRounds :: Int,maxMembers :: Int,maxDepth :: Int} deriving (Eq,Show)
defaultLimits :: Limits
defaultLimits = Limits 32 64 4
-- Supplied counts ordinary arguments, never captures. Capture/argument values
-- are joined by target and slot, not embedded recursively in member identity.
data Member = Member {memberTarget :: Target,memberSupplied :: Int} deriving (Eq,Ord,Show)
data Value = Value {valueMembers :: S.Set Member,valueUnknowns :: S.Set String,
                    valueFields :: M.Map String Value} deriving (Eq,Show)
emptyValue :: Value
emptyValue = Value S.empty S.empty M.empty
unknownValue :: String -> Value
unknownValue why = emptyValue {valueUnknowns=S.singleton why}
data SiteKind = ClosureConstruction | FunctionReference | PartialApplication
  | ResidualApplication | DirectApplication | BoundaryApplication | ContainerStorage
  deriving (Eq,Ord,Show)
data Site = Site {siteOwner :: Target,sitePath :: [Int],siteOffset :: Maybe SourceOffset,
                  siteOrigin :: Origin,siteKind :: SiteKind,siteType :: Type,
                  siteValue :: Value,siteArguments :: Int} deriving Show
data Summary = Summary {summaryContract :: CodeContract,summaryCaptures :: [Binder],
  summaryParameters :: [Binder],summaryInputs :: M.Map Slot Value,summaryResult :: Value,
  summaryDependencies :: S.Set Target,summaryReached :: Bool,summaryProductFlowInvalidated :: Bool} deriving Show
data Analysis = Analysis {analysisSummaries :: M.Map Target Summary,analysisSites :: [Site],
  analysisStatus :: String,analysisRounds :: Int,analysisLimits :: Limits} deriving Show

data Flow = Flow {inputs :: M.Map Target (M.Map Slot Value),results :: M.Map Target Value,
                  reached :: S.Set Target,opaqueEffects :: S.Set Target} deriving (Eq,Show)
data Work = Work {flow :: Flow,sites :: [Site],dependencies :: M.Map Target (S.Set Target)}

bounded limits = cut (max 0 (maxDepth limits))
  where
    cut depth (Value ms us fs) = Value
      (S.fromList (take cap (S.toAscList ms)))
      (S.fromList (take cap (S.toAscList us)) `S.union`
        S.fromList (["member-budget" | S.size ms>cap || S.size us>cap] ++
                    ["structure-budget" | depth==0 && not (M.null fs)]))
      (if depth==0 then M.empty else M.map (cut (depth-1)) fs)
    cap=max 1 (maxMembers limits)
join limits (Value a u f) (Value b v g)=bounded limits (Value (a<>b) (u<>v) (M.unionWith (join limits) f g))
joins limits=foldl (join limits) emptyValue
membersDeep v=valueMembers v<>S.unions (map membersDeep (M.elems (valueFields v)))
unknownsDeep v=valueUnknowns v<>S.unions (map unknownsDeep (M.elems (valueFields v)))
-- Bottom means no evidence yet (including a non-returning cycle), never a
-- proof that a function-valued expression has no runtime targets.
valueStatus :: Value -> String
valueStatus v
  | not (S.null (unknownsDeep v)) = "unknown"
  | v==emptyValue = "no-callable-evidence"
  | not (M.null (valueFields v)) = "structured"
  | otherwise = "finite-candidates"
callable ty=case ty of TFn{}->True;TV{}->True;_->False

-- Roots are externally callable entries of this snapshot. Other functions
-- acquire input evidence through calls or escaping callable values.
analyze :: Limits -> S.Set Target -> M.Map Target Template -> Analysis
analyze limits roots templates = Analysis summaries finalSites status rounds limits
  where
    initial=Flow (M.fromList [(t,seed t) | t<-S.toList roots,M.member t templates]) M.empty (roots `S.intersection` M.keysSet templates) S.empty
    seed t=case templates M.! t of
      Template cs ps _ _ _->M.fromList
        [(slot,unknownValue ("open-input:"++show (binderId b))) | (slot,b)<-roles cs ps]
    roles cs ps=zip (map CaptureSlot [0..]) cs++zip (map ArgumentSlot [0..]) ps
    run old = execState (mapM_ (visit old) (S.toAscList (reached old))) (Work old [] M.empty)
    visit old t=case M.lookup t templates of
      Nothing->pure ()
      Just (Template cs ps body _ _)->do
        let ins=M.findWithDefault M.empty t (inputs old)
            env=M.fromList [(binderId b,M.findWithDefault emptyValue slot ins) | (slot,b)<-roles cs ps]
        v<-eval old t [] env body
        modify $ \w->w {flow=(flow w) {results=M.insertWith (join limits) t v (results (flow w))}}
        when (t `S.member` roots) (escape old t v)
    solve n old
      | n>=max 1 (maxRounds limits)=(old,n,False)
      | otherwise=let next=flow (run old) in if next==old then (old,n+1,True) else solve (n+1) next
    (settled,rounds,complete)=solve 0 initial
    status=if complete then "fixed-point" else "budget-limited"
    -- A non-converged prefix is not a closed set. Tag all published values,
    -- including nested ones. Unreached entries are explicitly not analyzed.
    publish v=let safe=projectable settled v in
      if complete then safe else safe {valueUnknowns=S.insert "iteration-budget" (valueUnknowns safe)}
    censusState=settled {inputs=M.union (inputs settled) (M.fromList
      [(t,seed t) | t<-M.keys templates])}
    finalWork=execState (mapM_ (visit censusState) (M.keys templates)) (Work settled [] M.empty)
    finalSites=reverse (sites finalWork)
    summaries=M.mapWithKey (\t (Template cs ps _ contract _)->Summary contract cs ps
      (M.map publish (M.findWithDefault M.empty t (inputs settled)))
      (if t `S.member` reached settled then publish (let v=M.findWithDefault emptyValue t (results settled) in
         if callable (contractResult contract) && v==emptyValue then unknownValue "no-returning-callable-evidence" else v)
       else unknownValue "not-reached-from-roots")
      (M.findWithDefault S.empty t (dependencies finalWork)) (t `S.member` reached settled) (not (S.null (opaqueEffects settled)))) templates
    addSite owner path e kind n v=modify $ \w->w {sites=Site owner path (exprOffset e) (exprOrigin e) kind (exprType e)
      (publish (if owner `S.notMember` reached settled then join limits v (unknownValue "not-reached-from-roots")
        else if v==emptyValue && kind `elem` [ResidualApplication,PartialApplication,DirectApplication]
          then unknownValue "unresolved-callable-flow" else v)) n:sites w,
      dependencies=M.insertWith S.union owner (S.map memberTarget (membersDeep v)) (dependencies w)}
    local env uid=M.findWithDefault (unknownValue ("missing-binder:"++show uid)) uid env
    touch owner target=modify $ \w->w
      {dependencies=M.insertWith S.union owner (S.singleton target) (dependencies w),
       flow=(flow w) {reached=S.insert target (reached (flow w))}}
    taint owner=modify $ \w->w {flow=(flow w) {opaqueEffects=S.insert owner (opaqueEffects (flow w))}}
    feed target values=modify $ \w->w {flow=(flow w)
      {inputs=M.insertWith (M.unionWith (join limits)) target (M.fromList values) (inputs (flow w))}}
    escape old owner v=mapM_ one (S.toList (membersDeep v))
      where
        one (Member t supplied)=case M.lookup t templates of
          Nothing->pure ()
          Just (Template _ ps _ _ _)->do
            touch owner t
            feed t [(ArgumentSlot i,unknownValue "escaped-callable-input") | i<-[supplied..length ps-1]]
    invoke old owner depth headValue args
      | depth>max 1 (maxDepth limits)=pure (unknownValue "application-depth-budget")
      | otherwise=do
        when (not (S.null (valueUnknowns headValue))) (taint owner >> mapM_ (escape old owner) args)
        outcomes<-mapM one (S.toList (valueMembers headValue))
        pure (joins limits (unknownValueSet (valueUnknowns headValue):outcomes))
      where
        unknownValueSet us=emptyValue {valueUnknowns=us}
        one (Member t supplied)=case M.lookup t templates of
          Nothing->pure (unknownValue ("missing-target:"++show t))
          Just (Template _ ps _ _ _)->do
            let needed=length ps-supplied
                consumed=take (max 0 needed) args
            feed t (zip (map ArgumentSlot [supplied..]) consumed)
            if length args<needed then pure emptyValue {valueMembers=S.singleton (Member t (supplied+length args))}
            else do
              touch owner t
              when (t `S.member` opaqueEffects old) (taint owner)
              let result=M.findWithDefault emptyValue t (results old)
              if length args==needed then pure result else invoke old owner (depth+1) result (drop (max 0 needed) args)
    project key v=join limits (emptyValue {valueUnknowns=valueUnknowns v})
      (M.findWithDefault (unknownValue ("unknown-projection:"++key)) key (valueFields v))
    patternEnv env p v=case patNode p of
      Bind b->M.insert (binderId b) v env
      TuplePattern ps->foldl (\s (i,p')->patternEnv s p' (project (show i) v)) env (zip [0::Int ..] ps)
      RecordPattern fs->foldl (\s (k,b)->M.insert (binderId b) (project k v) s) env fs
      ConstructorPattern _ ps->foldl (\s p'->patternEnv s p' (unknownValue "constructor-pattern-flow")) env ps
      _->foldr (\b->M.insert (binderId b) (unknownValue "pattern-flow")) env (patternBinders p)
    eval old owner path env e=let
      child i=eval old owner (path++[i]) env
      record kind n v=addSite owner path e kind n v >> pure v
      children=getConst (mapChildrenM (Const . (:[])) e)
      generic why=do vs<-sequence [child i x | (i,x)<-zip [0..] children]
                     mapM_ (escape old owner) vs
                     pure (unknownValue why)
      in case exprNode e of
        Note x->child 0 x
        Var (Local uid)->pure (projectable old (local env uid))
        Var (Global n _)->case M.lookup (RootTarget n) templates of
          Just (Template _ ps _ _ _) | not (null ps)->record FunctionReference 0 emptyValue {valueMembers=S.singleton (Member (RootTarget n) 0)}
          Just _->touch owner (RootTarget n) >> pure (M.findWithDefault emptyValue (RootTarget n) (results old))
          Nothing->pure (unknownValue ("external-target:"++n))
        ClosureValue label caps->do
          let t=CodeTarget label
          feed t (zip (map CaptureSlot [0..]) (map (projectable old . local env) caps))
          record ClosureConstruction 0 (if M.member t templates then emptyValue {valueMembers=S.singleton (Member t 0)} else unknownValue ("missing-code:"++show label))
        Apply {}->do
          let (head',args)=spine e []
          h<-child 0 head'
          values<-sequence [child i a | (i,a)<-zip [1..] args]
          result<-invoke old owner 0 h values
          let partial=any (\(Member t k)->case M.lookup t templates of Just (Template _ ps _ _ _)->k+length args<length ps;_->False) (S.toList (valueMembers h))
              kind | partial=PartialApplication
                   | Var (Global n _) <- exprNode head',M.notMember (RootTarget n) templates=BoundaryApplication
                   | Var (Global _ _) <- exprNode head'=DirectApplication
                   | otherwise=ResidualApplication
          addSite owner path e kind (length args) h
          pure result
        CodeCall label cs args->direct old owner path env e label cs args
        JoinCall label cs args->direct old owner path env e label cs args
        Let b rhs body->do
          value<-child 0 rhs
          eval old owner (path++[1]) (M.insert (binderId b) value env) body
        LetRec b rhs body->do
          let env'=M.insert (binderId b) (unknownValue "local-recursive-binding") env
          value<-eval old owner (path++[0]) env' rhs
          eval old owner (path++[1]) (M.insert (binderId b) value env') body
        If c a b->child 0 c >> liftM2 (join limits) (child 1 a) (child 2 b)
        Sequence a b->child 0 a >> child 1 b
        CallRegion x->child 0 x
        LetPattern p rhs body->do v<-child 0 rhs;eval old owner (path++[1]) (patternEnv env p (projectable old v)) body
        TupleValue xs->productValue old owner path env e (zip (map show [0::Int ..]) xs)
        RecordValue fs->productValue old owner path env e fs
        RecordField x keys->do
          v<-child 0 x
          pure (if not (S.null (opaqueEffects old)) then unknownValue "product-flow-after-opaque-effect"
            else foldl (flip project) v keys)
        SetField {}->taint owner >> generic "mutable-field-store"
        Match _ xs alts->match old owner path env xs alts Nothing
        MatchTail _ xs alts fallback->match old owner path env xs alts (Just fallback)
        Fail _->pure emptyValue
        IntValue _->pure emptyValue
        StringValue _->pure emptyValue
        BoolValue _->pure emptyValue
        AtomValue _->pure emptyValue
        LayoutLiteral _->pure emptyValue
        EntryTick->pure emptyValue
        -- Until container/lifetime consumers share precise facts, their
        -- callables escape conservatively. Do not flatten heterogeneous fields
        -- into an allegedly compatible closed function family.
        _->do v<-generic "unsupported-value-flow"
              if any (callable . exprType) children then record ContainerStorage 0 v else pure v
    direct old owner path env e label cs args=do
      let t=CodeTarget label
      feed t (zip (map CaptureSlot [0..]) (map (projectable old . local env) cs))
      values<-sequence [eval old owner (path++[i]) env a | (i,a)<-zip [0..] args]
      let h=if M.member t templates then emptyValue {valueMembers=S.singleton (Member t 0)} else unknownValue ("missing-code:"++show label)
      addSite owner path e DirectApplication (length args) h
      invoke old owner 0 h values
    productValue old owner path env e fields=do
      vs<-sequence [do v<-eval old owner (path++[i]) env x;pure (k,v) | (i,(k,x))<-zip [0..] fields]
      let value=bounded limits emptyValue {valueFields=M.fromList vs}
      when (not (S.null (membersDeep value)) || not (S.null (unknownsDeep value))) (addSite owner path e ContainerStorage 0 value)
      pure value
    -- Without an alias analysis, an opaque mutation can affect a product
    -- captured in another owner. Conservatively invalidate product evidence
    -- across the snapshot, not merely in the syntactic caller.
    projectable old v=if not (S.null (opaqueEffects old)) && not (M.null (valueFields v))
      then v {valueUnknowns=S.insert "product-flow-after-opaque-effect" (valueUnknowns v)} else v
    match old owner path env xs alts fallback=do
      values<-sequence [eval old owner (path++[i]) env x | (i,x)<-zip [0..] xs]
      answers<-sequence [alt old owner (path++[length xs+i]) env values a | (i,a)<-zip [0..] alts]
      other<-maybe (pure emptyValue) (eval old owner (path++[length xs+length alts]) env) fallback
      pure (joins limits (other:answers))
    alt old owner path env values (Alternative ps gs body)=guards env' 0 gs
      where
        env'=foldl (\s (p,v)->patternEnv s p (projectable old v)) env (zip ps values)
        guards scope i []=eval old owner (path++[i]) scope body
        guards scope i (g:rest)=case g of
          BoolGuard x->eval old owner (path++[i]) scope x >> guards scope (i+1) rest
          PatternGuard p x->do v<-eval old owner (path++[i]) scope x;guards (patternEnv scope p (projectable old v)) (i+1) rest
