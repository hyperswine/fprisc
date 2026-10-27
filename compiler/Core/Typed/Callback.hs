{-# LANGUAGE FlexibleContexts #-}
-- Callback specialization on checked closed Core. Code identities survive
-- cloning; callback object arguments survive wherever their identity escapes.
module Core.Typed.Callback
  (CallbackMode(..),Callbacks,specializeCallbacks,specializeCallbacksWith,specializeFromCatalog,specializeClosedFromCatalog,specializeClosedWithDecisions,callbackClosed,callbackClones,callbackDecisions) where
import qualified Core.Typed.Decision as D
import Core.Typed.Syntax
import Core.Typed.Callback.Model
import Core.Typed.Callback.Catalog
import Core.Typed.Callback.Analysis
import Core.Typed.Callback.Trim (trimCallbacks)
import Core.Typed.Close
import Core.Typed.Instantiate
import Core.Typed.Walk
import Core.Typed.Verify (instanceOf,sameType)
import Core.Identity
import Type.Syntax
import qualified Type.Substitution as U
import Ownership.Shape (isLin)
import Ownership.TypeShape (linShapeT)
import Control.Monad.State.Strict
import Control.Monad (unless,foldM,when)
import Data.Functor.Const (Const(..))
import Data.Monoid (Sum(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data CallbackMode=PreserveCallbacks | SpecializeCallbacks deriving (Eq,Show)
data Callbacks=Callbacks ClosedFunction (S.Set CodeId) [D.Decision]
callbackClosed (Callbacks p _ _)=p
callbackClones (Callbacks _ ns _)=ns
callbackDecisions (Callbacks _ _ ds)=ds
data Known=Known Target [BinderId] [Expr] deriving Show
type Key=(Target,[(Slot,Target,Int)])
data Scope=Scope (M.Map BinderId Binder) (M.Map BinderId Known) (S.Set BinderId)
data Work=Work
  { code :: M.Map CodeId CodeFunction, keys :: M.Map Key CodeId,
    plans :: M.Map CodeId ClonePlan, origins :: M.Map CodeId CloneOrigin,
    nextType :: Int,nextTerm :: Int,nextCode :: Int,weight :: Int, removable :: S.Set BinderId, decisions :: [D.Decision] }

specializeCallbacks :: CallbackMode -> Namespace -> TypeContext -> M.Map String Int -> ClosedFunction -> Either String Callbacks
specializeCallbacks mode namespace types arities=specializeCallbacksWith mode namespace types arities []

-- Provider bodies are checked closed products. Imported code is declared, not
-- copied: a cloned source body still constructs its original home closure.
specializeCallbacksWith :: CallbackMode -> Namespace -> TypeContext -> M.Map String Int -> [ClosedFunction] -> ClosedFunction -> Either String Callbacks
specializeCallbacksWith PreserveCallbacks _ types arities _ input=do
  verifyClosed types input
  unless (all (>=0) arities) (Left "typed callbacks: negative physical arity")
  pure (Callbacks input S.empty [])
specializeCallbacksWith _ namespace types arities providers input=do
  snapshot<-catalog types (M.insert (functionName (closedRoot input)) input
    (M.fromList [(functionName (closedRoot p),p) | p<-providers]))
  specializeFromCatalog namespace types arities snapshot (functionName (closedRoot input))

specializeFromCatalog :: Namespace -> TypeContext -> M.Map String Int -> Catalog -> String -> Either String Callbacks
specializeFromCatalog namespace types arities snapshot name=do
  original<-maybe (Left ("typed callbacks: absent catalog owner "++name)) Right (M.lookup name (catalogOwners snapshot))
  specializeClosedFromCatalog namespace types arities snapshot original

-- A linked snapshot has one emitting template owner per constructor, while
-- each artifact retains its own original elided stub and root identities.
specializeClosedFromCatalog :: Namespace -> TypeContext -> M.Map String Int -> Catalog -> ClosedFunction -> Either String Callbacks
specializeClosedFromCatalog=specializeClosedWithDecisions False

specializeClosedWithDecisions :: Bool -> Namespace -> TypeContext -> M.Map String Int -> Catalog -> ClosedFunction -> Either String Callbacks
specializeClosedWithDecisions reporting namespace types arities snapshot original=do
  prepared<-importClosedLibrary types (catalogLibrary snapshot) original
  runCallbacks reporting namespace types arities snapshot prepared

runCallbacks reporting (Namespace ns) types@(TypeContext linears _) arities catalogView input=do
  verifyClosed types input
  unless (all (>=0) arities) (Left "typed callbacks: negative physical arity")
  (rootBody,work)<-runStateT (do
    body<-walk 0 (scope (functionParameters root)) (functionBody root)
    mapM_ convert (M.elems original)
    pure body) initial
  let root'=root {functionBody=rootBody}
  (finished,codes,retained)<-trimCallbacks types arities schemas templates (plans work) (removable work) root' (code work)
  let retain label origin=let present=S.fromList (map binderId (codeCaptures (codes M.! label)++codeParameters (codes M.! label)))
                         in origin {cloneBindings=[(old,uid >>= \u->if u `S.member` present then Just u else Nothing) | (old,uid)<-cloneBindings origin]}
      cloneOrigins=M.mapWithKey retain (M.restrictKeys (origins work) retained)
  output<-rewriteClosedWithOrigins types (\_ _ previous->Right (finished,codes,cloneOrigins `M.union` previous)) input
  let restored=[D.CallbackDecision (functionName root) (targetName target) D.RetainedArityOverflow
        | ClonePlan target _<-M.elems (M.withoutKeys (plans work) retained)]
  pure (Callbacks output retained (reverse (decisions work)++if reporting then restored else []))
  where
    root=closedRoot input
    original=closedCode input
    sourceOwners=catalogHomes catalogView
    schemas=catalogSchemas catalogView
    baseContracts=catalogContracts catalogView
    templates=catalogTemplates catalogView
    analysis=catalogAnalysis catalogView
    demands=callbackDemands analysis
    stable=stableCallback analysis
    initial=Work original M.empty M.empty M.empty (catalogFirstType catalogView) 0 0 0 S.empty []
    record target why=when reporting (modify (\w->w {decisions=D.CallbackDecision (functionName root) target why:decisions w}))
    targetName (RootTarget n)=n
    targetName (CodeTarget (CodeId n))=n
    occupied=catalogBinderIds catalogView
    spellings=catalogNames catalogView
    tempNamespace=Namespace (ns++"/callbacks/"++functionName root++"/temps")
    scope bs=Scope (M.fromList [(binderId b,b) | b<-bs]) M.empty S.empty
    extend bs (Scope env known safe)=Scope (M.union (M.fromList [(binderId b,b) | b<-bs]) env) known safe
    know b k (Scope env known safe)=Scope (M.insert (binderId b) b env) (M.insert (binderId b) k known) safe
    bad reason=lift (Left ("typed callbacks "++functionName root++": "++reason))
    require reason ok=unless ok (bad reason)
    generated ty node=Expr ty (linShapeT linears ty) Generated Nothing node
    ref b=generated (binderType b) (Var (Local (binderId b)))
    freshBinder scheme@(Forall _ _ ty)=do
      n<-gets nextTerm
      modify (\w->w {nextTerm=n+1})
      let uid=BinderId tempNamespace n;name="$typed_cb_"++show n
      if uid `S.member` occupied || name `S.member` spellings then freshBinder scheme
      else pure (Binder uid name scheme (linShapeT linears ty))
    cloneNamespace label=Namespace (ns++"/callbacks/"++show label)
    freshCode=do
      n<-gets nextCode
      modify (\w->w {nextCode=n+1})
      let label=CodeId ("$typed.mono."++functionName root++"."++show n)
      exists<-gets (M.member label . code)
      let namespaceUsed=cloneNamespace label `S.member` catalogNamespaces catalogView
          CodeId spelling=label
      if exists || namespaceUsed || spelling `S.member` spellings then freshCode else pure label
    template t=maybe (bad "missing template") pure (M.lookup t templates)
    count t=case t of
      RootTarget n | n==functionName root->Just (length (functionParameters root))
      RootTarget n->M.lookup n arities
      CodeTarget label->length . contractParameters <$> M.lookup label baseContracts
    known s@(Scope _ values _) e=case exprNode (unNote e) of
      Var (Local uid)->M.lookup uid values
      Var (Global n _) | Just nArgs<-M.lookup n arities,nArgs>0,
        Just signature<-M.lookup n schemas,instanceOf signature (exprType e)->Just (Known (RootTarget n) [] [])
      ClosureValue label caps | Just c<-M.lookup label baseContracts,contractKind c==ClosureCode->Just (Known (CodeTarget label) caps [])
      Apply {}->let (head',args)=spine e [] in do
        Known t caps leading<-known s head'
        n<-count t
        if length leading+length args<n then Just (Known t caps (leading++args)) else Nothing
      _->Nothing
    binderAt (Scope env _ _) uid=maybe (bad "absent value identity") pure (M.lookup uid env)
    safeValue s@(Scope env values assumed) visited e=case exprNode (unNote e) of
      Var (Local uid)
        | uid `S.member` assumed->True
        | uid `S.member` visited->False
        | Just b<-M.lookup uid env,plain (binderType b),not (isLin (binderShape b))->True
        | Just k<-M.lookup uid values->safeKnown s (S.insert uid visited) k
        | otherwise->False
      _ | Just k<-known s e->safeKnown s visited k
        | otherwise->plain (exprType e) && not (isLin (exprShape e))
    safeKnown s@(Scope env _ _) visited (Known _ caps leading)=
      all (\uid->case M.lookup uid env of Just b->safeValue s visited (ref b);_->False) caps
      && all (safeValue s visited) leading
    value s desired (Known target caps leading)=do
      let fullType=foldr (TFn . exprType) desired leading
      head'<-case target of
        RootTarget n->do sc<-maybe (bad ("missing callback schema: "++n)) pure (M.lookup n schemas)
                         require ("callback global schema: "++n++" "++show sc++" at "++show fullType) (instanceOf sc fullType)
                         pure (generated fullType (Var (Global n sc)))
        CodeTarget label->pure (generated fullType (ClosureValue label caps))
      apply head' leading
    apply=foldM (\fn arg->case exprType fn of
      TFn ty result->do require "application argument" (sameType ty (exprType arg));pure (generated result (Apply fn arg))
      _->bad "application has no checked arrow")
    snapshot s e continuation
      | evaluated arities e=continuation s e
      | otherwise=do
          b<-freshBinder (Forall [] [] (exprType e))
          case known s e of
            Just k | safeKnown s S.empty k->modify (\w->w {removable=S.insert (binderId b) (removable w)})
            _->pure ()
          body<-continuation (extend [b] s) (ref b)
          pure (generated (exprType body) (Let b e body))
    snapshotMany s [] continuation=continuation s []
    snapshotMany s (x:xs) continuation=snapshot s x $ \scope' value'->
      snapshotMany scope' xs (\scope'' values->continuation scope'' (value':values))
    convert f=do
      body<-walk 0 (scope (codeCaptures f++codeParameters f)) (codeBody f)
      modify (\w->w {code=M.insert (codeId f) (f {codeBody=body}) (code w)})
    walk depth s e=case exprNode e of
      Let b rhs body->do
        rhs'<-walk depth s rhs
        case known s rhs' of
          Just k | safeKnown s S.empty k->modify (\w->w {removable=S.insert (binderId b) (removable w)})
          _->pure ()
        case known s rhs' of
          Just k@(Known t caps leading) | safeKnown s S.empty k,
            not (poly (binderScheme b) && not (null leading))->
              snapshotMany s leading $ \scope' saved->do
                let k'=Known t caps saved
                    originalAlias=case exprNode (unNote rhs') of Var (Local _)->True;_->False
                initializer<-if originalAlias then pure rhs' else value scope' (exprType rhs') k'
                body'<-walk depth (know b k' scope') body
                pure (if binderId b `notElem` localUses body' then body' else e {exprNode=Let b initializer body'})
          _->do body'<-walk depth (extend [b] s) body
                pure e {exprNode=Let b rhs' body'}
      Apply {}->do
        let (head0,args0)=spine e []
        head'<-walk depth s head0
        args<-mapM (walk depth s) args0
        case known s head' of
          Just k | safeKnown s S.empty k->invoke depth s e k args
          _->do record "<dynamic>" D.UnknownTarget
                result<-apply head' args;pure result {exprOrigin=exprOrigin e,exprOffset=exprOffset e}
      CodeCall label caps args->mapM (walk depth s) args >>= invoke depth s e (Known (CodeTarget label) caps [])
      JoinCall label caps args->mapM (walk depth s) args >>= invoke depth s e (Known (CodeTarget label) caps [])
      MatchTail style args alternatives fallback->do
        args'<-mapM (walk depth s) args
        alternatives'<-mapM (alt depth s args') alternatives
        fallback'<-walk depth s fallback
        pure e {exprNode=MatchTail style args' alternatives' fallback'}
      LetPattern p rhs body->do
        rhs'<-walk depth s rhs
        body'<-walk depth (patternScope s p rhs') body
        pure e {exprNode=LetPattern p rhs' body'}
      _->mapChildrenM (walk depth s) e
    patternScope s p argument=case patNode p of
      Bind b | Just k@(Known _ _ leading)<-known s argument,
        all (evaluated arities) leading->know b k (extend [b] s)
      _->extend (patternBinders p) s
    alt depth s args (Alternative ps guards body)=do
      let start=foldl (\scope' (p,a)->patternScope scope' p a) s (zip ps args)
          go scope' []=do b<-walk depth scope' body;pure ([],b)
          go scope' (BoolGuard x:rest)=do
            x'<-walk depth scope' x;(rest',b)<-go scope' rest;pure (BoolGuard x':rest',b)
          go scope' (PatternGuard p x:rest)=do
            x'<-walk depth scope' x;(rest',b)<-go (patternScope scope' p x') rest;pure (PatternGuard p x':rest',b)
      (guards',body')<-go start guards
      pure (Alternative ps guards' body')
    -- Clone only checked templates. The root is an explicit target too; its
    -- private references retain their imported or locally owned identities.
    invoke depth s old k@(Known target caps leading) args=do
      let ordinary=leading++args
      case M.lookup target templates of
        Just (Template captures parameters _ _ _) | length ordinary==length parameters->do
          capExprs<-mapM (fmap ref . binderAt s) caps
          let actuals=M.fromList (zip (map CaptureSlot [0..]) capExprs++zip (map ArgumentSlot [0..]) ordinary)
              picks=[(slot,cb) | slot<-S.toAscList (M.findWithDefault S.empty target demands),
                Just argument<-[M.lookup slot actuals],Just cb<-[known s argument],
                safeKnown s S.empty cb,stable target slot]
          clone<-if null picks then do
              let wanted=S.toAscList (M.findWithDefault S.empty target demands)
                  knowns=[(slot,cb) | slot<-wanted,Just argument<-[M.lookup slot actuals],Just cb<-[known s argument]]
                  why | any (not . stable target . fst) knowns=D.Unstable
                      | any (not . safeKnown s S.empty . snd) knowns=D.UnsafeArgument
                      | otherwise=D.NoKnownArgument
              when (not (null wanted)) (record (targetName target) why)
              pure (Left D.NoKnownArgument)
            else do
              result<-getClone depth target picks
              record (targetName target) (either id (const D.Specialized) result)
              pure result
          case clone of
            Right label->prepareArguments s picks ordinary $ \_ saved leadingBySlot->do
                let extraCaps=concat [cs | (_,Known _ cs _)<-picks]
                    savedLeading=concat [M.findWithDefault [] slot leadingBySlot | (slot,_)<-picks]
                kind<-gets (codeKind . (M.! label) . code)
                pure old {exprNode=if kind==JoinCode then JoinCall label (caps++extraCaps) (saved++savedLeading)
                  else CodeCall label (caps++extraCaps) (saved++savedLeading)}
            Left _->direct s old k args
        _->direct s old k args
    -- Preserve the argument positions before rearranging private capture and
    -- parameter banks. Callback objects stay available for identity uses.
    prepareArguments s picks ordinary continuation=go s 0 ordinary [] captured
      where
        choices=M.fromList picks
        captured=M.fromList [(slot,leading) | (slot@(CaptureSlot _),Known _ _ leading)<-picks]
        go scope' _ [] saved leading=continuation scope' (reverse saved) leading
        go scope' i (argument:rest) saved leading=case M.lookup (ArgumentSlot i) choices of
          Nothing->snapshot scope' argument $ \scope'' value'->go scope'' (i+1) rest (value':saved) leading
          Just (Known target caps supplied)->snapshotMany scope' supplied $ \scope'' supplied'->do
            originalValue<-case exprNode (unNote argument) of
              Var (Local _)->pure argument
              _->value scope'' (exprType argument) (Known target caps supplied')
            snapshot scope'' originalValue $ \scope''' value'->
              go scope''' (i+1) rest (value':saved) (M.insert (ArgumentSlot i) supplied' leading)
    direct s old k@(Known target caps leading) args=case target of
      RootTarget _->do
        head'<-value s (foldr (TFn . exprType) (exprType old) args) k
        result<-apply head' args
        pure result {exprOrigin=exprOrigin old,exprOffset=exprOffset old}
      CodeTarget label->do
        let ordinary=leading++args
        case M.lookup label baseContracts of
          Just c | length ordinary==length (contractParameters c)->pure old {exprNode=
            if contractKind c==JoinCode then JoinCall label caps ordinary else CodeCall label caps ordinary}
          _->do head'<-value s (foldr (TFn . exprType) (exprType old) args) k
                result<-apply head' args
                pure result {exprOrigin=exprOrigin old,exprOffset=exprOffset old}
    getClone depth target picks=do
      let key=(target,[(slot,t,length leading) | (slot,Known t _ leading)<-picks])
      existing<-gets (M.lookup key . keys)
      case existing of
        Just label->pure (Right label)
        Nothing->do
          Template caps ps body _ _<-template target
          state<-get
          let extra=sum [length cs+length ls | (_,Known _ cs ls)<-picks]
              minimumArity=length caps+length ps-length picks+extra
          let spent=weight state+nodes body
              refusal | minimumArity>64=Just (D.OverArity minimumArity 64)
                      | depth>=12=Just (D.TooDeep depth 12)
                      | M.size (keys state)>=256=Just (D.TooManyClones (M.size (keys state)) 256)
                      | spent>60000=Just (D.OverNodeBudget spent 60000)
                      | otherwise=Nothing
          case refusal of
            Just why->pure (Left why)
            Nothing->do
              built<-prepareClone target picks
              case built of
                Left why->put state>>pure (Left why)
                Right (label,clone,scope',candidates,origin)->do
                  modify (\w->w {keys=M.insert key label (keys w),code=M.insert label clone (code w),
                    plans=M.insert label (ClonePlan target candidates) (plans w),origins=M.insert label origin (origins w),weight=spent})
                  body'<-walk (depth+1) scope' (codeBody clone)
                  modify (\w->w {code=M.insert label (clone {codeBody=body'}) (code w)})
                  pure (Right label)
    prepareClone target picks=do
      Template caps ps body contract kind<-template target
      label<-freshCode
      first<-gets nextType
      let (qs,rs)=contractQuantifiers contract
          originalFn=Function "template" (caps++ps) body
          (sub,flex,after)=U.freshSubstitution first (Forall qs rs (functionType originalFn))
          copied=instantiateFunction (cloneNamespace label) types sub originalFn
          (copiedCaps,copiedPs)=splitAt (length caps) (functionParameters copied)
          selected slot=case slot of CaptureSlot i->copiedCaps!!i;ArgumentSlot i->copiedPs!!i
      modify (\w->w {nextType=after})
      descriptors<-mapM (\(slot,cb)->do descriptor<-freshCallback cb;pure (slot,cb,descriptor)) picks
      let flexible=flex<>mconcat [vs | (_,_,(_,_,_,vs))<-descriptors]
          pairs=[(binderType (selected slot),remaining) | (slot,_,(_,_,remaining,_))<-descriptors]
      next<-gets nextType
      case U.unifyTypes flexible next pairs of
        Left _->pure (Left D.Unification)
        Right (solution,afterSolution)->do
          let private=mconcat [let Forall tv rv _=binderScheme (selected slot) in (S.fromList tv,S.fromList rv) | (slot,_,_)<-descriptors]
              extraVars=mconcat [mconcat (map (U.schemeVariables . U.applyScheme solution) captureSchemes)
                <>mconcat (map (U.variables . U.applyType solution) leadingTypes) | (_,_,(captureSchemes,leadingTypes,_,_))<-descriptors]
          if not (S.null (fst private `S.intersection` fst extraVars) && S.null (snd private `S.intersection` snd extraVars))
            then pure (Left D.EscapingType) else do
              modify (\w->w {nextType=afterSolution})
              let instantiated=substituteFunction types solution copied
                  (baseCaps,basePs)=splitAt (length caps) (functionParameters instantiated)
                  selected' slot=case slot of CaptureSlot i->baseCaps!!i;ArgumentSlot i->basePs!!i
              added<-mapM (\(slot,Known cb _ _,(captureSchemes,leadingTypes,_,_))->do
                cs<-mapM (freshBinder . U.applyScheme solution) captureSchemes
                ls<-mapM (freshBinder . Forall [] [] . U.applyType solution) leadingTypes
                pure (selected' slot,Known cb (map binderId cs) (map ref ls),cs,ls)) descriptors
              let allCaps=baseCaps++concat [cs | (_,_,cs,_)<-added]
                  allPs=basePs++concat [ls | (_,_,_,ls)<-added]
                  knowns=M.fromList [(binderId b,k) | (b,k,_,_)<-added]
                  assumed=S.fromList [binderId b | (_,_,cs,ls)<-added,b<-cs++ls]
                  scope'=case scope (allCaps++allPs) of Scope env _ _->Scope env knowns assumed
                  clone=CodeFunction label (if kind==JoinCode then JoinCode else EntryCode) allCaps allPs (functionBody instantiated)
                  (source,templateId)=case target of RootTarget n->(n,CodeId n);CodeTarget k->(sourceOwners M.! k,k)
                  origin=CloneOrigin source templateId (zip (map binderId (caps++ps)) (map (Just . binderId) (baseCaps++basePs)))
              pure (Right (label,clone,scope',S.fromList (map (binderId . selected' . fst) picks),origin))
    freshCallback (Known target _ leading)=do
      first<-gets nextType
      (captureSchemes,parameters,result,flex,next)<-case target of
        CodeTarget label->do
          let c=baseContracts M.! label;(qs,rs)=contractQuantifiers c
              full=foldr TFn (contractResult c) (contractParameters c)
              (sub,vars,next)=U.freshSubstitution first (Forall qs rs full)
          pure (map (U.applyScheme sub . fst) (contractCaptures c),map (U.applyType sub) (contractParameters c),U.applyType sub (contractResult c),vars,next)
        RootTarget n->do
          sc<-maybe (bad ("missing callback signature: "++n)) pure (M.lookup n schemas)
          nArgs<-maybe (bad "callback has no physical arity") pure (count target)
          let (full,vars,next)=U.freshen first sc
              peel 0 ty=Just ([],ty)
              peel n (TFn a b)=do (as,r)<-peel (n-1) b;pure (a:as,r)
              peel _ _=Nothing
          (as,r)<-maybe (bad "callback physical interface exceeds its type") pure (peel nArgs full)
          pure ([],as,r,vars,next)
      modify (\w->w {nextType=next})
      require "callback is already saturated" (length leading<length parameters)
      pure (captureSchemes,take (length leading) parameters,foldr TFn result (drop (length leading) parameters),flex)

poly (Forall ts rs _)=not (null ts && null rs)
plain ty=case ty of
  TC n->n `elem` ["Int","Bool","String","Atom","F32","F64","Unit"]
  TLayout _->True
  TTupT xs->all plain xs
  TRec row->fields row
  _->False
  where fields RNil=True;fields (RExt _ t rest)=plain t&&fields rest;fields (RV _)=False
globalNames e=(case exprNode e of Var (Global n _)->S.singleton n;_->S.empty)<>getConst (mapChildrenM (Const . globalNames) e)
nodes :: Expr -> Int
nodes e=1+getSum (getConst (mapChildrenM (Const . Sum . nodes) e))
