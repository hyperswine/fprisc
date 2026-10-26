{-# LANGUAGE FlexibleContexts #-}
-- Fuse checked map/filter callbacks, retaining lexical capture contracts.
module Core.Typed.Fusion (Fusion,planFusion,FusionNote,renderNote,fuseClosed) where
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Callback.Catalog
import Core.Typed.Callback.Model
import qualified Core.Typed.FusionSafety as Safety
import Core.Typed.Walk (allBinders,localUses,mapChildrenM)
import Core.Identity
import Compiler.VectorOperation
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import Control.Monad.State.Strict
import Data.List (nub)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Decline=CallbackEffect String Safety.Reason | CaptureEffect | CaptureBudget deriving (Eq,Show)
data FusionNote=FusionNote ElementOp String String Decline deriving (Eq,Show)
renderNote (FusionNote op outer inner refusal)=
  "vec note: Vec."++elementOpName op++" `"++outer++"` after Vec."++elementOpName op++" `"++inner
  ++"` is NOT fused: "++reason++" -- the two passes run in order, each over the whole vector"
  where reason=case refusal of
          CallbackEffect name why->"`"++name++"` uses "++Safety.renderReason why
          CaptureEffect->"capture evaluation can have effects or fail"
          CaptureBudget->"combined capture budget exceeded"

data Site=Site Expr ElementOp Expr Expr (Maybe Expr) Expr [(Binder,Expr)]
-- The original code captures retain their schemes; leading ordinary args use
-- checked occurrence types, while lexical polymorphic captures stay polymorphic.
data Callback=Callback Target Expr [(Expr,Scheme)] Int [Expr]
data Build=Build Int (M.Map CodeId CodeFunction) [FusionNote]
data Fusion=Fusion Catalog Safety.Safety
planFusion :: Catalog -> Fusion
planFusion snapshot=Fusion snapshot (Safety.planSafety (catalogTemplates snapshot))

fuseClosed :: Namespace -> TypeContext -> Fusion -> ClosedFunction -> Either String (ClosedFunction,[FusionNote])
fuseClosed (Namespace namespace) types@(TypeContext linears _) (Fusion snapshot safety) input=do
  ((root,codes),Build _ _ notes)<-runStateT (pass (closedRoot input) (closedCode input)) (Build 0 M.empty [])
  result<-rewriteClosed types (\_ _->Right (root,codes)) input
  pure (result,nub notes)
  where
    owner=functionName (closedRoot input)
    aliases=M.unions [bindings (functionBody f) | f<-closedRoot input:map codeAsFunction (M.elems (closedCode input))]
    bindings e=(case exprNode e of Let b rhs _->M.singleton (binderId b) rhs;_->M.empty)
      <>getConst (mapChildrenM (Const . bindings) e)
    -- A stored PAP has already evaluated its arguments. Resolve only value
    -- operands; substituting an arbitrary RHS would repeat or delay effects.
    resolve seen e=case exprNode (unNote e) of
      Var (Local uid) | uid `S.notMember` seen,Just rhs<-M.lookup uid aliases,
        let (head',args)=spine rhs [],all ready args->
          let value=resolve (S.insert uid seen) head'
          in case exprNode (unNote value) of
            Var (Global _ _)->foldl (apply e) value args
            ClosureValue {}->foldl (apply e) value args
            _->e
      _->e
    ready e=case exprNode (unNote e) of
      Var (Local _)->True
      IntValue _->True;StringValue _->True;BoolValue _->True
      _->False
    gen old ty node=Expr ty (linShapeT linears ty) Generated (exprOffset old) node
    ref old b ty=gen old ty (Var (Local (binderId b)))
    local old b=ref old b (binderType b)
    bind old (b,rhs) body=gen old (exprType body) (Let b rhs body)
    apply old fn arg=case exprType fn of
      TFn _ result->gen old result (Apply fn arg)
      _->error "typed fusion: checked callback lost its arrow"
    pass root codes=do
      root'<-function root
      codes'<-traverse (\code->do
        changed<-function (codeAsFunction code)
        pure code {codeBody=functionBody changed}) codes
      Build _ added _<-get
      pure (root',codes' `M.union` added)
    function fn=do
      let scope=M.fromList [(binderId b,b) | b<-functionParameters fn++allBinders (functionBody fn)]
          go e=mapChildrenM go e >>= join scope
      body<-go (functionBody fn)
      pure fn {functionBody=body}
    template key=do
      Build _ added _<-get
      pure $ case key of
        CodeTarget label | Just code<-M.lookup label added->
          Just (Template (codeCaptures code) (codeParameters code) (codeBody code) (codeContract code) ClosureCode)
        _->M.lookup key (catalogTemplates snapshot)
    safeTarget key=do
      Build _ added _<-get
      pure $ case key of
        CodeTarget label | M.member label added->Nothing -- generated only from admitted callbacks
        _->Safety.unsafeTarget safety key
    callback scope expr=do
      let (original,arguments)=spine expr []
          (resolved,leading')=spine (resolve S.empty original) []
          leading=leading'++arguments
          -- Preserve the use's instantiation, rather than its alias RHS's
          -- schematic arrow. Captured argument occurrences keep their types.
          head'=gen resolved (foldr (TFn . exprType) (exprType expr) leading) (exprNode resolved)
          initial=case exprNode head' of
            Var (Global name _)->Just (RootTarget name,[])
            ClosureValue key ids->do
              bs<-mapM (`M.lookup` scope) ids
              pure (CodeTarget key,[(local head' b,binderScheme b) | b<-bs])
            _->Nothing
      case initial of
        Nothing->pure Nothing
        Just (key,captured)->do
          source<-template key
          pure $ case source of
            Just (Template caps ps _ _ ClosureCode)
              | length caps==length captured,length ps==length leading+1->
                Just (Callback key head' (captured++map ordinary leading) (length captured) leading)
            Just (Template [] ps _ _ EntryCode)
              | null captured,length ps==length leading+1->
                Just (Callback key head' (map ordinary leading) 0 leading)
            _->Nothing
      where
        ordinary x=(x,case exprNode (unNote x) of
          Var (Local uid) | Just b<-M.lookup uid scope->binderScheme b
          _->Forall [] [] (exprType x))
    site e=peel [] e
      where
        peel prefix old=case exprNode (unNote old) of
          Let b rhs rest | Safety.unsafeExpression safety rhs==Nothing->peel (prefix++[(b,rhs)]) rest
          _->case spine old [] of
            (head',args) | Var (Global name _)<-exprNode head'->case (name,args) of
              ("Vec.map",[fn,v])->Just (Site e Map head' fn Nothing v prefix)
              ("Vec.filter",[fn,v])->Just (Site e Filter head' fn Nothing v prefix)
              ("Vec.fold",[fn,z,v])->Just (Site e Fold head' fn (Just z) v prefix)
              _->Nothing
            _->Nothing
    reconstruct (Site old _ head' _ _ _ _) fn seed vector=
      let args=fn:maybe [] (:[]) seed++[vector]
          ty=foldr (TFn . exprType) (exprType old) args
          head''=gen head' ty (exprNode head')
      in foldl (apply old) head'' args
    join scope e=case exprNode (unNote e) of
      Let b producer body | Just _<-site producer->
        let plug consumer=case site consumer of
              Just (Site old op head' fn seed vector prefix)
                | Var (Local uid)<-exprNode (unNote vector),uid==binderId b,
                  binderId b `notElem` concatMap localUses (fn:maybe [] (:[]) seed++map snd prefix)->
                    Just (Site old op head' fn seed producer prefix)
              _->Nothing
            try consumer rest=case plug consumer of
              Nothing->pure e
              Just candidate->do
                fused<-combine scope candidate
                pure (maybe e rest fused)
        in case exprNode (unNote body) of
          Let next consumer rest | binderId b `notElem` localUses rest->
            try consumer (\value->bind body (next,value) rest)
          _->try body id
      _->case site e of Nothing->pure e;Just candidate->maybe e id <$> combine scope candidate
    combine scope outer@(Site old op _ fn seed inputVector prefix)=case site inputVector of
      Just inner@(Site _ op' _ innerFn _ vector innerPrefix) | op==op',op/=Fold->do
        let scope''=foldl (\s (b,_)->M.insert (binderId b) b s) scope' innerPrefix
        outerCallback<-callback scope'' fn
        innerCallback<-callback scope'' innerFn
        case (outerCallback,innerCallback) of
          (Just a@(Callback outerKey _ ac _ _),Just b@(Callback innerKey _ bc _ _))->do
            g<-safeTarget innerKey;f<-safeTarget outerKey
            let refusal=case (g,f) of
                  (Just why,_)->Just (CallbackEffect (name innerKey) why)
                  (_,Just why)->Just (CallbackEffect (name outerKey) why)
                  _ | any ((/=Nothing) . Safety.unsafeExpression safety . fst) (ac++bc)->Just CaptureEffect
                    | length ac+length bc>7->Just CaptureBudget
                    | otherwise->Nothing
            case refusal of
              Just why->do
                modify (\(Build n cs ns)->Build n cs (FusionNote op (name outerKey) (name innerKey) why:ns))
                pure Nothing
              Nothing->do
                value<-composite scope'' outer inner a b
                -- A longer chain may now use the newly checked composite.
                Just <$> join scope'' value
          _->pure Nothing
      _->pure Nothing
      where scope'=foldl (\s (b,_)->M.insert (binderId b) b s) scope prefix
    name (RootTarget n)=n
    name (CodeTarget (CodeId n))=n
    composite scope outer@(Site old op _ _ _ _ prefix) (Site _ _ _ _ _ vector innerPrefix)
      a@(Callback _ _ ac _ _) b@(Callback _ _ bc _ _)=do
        let values=ac++bc;prefixes=prefix++innerPrefix
            count=length values
        (label,ns)<-fresh (2*count+length prefixes+1)
        let spelling i=name (CodeTarget label)++".$"++show i
            capture i (_,scheme)=Binder (BinderId ns i) (spelling i) scheme
              (linShapeT linears (case scheme of Forall _ _ ty->ty))
            caps=zipWith capture [0..] values
            inputType=case exprType vector of
              TAp (TC "Vector") element->element
              _->error "typed fusion: vector input lost its checked type"
            lane=Binder (BinderId ns count) (spelling count) (Forall [] [] inputType) (linShapeT linears inputType)
            inner=invoke old b (drop (length ac) caps) (local old lane)
            body=if op==Map then invoke old a (take (length ac) caps) inner
                 else gen old (TC "Bool") (If inner (invoke old a (take (length ac) caps) (local old lane)) (gen old (TC "Bool") (BoolValue False)))
            code=CodeFunction label ClosureCode caps [lane] body
            stage (i,(value,scheme))=case exprNode (unNote value) of
              Var (Local uid)->(uid,[])
              _->let j=count+1+i
                     binding=Binder (BinderId ns j) (spelling j) scheme (linShapeT linears (exprType value))
                 in (binderId binding,[(binding,value)])
            staged=map stage (zip [0..] values)
            closure=gen old (TFn inputType (exprType body)) (ClosureValue label (map fst staged))
            result=reconstruct outer closure Nothing vector
            -- Prefix binders can broaden scope. Fresh display spellings keep
            -- the current compatibility printer from capturing outer globals.
            renamed=[(binder {binderName=spelling (2*count+1+i)},rhs) | (i,(binder,rhs))<-zip [0..] prefixes]
        modify (\(Build n cs notes)->Build n (M.insert label code cs) notes)
        pure (foldr (bind old) result (renamed++concatMap snd staged))
    invoke old (Callback key head' original capCount leading) captures arg=case key of
      CodeTarget label->gen old result (CodeCall label (map binderId (take capCount captures))
        (zipWith (\b x->ref old b (exprType x)) (drop capCount captures) leading++[arg]))
      RootTarget _->foldl (apply old) head'
        (zipWith (\b (x,_)->ref old b (exprType x)) captures original++[arg])
      where result=case exprType head' of
              _->case foldl (\ty _->case ty of TFn _ r->r;_->ty) (exprType head') leading of
                TFn _ ty->ty
                _->error "typed fusion: callback lost its checked result"
    fresh count=do
      Build serial codes notes<-get
      let choose n=
            let base="$typed.fusion."++show n++"."++show (length owner)++"."++owner
                ns=Namespace (namespace++"/fusion/"++owner++"/"++show n)
            in if ns `S.member` catalogNamespaces snapshot || any (`S.member` catalogNames snapshot) (base:[base++".$"++show i | i<-[0..count]])
               then choose (n+1) else (CodeId base,ns,n+1)
          (label,ns,next)=choose serial
      put (Build next codes notes)
      pure (label,ns)
